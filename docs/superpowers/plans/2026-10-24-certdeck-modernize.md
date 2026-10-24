# CertDeck Owner App Modernize Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the owner side of CertDeck into a minimal three-tab app (Today · Library · Me) whose home shows real weak spots with one-tap Drills, with a focus-mode study screen and a refined teal look, and tag every card so weak tags have data.

**Architecture:** Weak-spot detection is a pure function over cards + the last 14 days of `review` rows (new `lib/weak.dart`), unit-tested like `logic_test.dart`. UI changes are owner-only, gated on `App.isOwner` / `easy == false`; the student app (`EasyHome`, easy study, student Settings) must not change. Tags are a content task done in Claude Code under `content/certdeck-versions/`, pushed with a manage.py shell script like `import.py`.

**Tech Stack:** Flutter (Material 3, `flutter_test`), local sqlite `Db`, Django backend (untouched except a content script run in `manage.py shell`).

**Spec:** `docs/superpowers/specs/2026-10-24-certdeck-modernize-design.md` (read it; this plan argues from it). Mockups: `.superpowers/brainstorm/2152550-1792817363/content/`.

## Global Constraints

- Owner app only. Student app (`EasyHome`, `StudyScreen(easy: true)`, `SettingsScreen` as students see it) looks and behaves exactly as today.
- No new pub dependencies. Material icons and plain widgets.
- No tags, version number or labels above the card before answering (1.5.7 rule, `no-answer-giveaways`).
- Every visible string goes through `t()`; add Arabic to `lib/i18n.dart` for each new string. RTL must work.
- Theme: seed `#2dd4bf`, surface `#111316`, dark only; 14–16 px radius.
- Weak-spot window 14 days; weak tag = ≥ 4 answers and miss rate ≥ 0.35; Today shows ≤ 5 spots.
- Drills: `StudyScreen(..., source: 'cram')`, schedule normally.
- Owner college data is hidden, never deleted.
- Builds: Flutter at `/home/jehad/FlutterSDK/flutter/bin/flutter`; JDK 17 at `~/opt`; Gradle capped at 2 GB, never with the emulator running; delete `app/build` and stop Gradle after builds; release APKs arm64-only via `deploy/release-apk.sh`.
- Content: authored in Claude Code, never the API pack pipeline. Anything that writes to the production server (169.58.7.222) or publishes a release needs the user's go-ahead first.

## Review Focus

1. **Student role** — signing in as `qa-student` shows the same EasyHome, easy study and Settings as before (theme included).
2. **Brand-new or idle owner** — no reviews in 14 days, cards without tags, no `versions` docs: Today renders, "Fix these first" shows its empty line, nothing throws.
3. **Arabic** — every new screen reads right-to-left with translated strings; the progress ring and horizontal list flip correctly.
4. **No exam date / exam passed / final 7 days** — countdown line reads "No exam date set" (tap → Me), "Exam date passed", or amber; final-days Drill uses `buildCramQueue`.
5. **Rewrite-only Drill on a card with no versions** — falls back to the original instead of crashing or skipping.

Tests for 2 and 5 live in Task 1 and Task 2; 1, 3, 4 are checked by hand in Task 9.

---

### Task 1: Weak-spot detection

**Files:**
- Create: `app/lib/weak.dart`
- Test: `app/test/weak_test.dart`

**Interfaces:**
- Consumes: `Json`, `isSuspended`, `Db.cardsFor`, `Db.reviewsSince`, `Db.query('analysis')`, `startOfToday` from `logic.dart`/`db.dart`.
- Produces:
  ```dart
  enum WeakKind { tag, memorized, misconception, leech, ai }
  class WeakSpot {
    final WeakKind kind;
    final String title;        // "KMS", "Memorized", "Misconceptions", "Leeches", AI topic
    final int missed, answered; // tag: misses/answers; others: missed = count, answered = 0
    final List<String> cardIds; // what a Drill/open uses; empty for ai
    final Json? ai;             // the analysis weak_areas entry for kind == ai
    double get severity;        // tag: missRate * answered; others: cardIds.length (ai: 0, sorts last)
  }
  const weakWindowDays = 14;
  List<WeakSpot> weakSpots(List<Json> cards, List<Json> reviews, {Json? analysis});
  Future<List<WeakSpot>> loadWeakSpots(Json cert); // active cert's cards, reviews since now-14d, latest analysis for cert
  ```

