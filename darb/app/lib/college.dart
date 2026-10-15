import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'api.dart';
import 'cards.dart';
import 'college_exam.dart';
import 'college_logic.dart';
import 'db.dart';
import 'home.dart';
import 'i18n.dart';
import 'logic.dart';
import 'study.dart';
import 'upload.dart';
import 'widgets.dart';

const materialKinds = {
  'slides': (Icons.slideshow_outlined, 'Lecture slides'),
  'notes': (Icons.description_outlined, 'Notes / handouts'),
  'book': (Icons.menu_book_outlined, 'Textbook'),
  'photos': (Icons.photo_camera_outlined, 'Photos of pages / board'),
  'syllabus': (Icons.event_note_outlined, 'Syllabus / course plan'),
  'past_exam': (Icons.history_edu_outlined, 'Past quiz / exam'),
};
const assessmentKinds = {'quiz': 'Quiz', 'midterm': 'Midterm', 'final': 'Final', 'test': 'Test', 'other': 'Other'};

String modeLabel(Mode m) => switch (m) { Mode.sprint => t('Sprint'), Mode.compressed => t('Compressed'), Mode.long => t('Long-term') };

String countdown(int? d) => d == null
    ? t('No date set')
    : d == 0
        ? t('Today')
        : d == 1
            ? t('Tomorrow')
            : App.lang == 'ar'
                ? (d == 2 ? 'بعد يومين' : (d <= 10 ? 'بعد $d أيام' : 'بعد $d يومًا')) // Arabic dual and plural forms
                : t('In {n} days', {'n': d});

Widget header(BuildContext context, String text, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
      child: Row(children: [
        Expanded(child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold))),
        if (trailing != null) trailing,
      ]),
    );

/// The College tab: today's plan across courses, the AI budget, and the courses.
class CollegeScreen extends StatelessWidget {
  const CollegeScreen({super.key});

  Future<(List<PlanItem>, List<Json>, Map<String, Json?>)> _load() async {
    final list = await courses();
    final next = <String, Json?>{};
    for (final c in list) {
      next[c['id']] = (await upcoming(courseId: c['id'])).firstOrNull;
    }
    return (await todayPlan(), list, next);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(t('College')), actions: const [SyncButton()]),
        floatingActionButton: FloatingActionButton.extended(
            icon: const Icon(Icons.add), label: Text(t('Course')), onPressed: () => editCourse(context)),
        body: Live(
          load: _load,
          builder: (context, data) {
            final (plan, list, next) = data;
            return RefreshIndicator(
              onRefresh: () async {
                final err = await Api.sync();
                if (err != null && context.mounted) toast(context, err);
              },
              child: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 96), children: [
                const OnlineBanner(),
                if (!Api.configured)
                  Card(child: ListTile(leading: const Icon(Icons.cloud_off), title: Text(t('Not connected')), subtitle: Text(t('Add your server token in Settings.')))),
                const BudgetLine(),
                header(context, t('Today')),
                if (plan.isEmpty)
                  Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(list.isEmpty ? t('Add a course, then its material and its next quiz or exam.') : t('Nothing planned: no quiz or exam in the next 3 weeks.'),
                          style: TextStyle(color: muted(context)))),
                for (final p in plan) PlanCard(p),
                header(context, t('Courses')),
                for (final c in list)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.school_outlined),
                      title: autoText(c['name'] ?? ''),
                      subtitle: Text([
                        if ((c['code'] ?? '').toString().isNotEmpty) c['code'],
                        if (next[c['id']] != null) '${next[c['id']]!['title']}: ${countdown(daysUntil(next[c['id']]!['date']))}',
                      ].join(' · ')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CourseScreen(c['id']))),
                    ),
                  ),
              ]),
            );
          },
        ),
      );
}

/// "AI budget: $8.20 of $10 left this month" (students; the owner has no cap).
class BudgetLine extends StatelessWidget {
  const BudgetLine({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: Api.me,
        builder: (_, me, __) => me == null || me['cap_usd'] == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                    t('AI budget: \${left} of \${cap} left this month', {
                      'left': (me['remaining_usd'] as num).toStringAsFixed(2),
                      'cap': (me['cap_usd'] as num).toStringAsFixed(0),
                    }),
                    style: TextStyle(color: (me['remaining_usd'] as num) < 1 ? Colors.orange : muted(context), fontSize: 13)),
              ),
      );
}

class PlanCard extends StatelessWidget {
  final PlanItem p;
  const PlanCard(this.p, {super.key});

