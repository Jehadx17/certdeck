import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'db.dart';
import 'logic.dart';

/// Content packs (docs/DARB-PACKS.md). The file comes from the CDN (resumable); a subscriber's device gets its key from
/// the backend. Cards are imported into the local database and never synced: the review log restores their schedule.
class Packs {
  static final progress = ValueNotifier<Map<String, double>>({}); // slug -> 0..1 while downloading

  static Future<List<Json>> manifest() async =>
      [for (final p in (await Api.call('GET', 'packs') as Map)['packs'] as List) Map<String, dynamic>.from(p as Map)];

  static Future<Directory> _dir() async => Directory(p.join((await getApplicationDocumentsDirectory()).path, 'packs')).create(recursive: true);

  /// Installs [pack] (manifest entry): the full encrypted pack for a subscriber, else the free sample.
  /// Returns null on success or a message.
  static Future<String?> install(Json pack, {required bool premium}) async {
    final slug = pack['slug'] as String;
    try {
      final Json data;
      if (premium) {
        final file = File(p.join((await _dir()).path, '$slug-${pack['version']}.dpk'));
        await download(Uri.parse(pack['url'] as String), file, size: pack['size'] as int, sha256: pack['sha256'] as String,
            onProgress: (f) => progress.value = {...progress.value, slug: f});
        final key = Map<String, dynamic>.from(await Api.call('POST', 'packs/$slug/key') as Map);
        data = await compute(decryptPack, (await file.readAsBytes(), slug, key['version'] as int, base64.decode(key['key'] as String)));
        data['seed'] = key['seed'];
      } else {
        final r = await http.get(Uri.parse(pack['sample_url'] as String)).timeout(const Duration(minutes: 2));
        if (r.statusCode != 200) return 'Download failed (HTTP ${r.statusCode})';
        data = jsonDecode(utf8.decode(gzip.decode(r.bodyBytes))) as Json;
      }
      await importPack(data);
      return null;
    } on ApiError catch (e) {
      return e.message;
    } on Exception catch (e) {
      return 'Download failed: $e';
    } finally {
      progress.value = {...progress.value}..remove(slug);
    }
  }

  /// Downloads [uri] to [file], resuming a partial `.part` with a Range request after a dropped connection, and checks
  /// the sha256. Already complete: does nothing.
  static Future<void> download(Uri uri, File file, {required int size, required String sha256, void Function(double)? onProgress}) async {
    if (await file.exists() && await file.length() == size) return;
    final part = File('${file.path}.part');
    final client = http.Client();
    try {
      for (var attempt = 0; attempt < 5; attempt++) {
        final have = await part.exists() ? await part.length() : 0;
        if (have >= size) break;
        try {
          final res = await client.send(http.Request('GET', uri)..headers['Range'] = 'bytes=$have-').timeout(const Duration(seconds: 30));
          if (res.statusCode != 206 && res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
          final sink = part.openWrite(mode: res.statusCode == 206 ? FileMode.append : FileMode.write);
          var got = res.statusCode == 206 ? have : 0;
          await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
            sink.add(chunk);
            got += chunk.length;
            onProgress?.call(got / size);
          }
          await sink.close();
        } on Exception {
          if (attempt == 4) rethrow;
          await Future<void>.delayed(Duration(seconds: 2 << attempt)); // slow networks: back off, then resume
        }
      }
      final digest = await crypto.sha256.bind(part.openRead()).first;
      if (digest.toString() != sha256) {
        await part.delete();
        throw const FormatException('the download was corrupted; it will start again');
      }
      await part.rename(file.path);
    } finally {
      client.close();
    }
  }

  /// Imports a decrypted (or sample) pack: replaces the pack's cards, watermarked for this account, then rebuilds their
  /// schedules from the synced review log.
  static Future<int> importPack(Json data) async {
    final slug = data['slug'] as String;
    final seed = data['seed'] as String?;
    final cards = [
      for (final c in data['cards'] as List)
        watermark({...Map<String, dynamic>.from(c as Map), if (data['sample'] == true) 'sample': true}, seed),
    ];
    await Db.deletePack(slug);
    await Db.putAll('card', cards, dirty: false);
    await Db.setMeta('pack:$slug', '${data['version']}${data['sample'] == true ? ':sample' : ''}');
    await replayReviews(cards.map((c) => c['id'] as String));
    return cards.length;
  }

  /// A subscription ended: full packs go, the free samples come back.
  static Future<void> lapse(List<Json> manifest) async {
    for (final pack in manifest) {
      final installed = await Db.meta('pack:${pack['slug']}');
      if (installed != null && !installed.endsWith(':sample')) {
        await Db.deletePack(pack['slug'] as String);
        await install(pack, premium: false);
      }
    }
  }
}

Future<Json> decryptPack((Uint8List, String, int, List<int>) args) async {
  final (blob, slug, version, key) = args;
  if (blob.length < 32 || utf8.decode(blob.sublist(0, 4)) != 'DPK1') throw const FormatException('not a Darb pack');
  final box = SecretBox(blob.sublist(16, blob.length - 16), nonce: blob.sublist(4, 16), mac: Mac(blob.sublist(blob.length - 16)));
  final plain = await AesGcm.with256bits().decrypt(box, secretKey: SecretKey(key), aad: utf8.encode('darb:$slug:$version'));
  return jsonDecode(utf8.decode(gzip.decode(plain))) as Json;
}

/// Makes this account's copy unique (docs/DARB-PACKS.md → Watermark): a multiple-choice card's options are shuffled
/// in an order derived from the account's seed and the card id, and the explanation carries an invisible zero-width
/// marker of the seed. A leaked copy then points back to its account. Samples (public) are left as they are.
Json watermark(Json c, String? seed) {
  if (seed == null) return c;
  final h = crypto.Hmac(crypto.sha256, utf8.encode(seed)).convert(utf8.encode('${c['id']}')).bytes;
  final options = c['options'] as List?;
  if (c['type'] == 'mcq' && options != null && options.length > 1) {
    final order = List<int>.generate(options.length, (i) => i);
    for (var i = order.length - 1; i > 0; i--) {
      final j = h[i % h.length] % (i + 1), tmp = order[i];
      order[i] = order[j];
      order[j] = tmp;
    }
    c['options'] = [for (final i in order) options[i]];
    final expl = c['option_explanations'] as List?;
    if (expl != null && expl.length == options.length) c['option_explanations'] = [for (final i in order) expl[i]];
    c['correct'] = [for (final k in (c['correct'] as List).cast<int>()) order.indexOf(k)]..sort();
  }
  final mark = crypto.Hmac(crypto.sha256, utf8.encode(seed)).convert(utf8.encode('wm')).bytes.take(4);
  final bits = mark.expand((b) => List.generate(8, (i) => (b >> (7 - i)) & 1 == 1 ? '‌' : '​')).join();
  if (c['explanation'] is String) c['explanation'] = '${c['explanation']}$bits';
  return c;
}

/// Rebuilds the FSRS state of [cardIds] from the review log (a reinstall, or a pack imported after reviews synced).
Future<void> replayReviews(Iterable<String> cardIds) async {
  final ids = cardIds.toSet();
  final byCard = <String, List<Json>>{};
  for (final r in await Db.query('review', orderBy: 'ts')) {
    final id = r['card_id'] as String?;
    if (id != null && ids.contains(id)) byCard.putIfAbsent(id, () => []).add(r);
  }
  for (final entry in byCard.entries) {
    final card = await Db.get(entry.key);
    if (card == null) continue;
    await Db.put('card', replay(card, entry.value));
  }
}