- [ ] **Step 1: Write the failing tests** in `app/test/weak_test.dart`:

```dart
Json c(String id, {List<String> tags = const [], bool mis = false, bool leech = false, bool susp = false}) =>
    {'id': id, 'tags': tags, 'fsrs': {'state': 2}, if (mis) 'misconception': true, if (leech) 'leech': true, if (susp) 'suspended': true};
Json r(String id, bool ok, {int ver = 0}) => {'card_id': id, 'correct': ok, 'ver': ver, 'ts': 1};

test('a tag is weak at >= 4 answers and >= 35% missed, counting every version', () {
  final cards = [c('a', tags: ['KMS']), c('b', tags: ['KMS', 'S3'])];
  final rs = [r('a', false), r('a', false, ver: 1), r('b', true), r('b', true, ver: 2), r('b', true)];
  final s = weakSpots(cards, rs).where((w) => w.kind == WeakKind.tag).toList();
  expect(s.map((w) => w.title), ['KMS']); // S3: 3 answers, too few
  expect((s.first.missed, s.first.answered), (2, 5));
  expect(s.first.cardIds.toSet(), {'a', 'b'});
});
test('34% missed is not weak', () { /* 6 answers, 2 missed on one tag -> no tag spot */ });
test('memorized: right on the original, wrong on a rewrite', () {
  final s = weakSpots([c('a'), c('b')], [r('a', true), r('a', false, ver: 1), r('b', false), r('b', false, ver: 1)]);
  expect(s.singleWhere((w) => w.kind == WeakKind.memorized).cardIds, ['a']);
});
test('no ver data: no memorized spot', () {
  expect(weakSpots([c('a')], [{'card_id': 'a', 'correct': false, 'ts': 1}]).any((w) => w.kind == WeakKind.memorized), false);
});
test('misconceptions and unsuspended leeches', () {
  final s = weakSpots([c('a', mis: true), c('b', leech: true), c('d', leech: true, susp: true)], []);
  expect(s.singleWhere((w) => w.kind == WeakKind.misconception).cardIds, ['a']);
  expect(s.singleWhere((w) => w.kind == WeakKind.leech).cardIds, ['b']);
});
test('ai weak areas come from the latest analysis', () {
  final s = weakSpots([], [], analysis: {'weak_areas': [{'topic': 'IAM conditions', 'domain': '2', 'count': 15}]});
  expect(s.single.kind, WeakKind.ai);
  expect(s.single.title, 'IAM conditions');
});
test('sorted by severity, empty input is empty', () {
  expect(weakSpots([], []), isEmpty);
  // tag with 10 answers / 6 missed (3.6) sorts before 2 misconceptions (2) before ai (0)
});
test('cards without tags never make a tag spot', () { /* reviews on an untagged card -> no tag spot */ });
```

