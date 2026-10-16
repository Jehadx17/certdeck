import 'package:flutter/material.dart';

import 'i18n.dart';
import 'widgets.dart';

/// Weighted percentage (النسبة الموزونة) = high school % × w1 + قدرات × w2 + تحصيلي × w3. Every university and
/// college sets its own weights, so they are editable; 30/30/40 is only a starting example.
double? weighted(List<double?> scores, List<double?> weights) {
  if (scores.any((s) => s == null || s < 0 || s > 100) || weights.any((w) => w == null || w < 0)) return null;
  final total = weights.fold<double>(0, (a, w) => a + w!);
  if ((total - 100).abs() > .01) return null;
  var sum = 0.0;
  for (var i = 0; i < scores.length; i++) {
    sum += scores[i]! * weights[i]! / 100;
  }
  return sum;
}

class WeightedScreen extends StatefulWidget {
  const WeightedScreen({super.key});
  @override
  State<WeightedScreen> createState() => _WeightedScreenState();
}

class _WeightedScreenState extends State<WeightedScreen> {
  final _score = [TextEditingController(), TextEditingController(), TextEditingController()];
  final _weight = [TextEditingController(text: '30'), TextEditingController(text: '30'), TextEditingController(text: '40')];

  @override
  void dispose() {
    for (final c in [..._score, ..._weight]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _row(String label, int i) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          Expanded(
              flex: 3,
              child: TextField(
                  controller: _score[i],
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: label, suffixText: '%'),
                  onChanged: (_) => setState(() {}))),
          const SizedBox(width: 12),
          Expanded(
              flex: 2,
              child: TextField(
                  controller: _weight[i],
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: t('Weight'), suffixText: '%'),
                  onChanged: (_) => setState(() {}))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    // Arabic-Indic digits and the Arabic decimal mark are what many Saudi keyboards type.
    double? n(TextEditingController c) => double.tryParse(c.text.trim().replaceAll('٫', '.').replaceAllMapped(
        RegExp('[٠-٩]'), (m) => '${m[0]!.codeUnitAt(0) - 0x660}'));
    final r = weighted(_score.map(n).toList(), _weight.map(n).toList());
    final weights = _weight.map(n).fold<double>(0, (a, w) => a + (w ?? 0));
    return Scaffold(
      appBar: AppBar(title: Text(t('Weighted percentage'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(t('Each university sets its own weights. Check your college\'s admission page and change them here.'),
            style: TextStyle(color: muted(context))),
        const SizedBox(height: 16),
        _row(t('High school'), 0),
        _row(t('Qudurat'), 1),
        _row(t('Tahsili'), 2),
        const SizedBox(height: 8),
        Text(
          r != null
              ? t('Your weighted percentage: {p}%', {'p': r.toStringAsFixed(2)})
              : (weights - 100).abs() > .01
                  ? t('The weights must add up to 100 (now {n}).', {'n': weights.toStringAsFixed(0)})
                  : t('Enter your three results (0-100).'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ]),
    );
  }
}