  @override
  Widget build(BuildContext context) {
    final a = p.assessment;
    final d = daysUntil(a['date']);
    final cs = Theme.of(context).colorScheme;
    return Card(
      shape: p.behind ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Colors.orange)) : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${p.course} · ${a['title']}', style: const TextStyle(fontWeight: FontWeight.bold)),
          Text(
              p.morning
                  ? t('Exam day: a 10-minute check of your weakest points, nothing new.')
                  : '${countdown(d)} · ${modeLabel(p.mode)} · ${t('{n} min today', {'n': p.minutes})}',
              style: TextStyle(color: cs.onSurfaceVariant)),
          if (p.behind)
            Text(t('You are behind: yesterday\'s plan wasn\'t done. Catch up today.'), style: const TextStyle(color: Colors.orange, fontSize: 13)),
          if (p.practiceDay) Text(t('Good day for a practice exam.'), style: TextStyle(color: cs.tertiary, fontSize: 13)),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: Text(p.morning ? t('Morning check') : t('Start')),
              onPressed: () => p.morning ? startMorning(context, a) : startStudy(context, a, p.minutes),
            ),
            const SizedBox(width: 8),
            TextButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AssessmentScreen(a['id']))), child: Text(t('Details'))),
          ]),
        ]),
      ),
    );
  }
}

Future<void> editCourse(BuildContext context, [Json? course]) async {
  final name = TextEditingController(text: course?['name']);
  final code = TextEditingController(text: course?['code']);
  var lang = (course?['lang'] ?? (App.lang == 'ar' ? 'ar' : 'en')) as String;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(course == null ? t('New course') : t('Edit course')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, autofocus: true, decoration: InputDecoration(labelText: t('Name, e.g. Calculus II'))),
          TextField(controller: code, decoration: InputDecoration(labelText: t('Code (optional), e.g. MATH106'))),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'en', label: Text(t('English'))),
              ButtonSegment(value: 'ar', label: Text(t('Arabic'))),
              ButtonSegment(value: 'mixed', label: Text(t('Mixed'))),
            ],
            selected: {lang},
            onSelectionChanged: (v) => setState(() => lang = v.first),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, name.text.trim().isNotEmpty), child: Text(t('Save'))),
        ],
      ),
    ),
  );
  if (ok != true) return;
  await Db.put('course', {...?course, 'name': name.text.trim(), 'code': code.text.trim(), 'lang': lang, 'created_at': course?['created_at'] ?? nowMs()});
  Api.sync().ignore();
}

Future<bool> confirm(BuildContext context, String title, String body, {String ok = 'Delete'}) async =>
    await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(title: Text(title), content: Text(body), actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t('Cancel'))),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t(ok))),
            ])) ==
    true;

class CourseScreen extends StatelessWidget {
  final String id;
  const CourseScreen(this.id, {super.key});

  Future<(Json?, List<Json>, List<Json>, Map<String, Json?>, Json?, int)> _load() async {
    final c = await Db.get(id);
    final assess = (await courseDocs('assessment', id))
      ..sort((a, b) => (daysUntil(a['date']) ?? 9999).compareTo(daysUntil(b['date']) ?? 9999));
    final mats = (await courseDocs('material', id))..sort((a, b) => ((a['created_at'] as int?) ?? 0).compareTo((b['created_at'] as int?) ?? 0));
    final ing = {for (final m in mats) m['id'] as String: await ingestOf(m['id'])};
    return (c, assess, mats, ing, await Db.get('profile-$id'), (await courseCards(id)).length);
  }

  @override
  Widget build(BuildContext context) => Live(
        load: _load,
        builder: (context, data) {
          final (c, assess, mats, ing, profile, cardCount) = data;
          if (c == null) return Scaffold(appBar: AppBar(), body: Center(child: Text(t('Course deleted'))));
          return Scaffold(
            appBar: AppBar(title: Text(c['name'] ?? ''), actions: [
              const SyncButton(),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'edit') editCourse(context, c);
                  if (v == 'delete' &&
                      await confirm(context, t('Delete this course?'), t('Its assessments and materials are removed from your list. Cards stay in the Cards tab.'))) {
                    for (final x in assess) {
                      await Db.put('assessment', x, deleted: true);
                    }
                    for (final x in mats) {
                      await Db.put('material', x, deleted: true);
                    }
                    await Db.put('course', c, deleted: true);
                    Api.sync().ignore();
                    if (context.mounted) Navigator.pop(context);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'edit', child: Text(t('Edit course'))),
                  PopupMenuItem(value: 'delete', child: Text(t('Delete course'))),
                ],
              ),
            ]),
            body: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 40), children: [
              const OnlineBanner(),
              header(context, t('Quizzes & exams'),
                  trailing: TextButton.icon(icon: const Icon(Icons.add), label: Text(t('Add')), onPressed: () => newAssessment(context, id))),
              if (assess.isEmpty)
                Text(t('Add your next quiz or exam, or upload the syllabus and the app proposes them.'), style: TextStyle(color: muted(context))),
              for (final a in assess) AssessmentTile(a),
              header(context, t('Material'),
                  trailing: TextButton.icon(icon: const Icon(Icons.upload_file), label: Text(t('Add')), onPressed: () => addMaterial(context, id))),
              if (mats.isEmpty)
                Text(t('Upload slides, notes, a textbook, photos, the syllabus or past exams.'), style: TextStyle(color: muted(context))),
              for (final m in mats) MaterialTile(m, ing[m['id']]),
              if (profile != null) ...[
                header(context, t('Your professor\'s exams')),
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Md('${profile['style'] ?? ''}', style: const TextStyle(fontSize: 14)),
                          if (((profile['traps'] as List?) ?? []).isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(t('Traps'), style: const TextStyle(fontWeight: FontWeight.bold)),
                            for (final tr in (profile['traps'] as List)) Md('• $tr', style: const TextStyle(fontSize: 14)),
                          ],
                          const SizedBox(height: 6),
                          Text(
                              (profile['formats'] as Map? ?? {})
                                  .entries
                                  .where((e) => (e.value as num) > 0)
                                  .map((e) => '${t(e.key.toString())} ${((e.value as num) * 100).round()}%')
                                  .join(' · '),
                              style: TextStyle(color: muted(context), fontSize: 12)),
                        ]))),
              ],
              header(context, t('Cards')),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.style_outlined),
                  title: Text(t('{n} cards', {'n': cardCount})),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CardsScreen(course: id))),
                ),
              ),
            ]),
          );
        },
      );
}