Fill in the two commented tests with real fixtures and assertions matching their comments.

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && /home/jehad/FlutterSDK/flutter/bin/flutter test test/weak_test.dart`
Expected: FAIL, `weak.dart` not found.

- [ ] **Step 3: Implement `weak.dart`** with the interface above. Rules: ignore reviews whose card isn't in `cards`; memorized = card has a review with `ver == 0 && correct == true` and a review with `ver >= 1 && correct == false` (missing `ver` counts as neither); group memorized into one spot (title "Memorized"). Sort descending by `severity`. `loadWeakSpots` filters cards to the cert via `Db.cardsFor(cert['id'])`, reviews via `Db.reviewsSince(nowMs() - weakWindowDays * dayMs)`, analysis = latest `analysis` doc for the cert by `created_at` (same query as `InsightsTab._load`).

- [ ] **Step 4: Run to verify they pass**

Run: `cd app && /home/jehad/FlutterSDK/flutter/bin/flutter test test/weak_test.dart`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add app/lib/weak.dart app/test/weak_test.dart
git commit -m "Weak spots: weak tags, memorized-not-understood, misconceptions, leeches, AI areas"
```

---

### Task 2: Drill queues and rewrite-only versions

**Files:**
- Modify: `app/lib/logic.dart:137-145` (`pickVersion`)
- Modify: `app/lib/weak.dart`
- Modify: `app/lib/study.dart:41-56,119` (`StudyScreen` param, `_next`)
- Test: `app/test/weak_test.dart`, `app/test/logic_test.dart`

**Interfaces:**
- Consumes: `WeakSpot` (Task 1), `retrievability`, `schedulerFor`, `dueOf`, `isSuspended`.
- Produces:
  ```dart
  (int, Json) pickVersion(Json card, List versions, {bool rewriteOnly = false});
  List<Json> drillQueue(WeakSpot w, List<Json> cards, {int limit = 20}); // in weak.dart
  // StudyScreen gains: final bool rewriteOnly; (default false)
  ```

- [ ] **Step 1: Write failing tests**

```dart
// logic_test.dart
test('rewriteOnly skips the original, and falls back to it with no versions', () {
  final card = {'id': 'a', 'ver': 2, 'question': 'orig'};
  final vs = [{'question': 'v1'}, {'question': 'v2'}];
  expect(pickVersion(card, vs, rewriteOnly: true).$1, 1); // 2 -> next would be 0, skip to 1
  expect(pickVersion({'id': 'a', 'ver': 0}, vs, rewriteOnly: true).$1, 1);
  expect(pickVersion(card, const [], rewriteOnly: true).$1, 0);
});
// weak_test.dart
test('drill: suspended out, due first, then least retained, capped', () {
  // 3 cards in w.cardIds: one suspended, one due yesterday, one not due -> [due, notDue]; limit: 1 -> [due]
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && /home/jehad/FlutterSDK/flutter/bin/flutter test test/logic_test.dart test/weak_test.dart`
Expected: FAIL (no named parameter `rewriteOnly`, no `drillQueue`).

- [ ] **Step 3: Implement.** `pickVersion`: when `rewriteOnly` and the computed index is 0 and `versions.isNotEmpty`, use 1. `drillQueue`: cards whose id is in `w.cardIds`, not suspended, due ones first (`dueOf <= nowMs()`), then ascending retrievability for the card's cert scheduler, `take(limit)`. New cards are allowed in a tag Drill. `StudyScreen.rewriteOnly` passes through to `pickVersion` in `_next`. Also load versions when `rewriteOnly` is true even if `rotate_versions` is off (`loading = App.settings['rotate_versions'] == true || widget.rewriteOnly`).

- [ ] **Step 4: Run all tests**

Run: `cd app && /home/jehad/FlutterSDK/flutter/bin/flutter test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add app/lib/logic.dart app/lib/weak.dart app/lib/study.dart app/test
git commit -m "Drills: queue per weak spot, rewrite-only versions"
```

---

### Task 3: Owner theme

**Files:**
- Modify: `app/lib/main.dart:31-55`

**Interfaces:**
- Produces: `ThemeData ownerTheme()` and `ThemeData studentTheme()` in `main.dart`; `darkTheme: App.isOwner ? ownerTheme() : studentTheme()`.

