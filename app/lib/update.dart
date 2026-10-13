import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';

/// Forced self-update. When the server has a newer build (deploy/release-apk.sh), the app locks, downloads it and
/// installs it (MainActivity.kt). Offline or on any error it keeps working and tries again on the next open/resume,
/// so studying never depends on the network.
class Updater {
  static const _ch = MethodChannel('certdeck/update');

  /// Non-null while an update is underway: UpdateGate covers the app with it. 'permission' = needs the one-time
  /// "install unknown apps" permission.
  static final status = ValueNotifier<String?>(null);
  static bool _busy = false;

  static Future<void> check() async {
    if (!Platform.isAndroid || !Api.configured || _busy) return;
    _busy = true;
    _ch.setMethodCallHandler((call) async => status.value = null); // 'failed': install cancelled or rejected
    try {
      final latest = Map<String, dynamic>.from(await Api.call('GET', 'app/latest'));
      final dir = await getTemporaryDirectory();
      if (latest['version_code'] as int <= (await _ch.invokeMethod<int>('versionCode'))!) {
        for (final f in dir.listSync().whereType<File>().where((f) => f.path.contains('/update-'))) {
          f.deleteSync(); // the downloaded APK of an update that's now installed
        }
        return;
      }
      final name = latest['version_name'];
      status.value = 'Downloading CertDeck $name…';
      final apk = File('${dir.path}/update-${latest['version_code']}.apk');
      if (!await apk.exists() || sha256.convert(await apk.readAsBytes()).toString() != latest['sha256']) {
        final bytes = await Api.call('GET', 'app/apk', timeout: const Duration(minutes: 10)) as List<int>;
        if (sha256.convert(bytes).toString() != latest['sha256']) throw ApiError('update download corrupted');
        await apk.writeAsBytes(bytes, flush: true);
      }
      if (!(await _ch.invokeMethod<bool>('canInstall'))!) {
        status.value = 'permission';
        return;
      }
      status.value = 'Installing CertDeck $name…\n\nThe app closes when it\'s done. Open it again to continue.';
      await _ch.invokeMethod('install', apk.path);
    } catch (_) {
      status.value = null;
    } finally {
      _busy = false;
    }
  }
}

/// Covers the app while an update installs. The app stays mounted underneath, so resuming re-checks.
class UpdateGate extends StatelessWidget {
  final Widget child;
  const UpdateGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
        valueListenable: Updater.status,
        builder: (context, s, _) => Stack(children: [
          child,
          if (s != null)
            Positioned.fill(
              child: Scaffold(
                body: SafeArea(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: s == 'permission'
                            ? [
                                const Icon(Icons.system_update, size: 48),
                                const SizedBox(height: 16),
                                Text('A new version of CertDeck is ready', style: Theme.of(context).textTheme.titleMedium),
                                const SizedBox(height: 8),
                                const Text('One time only: allow CertDeck to install its own updates. Tap below, turn on '
                                    '"Allow from this source", then come back.', textAlign: TextAlign.center),
                                const SizedBox(height: 24),
                                FilledButton(
                                    onPressed: () => const MethodChannel('certdeck/update').invokeMethod('openInstallSettings'),
                                    child: const Text('Allow updates')),
                              ]
                            : [const CircularProgressIndicator(), const SizedBox(height: 24), Text(s, textAlign: TextAlign.center)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );
}