class AssessmentTile extends StatelessWidget {
  final Json a;
  const AssessmentTile(this.a, {super.key});
  @override
  Widget build(BuildContext context) {
    final d = daysUntil(a['date']);
    final proposed = a['status'] == 'proposed';
    return Card(
      child: ListTile(
        leading: Icon(proposed ? Icons.help_outline : Icons.event_available, color: proposed ? Colors.amber : null),
        title: autoText('${a['title']}'),
        subtitle: Text([
          if (proposed) t('Proposed from the syllabus: tap to confirm'),
          if (!proposed) countdown(d),
          if (a['date'] == null && a['weeks'] != null) t('week {w}', {'w': a['weeks']}),
          if (a['weight_pct'] != null) '${a['weight_pct']}%',
        ].join(' · ')),
        trailing: d != null && d < 0 ? Text(t('Past'), style: TextStyle(color: Theme.of(context).colorScheme.outlineVariant)) : Icon(Icons.chevron_right),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AssessmentScreen(a['id']))),
      ),
    );
  }
}

Future<void> newAssessment(BuildContext context, String courseId) async {
  final a = await Db.put('assessment', {
    'course_id': courseId,
    'kind': 'quiz',
    'title': t('Quiz'),
    'date': null,
    'scope': [],
    'hints': '',
    'status': 'active',
    'source': 'manual',
    'created_at': nowMs(),
  });
  if (context.mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => AssessmentScreen(a['id'])));
}

// ---------------- material ----------------

class MaterialTile extends StatelessWidget {
  final Json m;
  final Json? ing;
  const MaterialTile(this.m, this.ing, {super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: Uploads.progress,
        builder: (context, progress, _) => ValueListenableBuilder(
          valueListenable: Uploads.errors,
          builder: (context, errors, _) {
            final up = progress[m['id']];
            final status = up != null ? 'uploading' : (ing?['status'] ?? (errors[m['id']] != null ? 'failed' : 'waiting'));
            final err = errors[m['id']] ?? ing?['error'];
            return Card(
              child: ListTile(
                leading: Icon(materialKinds[m['kind']]?.$1 ?? Icons.insert_drive_file_outlined),
                title: autoText(m['title'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(statusText(status, ing, up), style: TextStyle(color: status == 'failed' ? Colors.redAccent : muted(context), fontSize: 13)),
                  if (status == 'failed' && err != null) Text(t('$err'), style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                  if (up != null || const {'converting', 'mapping', 'queued'}.contains(status))
                    Padding(padding: const EdgeInsets.only(top: 4), child: LinearProgressIndicator(value: up)),
                ]),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MaterialScreen(m['id']))),
              ),
            );
          },
        ),
      );
}

String statusText(String status, Json? ing, double? up) => switch (status) {
      'uploading' => t('Uploading {p}%', {'p': ((up ?? 0) * 100).round()}),
      'waiting' => t('Waiting to upload'),
      'queued' => t('Queued on the server'),
      'converting' => t('Converting'),
      'mapping' => t('Finding chapters and sections'),
      'ready' => [
          if (ing?['pages'] != null) t('{n} pages', {'n': ing!['pages']}),
          t('{n} sections', {'n': ((ing?['structure'] as List?) ?? []).length}),
        ].join(' · '),
      'failed' => t('Failed'),
      _ => status,
    };