- [ ] **Step 1:** Move today's `ThemeData` verbatim into `studentTheme()`.
- [ ] **Step 2:** Write `ownerTheme()`: same seed/surface; `cardTheme` radius 16, elevation 0, `surfaceContainerLow`; `filledButtonTheme` / `outlinedButtonTheme` radius 14 and 14 px vertical padding; `navigationBarTheme` with `surface` background, `secondaryContainer` indicator, labels always shown; `listTileTheme` 16 px horizontal padding; `chipTheme` rounded (99) without border; `textTheme` body secondary via `onSurfaceVariant`; `appBarTheme` as today with `centerTitle: false`.
- [ ] **Step 3:** Confirm `MaterialApp` rebuilds on role change (it is keyed via `changes`; `UpdateGate` key includes role). Run `cd app && /home/jehad/FlutterSDK/flutter/bin/flutter analyze` → no new issues.
- [ ] **Step 4: Commit** `git commit -am "Owner theme: refined teal, student theme unchanged"`

---

### Task 4: Three tabs and the new Today

**Files:**
- Modify: `app/lib/main.dart:93-117` (`_ShellState._body`)
- Modify: `app/lib/home.dart` (rewrite `TodayScreen`; keep `studyCert`, `SyncButton`)
- Create: `app/lib/focus.dart` (`WeakSpotCard`, `WeakSpotsScreen`, `drill(context, WeakSpot)`)
- Modify: `app/lib/i18n.dart`

**Interfaces:**
- Consumes: `loadWeakSpots`, `drillQueue`, `WeakSpot` (Tasks 1–2); `buildQueue`, `buildExtraQueue`, `buildCramQueue`, `daysToExam`, `startOfToday`, `Db.reviewsSince`; `ExamScreen`, `GenerateTab`, `InsightsTab`, `StatsScreen`, `CardsScreen(filter:)`.
- Produces: `LibraryScreen` and the Me entry are consumed from Tasks 5–6; until then Shell may point at `CardsScreen()` and `SettingsScreen()`.
  ```dart
  Future<void> drill(BuildContext context, WeakSpot w); // focus.dart
  class WeakSpotsScreen extends StatelessWidget {}      // "See all": full list + "Analyze weak areas" button (InsightsTab._run logic)
  ```

