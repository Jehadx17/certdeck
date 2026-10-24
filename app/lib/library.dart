import 'package:flutter/material.dart';

import 'ai.dart';
import 'cards.dart';
import 'db.dart';
import 'i18n.dart';
import 'logic.dart';
import 'widgets.dart';

/// Owner's Library tab: search, one tile per cert deck, all cards, Generate.
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  void _push(BuildContext context, Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));

  Widget _header(BuildContext context, String s) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(s.toUpperCase(),
          style: TextStyle(fontSize: 12, letterSpacing: .8, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurfaceVariant)));

  Widget _tile(BuildContext context, IconData icon, String title, String? sub, Widget to) => Card(
      child: ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: sub == null ? null : Text(sub, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _push(context, to)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t('Library'))),
      body: Live<Map<String, (int, int)>>(
        load: () async => {
          for (final c in App.certs)
            c['id'] as String: await Db.cardsFor(c['id'] as String).then((l) => (l.length, l.where((x) => x['leech'] == true && !isSuspended(x)).length)),
        },
        builder: (context, counts) => ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(hintText: t('Search all cards'), prefixIcon: const Icon(Icons.search)),
            onSubmitted: (v) => _push(context, CardsScreen(cert: 'any', query: v)),
          ),
          _header(context, t('Certs')),
          for (final c in App.certs)
            _tile(context, Icons.style_outlined, c['code'] ?? '',
                t('{n} cards · {l} leeches', {'n': counts[c['id']]?.$1 ?? 0, 'l': counts[c['id']]?.$2 ?? 0}), CardsScreen(cert: c['id'] as String)),
          const SizedBox(height: 8),
          _tile(context, Icons.collections_bookmark_outlined, t('All cards'), null, const CardsScreen(cert: 'any')),
          _tile(context, Icons.auto_awesome, t('Generate cards'), null, generateScreen()),
        ]),
      ),
    );
  }
}