Future<void> addMaterial(BuildContext context, String courseId) async {
  final kind = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        Padding(padding: const EdgeInsets.all(16), child: Text(t('What are you adding?'), style: Theme.of(context).textTheme.titleMedium)),
        for (final e in materialKinds.entries) ListTile(leading: Icon(e.value.$1), title: Text(t(e.value.$2)), onTap: () => Navigator.pop(context, e.key)),
      ]),
    ),
  );
  if (kind == null || !context.mounted) return;
  var paths = <String>[];
  String? name;
  if (kind == 'photos') {
    final src = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(leading: const Icon(Icons.photo_camera), title: Text(t('Take photos')), onTap: () => Navigator.pop(context, 'camera')),
              ListTile(leading: const Icon(Icons.photo_library), title: Text(t('Choose from gallery')), onTap: () => Navigator.pop(context, 'gallery')),
            ])));
    if (src == 'gallery') {
      paths = [for (final x in await ImagePicker().pickMultiImage(maxWidth: 2400, imageQuality: 88)) x.path];
    } else if (src == 'camera') {
      while (context.mounted) {
        final x = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 2400, imageQuality: 88);
        if (x == null) break;
        paths.add(x.path);
        if (!context.mounted || !await confirm(context, t('{n} photo(s)', {'n': paths.length}), t('Take another photo?'), ok: 'Another')) break;
      }
    }
    name = t('Photos {date}', {'date': DateTime.now().toString().substring(0, 10)});
  } else {
    final r = await FilePicker.pickFiles(
        type: FileType.custom, allowedExtensions: ['pdf', 'pptx', 'ppt', 'docx', 'doc', 'odp', 'odt', 'jpg', 'jpeg', 'png', 'webp'], allowMultiple: true);
    paths = [for (final f in r?.files ?? <PlatformFile>[]) if (f.path != null) f.path!];
    name = r?.files.firstOrNull?.name.replaceAll(RegExp(r'\.[^.]+$'), '');
  }
  if (paths.isEmpty || !context.mounted) return;
  final title = TextEditingController(text: name);
  final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
            title: Text(t(materialKinds[kind]!.$2)),
            content: TextField(controller: title, decoration: InputDecoration(labelText: t('Title, e.g. Lecture 3: Integration by parts'))),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t('Cancel'))),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t('Upload'))),
            ],
          ));
  if (ok != true) return;
  await Uploads.add(courseId: courseId, kind: kind, title: title.text.trim().isEmpty ? (name ?? kind) : title.text.trim(), files: paths);
}

class MaterialScreen extends StatelessWidget {
  final String id;
  const MaterialScreen(this.id, {super.key});

  @override
  Widget build(BuildContext context) => Live(
        load: () async => (await Db.get(id), await ingestOf(id)),
        builder: (context, data) {
          final (m, ing) = data;
          if (m == null) return Scaffold(appBar: AppBar(), body: Center(child: Text(t('Deleted'))));
          final sections = ((ing?['structure'] as List?) ?? []).cast<Map>();
          return Scaffold(
            appBar: AppBar(title: Text(m['title'] ?? ''), actions: [
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (!await confirm(context, t('Delete this material?'), t('Cards made from it stay.'))) return;
                  await Db.put('material', m, deleted: true);
                  Api.sync().ignore();
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ]),
            body: ListView(padding: const EdgeInsets.all(12), children: [
              Text(statusText(ing?['status'] ?? 'waiting', ing, Uploads.progress.value[id]), style: TextStyle(color: muted(context))),
              if (ing?['status'] == 'failed') ...[
                Text(t('${ing?['error'] ?? ''}'), style: const TextStyle(color: Colors.redAccent)),
                TextButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: Text(t('Try again')),
                    onPressed: () => busy(context, t('Starting…'), () => Api.call('POST', 'college/process', body: {'material_id': id}))),
              ],
              for (final s in sections)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsetsDirectional.only(start: s['level'] == 2 ? 28 : 4),
                  title: Md('${s['title']}', style: TextStyle(fontWeight: s['level'] == 1 ? FontWeight.bold : null)),
                  subtitle: Text('${t('p.')} ${s['start']}–${s['end']}${s['kind'] == 'exercises' ? ' · ${t('exercises')}' : ''}'),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SourcePage(id, s['start'] as int, m['title'] ?? ''))),
                ),
            ]),
          );
        },
      );
}

// ---------------- assessment ----------------

class AssessmentScreen extends StatefulWidget {
  final String id;
  const AssessmentScreen(this.id, {super.key});
  @override
  State<AssessmentScreen> createState() => _AssessmentScreenState();
}

class _AssessmentScreenState extends State<AssessmentScreen> {
  final hints = TextEditingController();
  bool hintsLoaded = false;