- [ ] **Step 1: Shell.** Owner tabs: Today (`Icons.home_outlined`/`home`), Library (`Icons.style_outlined`/`style`), Me (`Icons.person_outline`/`person`). Remove College, AI, Exam tabs for the owner. `labelBehavior: alwaysShow` for the owner. Student branch untouched. In `app/lib/notify.dart` (~lines 60–140) skip the college plan reminders (`todayPlan()`, night-before, morning check) when `App.isOwner`; the cert reminder stays.
- [ ] **Step 2: Today layout** per spec "Today" items 1–8 (mockup `tabs-b.html` #1). App bar: `CertDeck` + Stats icon only. Pull-to-refresh syncs. Ring: `done` = reviews today (`Db.reviewsSince(startOfToday())`, `source == 'study'`) and `total = done + queue.length`; use `CircularProgressIndicator(value:)` in a `Stack` with the number. Countdown: amber in final 7 days; "No exam date set" taps to Me (switch Shell tab via a callback or `ValueNotifier<int>` for the tab index). Exam sim button → `ExamScreen()` pushed; Generate → `Scaffold(appBar: AppBar(title: Text(t('Generate cards'))), body: GenerateTab())` pushed. Counts as one muted line.
- [ ] **Step 3: Fix these first.** Horizontal `ListView` of up to 5 `WeakSpotCard`s; title "Final review" in final 7 days. Evidence lines: tag "{missed} of {answered} missed"; memorized "{n} cards: right on the original, wrong on rewrites"; misconception "{n} cards you were sure about and missed"; leech "{n} cards you keep forgetting"; ai: the analysis entry's reason. Actions: tag/memorized/misconception → `drill` (memorized passes `rewriteOnly: true`; final 7 days → `buildCramQueue(cert)` for misconception); leech → `CardsScreen(filter: 'leech')`; ai → Generate prefilled with its domain/topic/count (same body as `InsightsTab._action`). Empty: "No weak spots in the last 14 days." A "See all" link → `WeakSpotsScreen`.
- [ ] **Step 4:** Remove Readiness block, predicted score, domain bars and the Leeches/Misconceptions chips from Today. Keep `readiness()` in `logic.dart` (used by `buildCramQueue`).
- [ ] **Step 5:** Add Arabic for every new string in `i18n.dart`.
- [ ] **Step 6: Verify** `flutter analyze` (no new issues) and `flutter test` (all pass).
- [ ] **Step 7: Commit** `git commit -m "Owner: three tabs, Today with progress ring and weak spots"`

---

### Task 5: Library hub and card filter chips

**Files:**
- Create: `app/lib/library.dart` (`LibraryScreen`)
- Modify: `app/lib/cards.dart:67-140` (`CardsScreen`: `cert` param, chips, no courses for owner)
- Modify: `app/lib/main.dart` (Library tab → `LibraryScreen`)

**Interfaces:**
- Consumes: `App.certs`, `Db.cardsFor`, `GenerateTab`.
- Produces: `CardsScreen({String filter = 'all', String? course, String? cert, String? tag})` — `cert` preselects `cert` state (`'any'` = all cards); `tag` preselects a tag chip.

- [ ] **Step 1: LibraryScreen** (mockup `library-me.html` B without College): search field (submitting pushes `CardsScreen(cert: 'any')` with that query prefilled — add `String query = ''` param), "Certs" section with one tile per `App.certs` ("{n} cards · {l} leeches"), an "All cards" tile, a "Generate cards" tile. No College section.
- [ ] **Step 2: CardsScreen for the owner:** replace the filter popup with a horizontal row of `FilterChip`s: the status filters (`filters` map) and the card set's tags (most used first). The course entries disappear from the owner's picker (`courseList` stays empty when `App.isOwner`). Students keep today's popup and course picker.
- [ ] **Step 3:** Weak-spot tag Drill's "see cards" (in `WeakSpotsScreen`) uses `CardsScreen(tag:)`.
- [ ] **Step 4: Verify** analyze + test. **Commit** `git commit -m "Owner Library hub, card filter chips, no courses for owner"`

---

### Task 6: Me

**Files:**
- Modify: `app/lib/settings.dart:84-356`
- Modify: `app/lib/main.dart` (Me tab → `SettingsScreen()`)

**Interfaces:**
- Produces: `SettingsScreen({String? section})` — `section == 'more'` shows only the "More" rows. Student layout (`!App.isOwner`) unchanged regardless.

- [ ] **Step 1:** Split the existing `ListView` children into private builders per group (language, cert, study, reminders, sync, usage, data/import/export, FSRS, leech, account) without changing any row's behavior.
- [ ] **Step 2: Owner layout** (`App.isOwner && section == null`), title "Me": a status card (last sync, Sync button with spinner on `Api.syncing`, AI spend line from the existing `usage` future), then **Cert** (active cert, exam date set/clear), **Study** (Study setup, Autopilot, Rotate card versions, Reminders toggle + time), then one "More" tile → `SettingsScreen(section: 'more')` with import/export (file + server), Re-optimize FSRS, leech threshold, language, sign-in/account.
- [ ] **Step 3: Students:** the same builders in today's order (diff the student build output by eye against `main` on the qa-student account in Task 9).
- [ ] **Step 4: Verify** analyze + test. **Commit** `git commit -m "Owner Me screen: status, cert, study, More"`

---

### Task 7: Focus-mode study (owner)

**Files:**
- Modify: `app/lib/study.dart:206-300` (owner `build` + `_bottom`)
- Modify: `app/lib/widgets.dart` (`CardView` only if tags need a slot after reveal)

**Interfaces:**
- Consumes: `StudyScreen.rewriteOnly` (Task 2). `_easyCard`/`_easyBottom` untouched.

- [ ] **Step 1: App bar** (owner): leading ✕ (pop), no title text, actions: ⋮ only with Ask AI, Edit card, Card details & history, Suspend card (existing handlers). Under it a 3 px `LinearProgressIndicator(value: done / planned)` and a small muted "{n} left".
- [ ] **Step 2: Before reveal:** only `CardView`. **After reveal:** existing explanation and notes, then the card's tags as small chips and an "Ask AI" `TextButton` → `ChatScreen(c)`.
- [ ] **Step 3: Confidence:** one `SegmentedButton<Conf>` (Guessing orange / Unsure amber / Sure green, no selection) where selecting sets `conf` and `revealed`; disabled until `ans!.ready`. Written / self-grade / Next bars keep their behavior, restyled with theme buttons.
- [ ] **Step 4: Verify** analyze + test. **Commit** `git commit -m "Owner study: focus mode"`

---

### Task 8: Tag every card (content)

**Files:**
- Create: `content/certdeck-versions/tags_export.py` (server: dump `{id, tags, certs}` for owner card docs to `/tmp/card-tags.json`)
- Create: `content/certdeck-versions/tags/vocab.json` (the fixed tag list)
- Create: `content/certdeck-versions/tags/bN.json` (`[{"card_id", "tags": [...]}]`, one per batch b1–b9, same batches as `in/`)
- Create: `content/certdeck-versions/tags_import.py` (server: sets `data.tags` and `updated_at` on those card docs only; prints counts)
- Create: `content/certdeck-versions/validate_tags.py`

- [ ] **Step 1:** Ask the user before running `tags_export.py` on the server (`python manage.py shell < tags_export.py` inside certdeck-api). Copy the result to `content/certdeck-versions/tags/existing.json`.
- [ ] **Step 2: Vocabulary:** from existing tags plus services/concepts across `current/bN.json` and `out/bN.json`, write `vocab.json` — AWS services by their short name (`S3`, `KMS`, `Lambda`, `DynamoDB`…), concepts in lower case (`encryption at rest`, `cross-account access`…). Fold existing hand tags in (normalize case, merge duplicates); keep any that don't fit as-is.
- [ ] **Step 3: Tag each batch:** read each card's original (`current/bN.json`) and both versions (`out/bN.json`); 2–6 tags from `vocab.json` that cover all three wordings; union with the card's existing tags. Write `tags/bN.json`. Batches are independent (one subagent per batch is fine; no git, no network).
- [ ] **Step 4: `validate_tags.py`** asserts: every card in `in/b*.json` has an entry; every tag is in `vocab.json`; 1–8 tags per card; no existing hand tag lost. Run `python3 validate_tags.py` → `OK`.
- [ ] **Step 5: Commit** the scripts and `tags/`.
- [ ] **Step 6:** Ask the user before running `tags_import.py` on the server. After it runs, sync the phone and spot-check tags in Library.

---

### Task 9: Check on a device and release

- [ ] **Step 1:** `cd app && flutter analyze && flutter test` → no new issues, all pass.
- [ ] **Step 2:** Build a debug APK (no emulator running, Gradle ≤ 2 GB) and walk through on the phone: Review Focus 1–5, each owner screen (Today, See all, a tag Drill, a memorized Drill, Exam sim, Generate, Stats, Library, Cards chips, Me + More, study before/after reveal, Arabic). Then sign in as qa-student and confirm EasyHome, easy study and Settings look as before.
- [ ] **Step 3:** Delete `app/build`, stop Gradle.
- [ ] **Step 4:** Ask the user before releasing. On yes: bump `app/pubspec.yaml` to `1.6.0+30`, run `deploy/release-apk.sh` (arm64 only), commit "Release 1.6.0+30: three tabs, weak spots, focus study, Library hub, Me".