  Future<(Json?, Json?, Scope?, Readiness2?, Map<String, Json>)> _load() async {
    final a = await Db.get(widget.id);
    if (a == null) return (null, null, null, null, <String, Json>{});
    if (!hintsLoaded) {
      hints.text = a['hints'] ?? '';
      hintsLoaded = true;
    }
    final s = await Scope.load(a);
    final sheets = {for (final k in ['summary', 'facts', 'formulas', 'night']) k: await Db.get('sheet-${a['id']}-$k')}..removeWhere((_, v) => v == null);
    return (a, await prepOf(a['id']), s, s.cards.isEmpty ? null : await readinessOf(s), sheets.cast<String, Json>());
  }

  Future<void> _save(Json a, Map<String, Object?> changes) async {
    await Db.put('assessment', {...a, ...changes});
    Api.sync().ignore();
  }

  @override
  Widget build(BuildContext context) => Live(
        load: _load,
        builder: (context, data) {
          final (a, prep, scope, ready, sheets) = data;
          if (a == null) return Scaffold(appBar: AppBar(), body: Center(child: Text(t('Deleted'))));
          final d = daysUntil(a['date']);
          final cs = Theme.of(context).colorScheme;
          return Scaffold(
            appBar: AppBar(title: Text(a['title'] ?? ''), actions: [
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (!await confirm(context, t('Delete this assessment?'), t('Its cards stay.'))) return;
                  await Db.put('assessment', a, deleted: true);
                  Api.sync().ignore();
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ]),
            body: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 48), children: [
              const OnlineBanner(),
              if (a['status'] == 'proposed')
                Card(
                  color: cs.tertiaryContainer,
                  child: ListTile(
                    title: Text(t('Proposed from your syllabus')),
                    subtitle: Text([if (a['weeks'] != null) t('week {w}', {'w': a['weeks']}), if ((a['coverage'] ?? '').isNotEmpty) a['coverage']].join(' · ')),
                    trailing: FilledButton(onPressed: () => _save(a, {'status': 'active'}), child: Text(t('Confirm'))),
                  ),
                ),
              _details(context, a),
              header(context, t('What it covers'),
                  trailing: TextButton(
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ScopePicker(a))), child: Text(t('Choose')))),
              Text(
                  ((a['scope'] as List?) ?? []).isEmpty
                      ? t('Nothing chosen yet: pick the lectures / chapters this covers.')
                      : t('{n} sections chosen', {'n': (a['scope'] as List).length}),
                  style: TextStyle(color: muted(context))),
              const SizedBox(height: 8),
              TextField(
                controller: hints,
                minLines: 1,
                maxLines: 5,
                decoration: InputDecoration(labelText: t('Professor\'s hints (e.g. "focus on chapter 3", "no proofs")'), border: const OutlineInputBorder()),
                onChanged: (v) => _save(a, {'hints': v}),
              ),
              header(context, t('Prepare')),
              PrepCard(a, prep),
              if (scope != null && scope.cards.isNotEmpty) ...[
                header(context, t('Readiness')),
                ReadinessCard(scope, ready!),
                header(context, '${t('Study')} · ${modeLabel(scope.mode)}'),
                Text(switch (scope.mode) {
                  Mode.sprint => t('Short on time: each card comes back in this session until you get it right twice, most valuable first.'),
                  Mode.compressed => t('Spread over the days left, spaced so it sticks until the exam. Practice exams at the midpoint and 2 days before.'),
                  Mode.long => t('Spaced repetition up to the exam date, plus review of earlier material.'),
                }, style: TextStyle(color: muted(context), fontSize: 13)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final m in [15, 30, 45, 60, 90, 120])
                    ActionChip(avatar: const Icon(Icons.timer_outlined, size: 18), label: Text(t('{n} min', {'n': m})), onPressed: () => startStudy(context, a, m)),
                ]),
                if (d != null && d <= 1) ...[
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(icon: const Icon(Icons.wb_twilight), label: Text(t('Morning check (10 min)')), onPressed: () => startMorning(context, a)),
                ],
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.quiz_outlined),
                  label: Text(t('Practice exam')),
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PracticeSetup(a))),
                ),
                header(context, t('Sheets')),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final (k, label, icon) in [
                    ('summary', 'Summary', Icons.summarize_outlined),
                    ('facts', 'Key facts', Icons.checklist),
                    ('formulas', 'Formulas', Icons.functions),
                    ('night', 'Night before', Icons.nightlight_outlined),
                  ])
                    if (sheets[k] != null)
                      ActionChip(
                          avatar: Icon(icon, size: 18),
                          label: Text(t(label)),
                          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SheetScreen(t(label), sheets[k]!['content'])))),
                  ActionChip(
                    avatar: const Icon(Icons.auto_awesome, size: 18),
                    label: Text(sheets['night'] == null ? t('Make my night-before sheet') : t('Remake night-before sheet')),
                    onPressed: () async {
                      await Api.sync();
                      if (!context.mounted) return;
                      final r = await busy(context, t('Writing your night-before sheet…'), () => Api.ai('college/night', {'assessment_id': a['id']}));
                      if (r == null) return;
                      await Api.sync();
                      if (context.mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => SheetScreen(t('Night before'), r['content'])));
                    },
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.calculate_outlined, size: 18),
                    label: Text(t('Worked problems')),
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CardsScreen(course: a['course_id'], filter: 'worked'))),
                  ),
                ]),
              ],
            ]),
          );
        },
      );

  Widget _details(BuildContext context, Json a) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            TextFormField(
              initialValue: a['title'],
              decoration: InputDecoration(labelText: t('Title')),
              onChanged: (v) => _save(a, {'title': v}),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: assessmentKinds.containsKey(a['kind']) ? a['kind'] : 'other',
                  decoration: InputDecoration(labelText: t('Kind')),
                  items: [for (final e in assessmentKinds.entries) DropdownMenuItem(value: e.key, child: Text(t(e.value)))],
                  onChanged: (v) => _save(a, {'kind': v}),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.event),
                  label: FittedBox(fit: BoxFit.scaleDown, child: Text(a['date'] ?? t('Set date'), maxLines: 1)),
                  onPressed: () async {
                    final now = DateTime.now();
                    final picked = await showDatePicker(
                        context: context,
                        firstDate: now.subtract(const Duration(days: 1)),
                        lastDate: now.add(const Duration(days: 365)),
                        initialDate: DateTime.tryParse(a['date'] ?? '') ?? now.add(const Duration(days: 3)));
                    if (picked != null) _save(a, {'date': picked.toIso8601String().substring(0, 10), if (a['status'] == 'proposed') 'status': 'active'});
                  },
                ),
              ),
            ]),
            Row(children: [
              Expanded(
                child: TextFormField(
                  initialValue: a['minutes']?.toString() ?? '',
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: t('Duration (min)')),
                  onChanged: (v) => _save(a, {'minutes': int.tryParse(v)}),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  initialValue: a['weight_pct']?.toString() ?? '',
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: t('Weight (% of grade)')),
                  onChanged: (v) => _save(a, {'weight_pct': num.tryParse(v)}),
                ),
              ),
            ]),
          ]),
        ),
      );
}

/// Pick the sections an assessment covers, by material. Ticking a chapter ticks its sections.
class ScopePicker extends StatefulWidget {
  final Json a;
  const ScopePicker(this.a, {super.key});
  @override
  State<ScopePicker> createState() => _ScopePickerState();
}

class _ScopePickerState extends State<ScopePicker> {
  late final Set<String> picked = scopeKeys(widget.a);

  Future<List<(Json, List<Map>)>> _load() async {
    final out = <(Json, List<Map>)>[];
    for (final m in (await courseDocs('material', widget.a['course_id']))..sort((a, b) => ((a['created_at'] as int?) ?? 0).compareTo((b['created_at'] as int?) ?? 0))) {
      final ing = await ingestOf(m['id']);
      if (ing?['status'] == 'ready' && m['kind'] != 'syllabus' && m['kind'] != 'past_exam') out.add((m, ((ing!['structure'] as List?) ?? []).cast<Map>()));
    }
    return out;
  }

  Future<void> _save() async {
    final a = await Db.get(widget.a['id']);
    await Db.put('assessment', {
      ...?a,
      'scope': [
        for (final k in picked) {'material_id': k.split('/')[0], 'section_id': k.split('/')[1]}
      ],
    });
    Api.sync().ignore();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(t('What it covers')), actions: [
          TextButton.icon(
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: Text(t('Suggest')),
            onPressed: () async {
              await Api.sync();
              if (!context.mounted) return;
              final r = await busy(context, t('Matching the syllabus to your material…'), () => Api.ai('college/suggest_scope', {'assessment_id': widget.a['id']}));
              if (r == null) return;
              setState(() => picked
                ..clear()
                ..addAll([for (final s in (r['scope'] as List).cast<Map>()) sectionKey(s)]));
              _save();
              if (context.mounted && picked.isEmpty) toast(context, t('No clear match: pick the sections yourself.'));
            },
          ),
        ]),
        body: FutureBuilder<List<(Json, List<Map>)>>(
          future: _load(),
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            if (snap.data!.isEmpty) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(t('Upload this course\'s material first; it appears here once processed.'), textAlign: TextAlign.center)));
            return ListView(children: [
              for (final (m, secs) in snap.data!) ...[
                Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: autoText(m['title'] ?? '', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold))),
                for (final s in secs)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsetsDirectional.only(start: s['level'] == 2 ? 36 : 8, end: 8),
                    value: picked.contains('${m['id']}/${s['id']}'),
                    title: autoText('${s['title']}', style: TextStyle(fontWeight: s['level'] == 1 ? FontWeight.bold : null)),
                    subtitle: Text('${t('p.')} ${s['start']}–${s['end']}'),
                    onChanged: (v) {
                      setState(() {
                        final key = '${m['id']}/${s['id']}';
                        final children = s['level'] == 1
                            ? [for (final c in secs) if (c['level'] == 2 && (c['start'] as int) >= (s['start'] as int) && (c['end'] as int) <= (s['end'] as int)) '${m['id']}/${c['id']}']
                            : <String>[];
                        if (v == true) {
                          picked.add(key);
                          picked.addAll(children);
                        } else {
                          picked.remove(key);
                          picked.removeAll(children);
                        }
                      });
                      _save();
                    },
                  ),
              ],
            ]);
          },
        ),
      );
}

/// Preparation status, and the button that asks for an estimate and starts it.
class PrepCard extends StatelessWidget {
  final Json a;
  final Json? prep;
  const PrepCard(this.a, this.prep, {super.key});

  Future<void> _start(BuildContext context) async {
    await Api.sync();
    if (!context.mounted) return;
    final res = await busy(context, t('Estimating…'), () => Api.ai('college/prepare', {'assessment_id': a['id']}));
    if (res == null || !context.mounted) return;
    final e = res['estimate'] as Map;
    final d = daysUntil(a['date']);
    final background = d != null && d > 3;
    final me = Api.me.value;
    final ok = await confirm(
        context,
        t('Prepare this assessment?'),
        [
          t('{p} pages, {s} sections → about {c} cards.', {'p': e['pages'], 's': e['sections'], 'c': e['cards']}),
          background
              ? t('Cost: about \${usd} (prepared in the background at half price; usually ready within the hour).', {'usd': e['usd_batch']})
              : t('Cost: about \${usd} (ready in a few minutes).', {'usd': e['usd']}),
          if (me?['remaining_usd'] != null) t('Your budget left this month: \${left}.', {'left': (me!['remaining_usd'] as num).toStringAsFixed(2)}),
          if ((e['unprocessed'] as num) > 0) t('{n} sections are still processing and are left out.', {'n': e['unprocessed']}),
        ].join('\n\n'),
        ok: 'Prepare');
    if (!ok || !context.mounted) return;
    await busy(context, t('Starting…'), () => Api.ai('college/prepare', {'assessment_id': a['id'], 'confirm': true}));
    Api.sync().ignore();
  }

  @override
  Widget build(BuildContext context) {
    final p = prep;
    final status = p?['status'];
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (p == null)
            Text(t('The AI reads the chosen sections, extracts everything examinable, ranks it for this assessment and writes cards, practice questions and sheets.'),
                style: TextStyle(color: muted(context))),
          if (status == 'queued' || status == 'running') ...[
            Text(t('Preparing: {stage}', {'stage': t(p!['stage'] ?? '')})),
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator()),
          ],
          if (status == 'waiting') ...[
            Text(t('Preparing in the background ({stage}); cards arrive on a later sync.', {'stage': t(p!['stage'] ?? '')})),
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator()),
          ],
          if (status == 'failed') Text(t('Preparation failed: {e}', {'e': p!['error'] ?? ''}), style: TextStyle(color: cs.error)),
          if (status == 'done')
            Text(t('{c} cards from {k} knowledge points · \${usd}', {'c': p!['cards_added'], 'k': p['kps'], 'usd': (p['cost_usd'] as num).toStringAsFixed(2)}) +
                ((p['unverified'] ?? 0) > 0 ? ' · ${t('{n} problems dropped: their answers didn\'t check out', {'n': p['unverified']})}' : '') +
                ((p['uncovered'] ?? 0) > 0 ? ' · ${t('{n} points without a card', {'n': p['uncovered']})}' : '')),
          if (status != 'queued' && status != 'running' && status != 'waiting')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.icon(
                icon: const Icon(Icons.auto_awesome),
                label: Text(status == 'done' ? t('Prepare again (new sections only)') : t('Prepare')),
                onPressed: ((a['scope'] as List?) ?? []).isEmpty ? null : () => _start(context),
              ),
            ),
        ]),
      ),
    );
  }
}

class ReadinessCard extends StatelessWidget {
  final Scope s;
  final Readiness2 r;
  const ReadinessCard(this.s, this.r, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(t('Predicted mark'), style: const TextStyle(fontWeight: FontWeight.bold))),
            Text('${(r.low * 100).round()}–${(r.high * 100).round()}%', style: Theme.of(context).textTheme.titleLarge),
          ]),
          Text(
              [
                t('An estimate from your recall ({p}%)', {'p': (r.recall * 100).round()}),
                if (r.practice != null) t('and your last practice exam ({p}%)', {'p': (r.practice! * 100).round()}),
                if (r.reviews < 30) t('· few answers yet, so the range is wide'),
              ].join(' '),
              style: TextStyle(color: muted(context), fontSize: 12)),
          const SizedBox(height: 10),
          FutureBuilder<Map<String, String>>(
            future: _sectionNames(r.sections.keys),
            builder: (context, snap) => Column(children: [
              for (final sc in r.sections.values.where((x) => x.cards > 0))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: autoText(snap.data?[sc.key] ?? '…', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                      Text(t('{m}/{n} known · {s} seen', {'m': sc.mastered, 'n': sc.cards, 's': sc.seen}), style: TextStyle(fontSize: 12, color: muted(context))),
                    ]),
                    const SizedBox(height: 3),
                    LinearProgressIndicator(
                        value: sc.mastered / sc.cards,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                        color: sc.mastered / sc.cards >= .8 ? Colors.green : cs.primary,
                        backgroundColor: cs.primary.withOpacity(.15)),
                  ]),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

Future<Map<String, String>> _sectionNames(Iterable<String> keys) async {
  final out = <String, String>{};
  for (final k in keys) {
    final parts = k.split('/');
    final ing = await ingestOf(parts[0]);
    final s = ((ing?['structure'] as List?) ?? []).cast<Map>().where((s) => s['id'] == parts[1]).firstOrNull;
    out[k] = s?['title'] ?? k;
  }
  return out;
}

class SheetScreen extends StatelessWidget {
  final String title, content;
  const SheetScreen(this.title, this.content, {super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ListView(padding: const EdgeInsets.all(16), children: [Md(content)]),
      );
}

// ---------------- starting sessions ----------------

Future<void> startStudy(BuildContext context, Json a, int minutes) async {
  final s = await Scope.load(a);
  if (!context.mounted) return;
  if (s.cards.isEmpty) return toast(context, t('No cards yet: choose what it covers and prepare it first.'));
  if (s.mode == Mode.sprint) {
    final tri = plan(s, minutes);
    await Navigator.push(context, MaterialPageRoute(builder: (_) => TriageScreen(s, tri)));
  } else {
    final q = pacedQueue(s, minutes);
    if (q.isEmpty) return toast(context, t('Nothing due right now. Well done: try a practice exam.'));
    await Navigator.push(context, MaterialPageRoute(builder: (_) => StudyScreen(q, title: a['title'] ?? t('Study'), scheduler: s.scheduler)));
  }
}

Future<void> startMorning(BuildContext context, Json a) async {
  final s = await Scope.load(a);
  final q = morningCheck(s);
  if (!context.mounted) return;
  if (q.isEmpty) return toast(context, t('Nothing weak left. Read your night-before sheet and go get it!'));
  await Navigator.push(
      context, MaterialPageRoute(builder: (_) => StudyScreen(q, title: t('Morning check'), source: 'cram', scheduler: s.scheduler)));
}

/// What fits in the time: master now, skim on the summary sheet, skip.
class TriageScreen extends StatelessWidget {
  final Scope s;
  final Triage tri;
  const TriageScreen(this.s, this.tri, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget group(String title, String sub, List<Json> cards, Color color) => ExpansionTile(
          leading: CircleAvatar(backgroundColor: color.withOpacity(.2), child: Text('${cards.length}', style: TextStyle(color: color))),
          title: Text(title),
          subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
          children: [
            for (final c in cards.take(60))
              ListTile(
                dense: true,
                title: autoText(plain(c['question']), maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: Text('★' * (s.weight(c) * 5).round(), style: const TextStyle(color: Colors.amber, fontSize: 11)),
              ),
          ],
        );
    final masterMin = (tri.master.fold<double>(0, (t, c) => t + s.cost(c)) / 60).round();
    return Scaffold(
      appBar: AppBar(title: Text(t('{n} minutes', {'n': tri.minutes}))),
      body: ListView(padding: const EdgeInsets.all(8), children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
              tri.skim.isEmpty && tri.skip.isEmpty
                  ? t('Everything fits. Each card comes back until you get it right twice in a row.')
                  : t('Not everything fits in {n} minutes, so this is ordered by the marks it can earn you.', {'n': tri.minutes}),
              style: TextStyle(color: muted(context))),
        ),
        group(t('Master now'), t('about {n} min including repeats', {'n': masterMin}), tri.master, Colors.green),
        if (tri.skim.isNotEmpty) group(t('Skim'), t('read these on the summary sheet'), tri.skim, Colors.amber),
        if (tri.skip.isNotEmpty) group(t('Skip for now'), t('least likely to earn marks'), tri.skip, cs.outline),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
            icon: const Icon(Icons.play_arrow),
            label: Text(t('Start ({n} cards)', {'n': tri.master.length})),
            onPressed: tri.master.isEmpty
                ? null
                : () => Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                        builder: (_) => StudyScreen(tri.master,
                            title: s.assessment['title'] ?? t('Sprint'), source: 'study', custom: SprintSession(tri.master, s), scheduler: s.scheduler))),
          ),
        ),
      ),
    );
  }
}
