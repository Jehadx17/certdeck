# CertDeck owner app: modernize (design)

2026-10-24. Mockups: `.superpowers/brainstorm/2152550-1792817363/content/` (`tabs-b.html` option 1, `study-screen.html` B, `library-me.html` Hub + Me, `style.html` A).

## Why

The owner side of CertDeck feels jammed: six bottom tabs, a home screen stacking a dozen blocks, too many app bar icons. The Readiness block (predicted score, per-domain bars) gives no insight: every domain reads high. What the owner actually wants from the home screen is **where am I weak and what do I do about it**.

The owner's own diagnosis of a weakness: getting a *rewritten version* of a card wrong after getting the original right, i.e. memorizing the original's shape instead of the concept.

## Scope

- **In:** the owner app (`App.isOwner`, the `Shell` tabs in `app/lib/main.dart`) and the shared screens it opens (study, exam, stats, cards, card detail/editor, AI chat, settings).
- **Out:** the student app (`EasyHome`, `easy.dart`, the easy study variant). Must look and behave exactly as today.
- **Content:** tag every CertDeck card (and check its versions) with service and concept tags.

## Goals

- Minimal, uncluttered, modern look across the whole owner app.
- Three tabs instead of six.
- Home shows concrete weak spots with a one-tap fix, replacing Readiness.
- Weakness detection uses per-version results and tags.
- **Keep every feature** except the ones removed below. Nothing else is cut; things move.

## Anti-goals

- Hints before answering. No tags, version number or labels above the card while studying (removed in 1.5.7; see `no-answer-giveaways`).
- Any change to the student app.
- New dependencies for looks (charts, icon packs). Material icons and plain widgets.

## Removed (owner decisions)

- Readiness block, predicted score, per-domain readiness bars on the home screen.
- College for the owner. The owner app has no College tab, no College in Library, and no courses in the Cards filter. Students keep College as today.

Not removed: predicted vs pass inside Exam results (real simulation data) stays. *Builder's call to confirm; owner didn't comment.*

## Navigation

Bottom `NavigationBar`, three destinations with icons and labels:

| Tab | Icon (outlined / filled) | Holds |
|-----|------|-------|
| Today | home | study, weak spots, Exam sim + Generate buttons |
| Library | style / book | cert decks hub, Generate |
| Me | person | settings, sync status, AI spend |

Old tab → new home: Certs → Today. Cards → Library. AI Generate → Library tile + Today button. AI Weak areas (`InsightsTab`) → feeds "Fix these first" (see below). Exam → Today "Exam sim" button opens today's `ExamScreen` unchanged in features (start, history, results). Settings → Me. College → gone for owner.

App bar on Today: title "CertDeck" + **one** icon, Stats (opens `StatsScreen`). No sync icon: pull-to-refresh on Today syncs; Me shows status with a Sync button.

## Today (mockup `tabs-b.html` #1)

Top to bottom:
1. `OnlineBanner`, and the "Not connected" notice when signed out (keep, restyled).
2. Progress ring: cards done today out of today's queue size ("12 of 28 today").
3. Cert code + exam countdown ("DVA-C02 · exam in 23 days"); amber in the final 7 days; "No exam date set" links to Me.
4. Primary button: "Continue · N left" / "Study (N) · about M min" / "Done for today · study ahead" — same queue logic as now (`buildQueue`, `buildExtraQueue`, `studyCert`).
5. Exam pacing warning (when `plan.paced > newPerDay`): one muted line under the button.
6. Two quiet buttons in a row: **Exam sim**, **✨ Generate**.
7. **Fix these first**: horizontally scrolling cards, worst first, each with a title, one line of evidence, and a "Drill" chip. A "See all" entry opens the full list.
8. Due / new / unseen counts: one muted line (not three tiles), e.g. "18 due · 10 new · 412 unseen".

The old "Weak-area review" / "Final review" button becomes the Drill action; in the final 7 days the section title reads "Final review" and its Drill uses `buildCramQueue` as now.

## Fix these first (weak spots)

Window: last 14 days of `review` rows for the active cert. Owner's call on what counts as weak was delegated; defaults below are **builder's call**, tune freely.

Kinds of weak spot, merged into one list sorted by severity:

1. **Weak tag** — a tag with ≥ 4 answers in the window and miss rate ≥ 35%, counting every version answered. Evidence: "KMS · 9 of 14 missed". Drill: a short session of that tag's cards (due first, then lowest stability), mixing versions.
2. **Memorized, not understood** — cards where the original (`ver` 0) was answered right but a rewrite (`ver` ≥ 1) was missed within the window; grouped per tag when ≥ 2 cards share one, else one entry "N cards". Evidence: "6 cards: right on the original, wrong on rewrites". Drill: those cards, shown **only as rewrites** for this session, per-answer notes visible after answering.
3. **Misconceptions** — cards with `misconception == true` (sure + wrong). Drill: those cards.
4. **Leeches** — cards with `leech == true`, not suspended. Action: opens them in Cards (to rewrite or suspend), as the old chip did.
5. **AI weak areas** — the `InsightsTab` analysis result, when one exists, shown as entries with its suggested topics; action "Generate cards" opens Generate prefilled (as `InsightsTab` does today). Running a new analysis: a button at the bottom of "See all".

Severity: miss rate × answers for tags; count for the others. Show at most 5 on Today. Empty state: "No weak spots in the last 14 days."

Data already present: `review.ver` (since 1.5.9), `review.correct`, `card.tags`, `card.misconception`, `card.leech`. No schema change.

## Study screen: Focus mode (mockup `study-screen.html` B)

Same flow and features as now (answer → confidence → reveal → right/wrong → Next; written/typed cards unchanged; "Actually right/wrong" override).

- App bar: close (✕) and ⋮ only. ⋮ holds Ask AI, Edit card, Card details & history, Suspend card.
- Thin progress line under the app bar instead of "Title · N left" text; keep the count small and muted.
- Before answering: only the question and options.
- After answering: the explanation, per-answer notes, and then the card's tags and an Ask AI button.
- Confidence: one segmented bar (Guessing / Unsure / Sure, orange / amber / green), disabled until an answer is picked.

Applies to the owner study path only (`_easyCard` stays as is).

## Library: Hub (mockup `library-me.html` B, minus College)

- Search field at top: searches all cards (existing search over question, answer, tags, options).
- "Certs" section: one tile per cert (`App.certs`), "642 cards · 5 leeches". Tap opens `CardsScreen` filtered to that cert.
- A tile "All cards" (the old `any` filter).
- A tile "Generate cards" opens `GenerateTab` as its own screen.
- Inside `CardsScreen`: filters become chips (tags, Leeches, Misconceptions) instead of the popup; add card stays.

## Me (mockup `library-me.html`, Me)

- Top: sync status card ("Synced 2 min ago", Sync button, spinner while `Api.syncing`) + AI spend this month.
- **Cert:** active cert, exam date (set/clear).
- **Study:** Study setup, Autopilot, Rotate card versions, Reminders (toggle + time).
- **More** (one level down): import/export (file and server), Re-optimize FSRS, leech threshold, language, sign-in/account.

Every current setting stays; only grouping and depth change.

## Look: Teal, refined (mockup `style.html` A)

- Keep the current dark theme, seed `#2dd4bf`, surface `#111316`, dark only.
- More whitespace, 14–16 px corner radius on cards and buttons, no borders where a surface tone does the job.
- Muted secondary text instead of extra labels; small uppercase section headers.
- Apply to every owner screen, including Exam, Stats, card detail/editor, AI chat. Layouts of those stay; only spacing and styling change.
- Prefer theme-level changes (`ThemeData` in `main.dart`) over per-widget styling, so the student app's look moves only as much as shared theme values move. **Builder: confirm the student app still looks right**; if a theme change would alter it noticeably, scope the change to owner screens.

## Tags (content task)

- Review every CertDeck card and its two versions; add tags where missing. Tags: AWS services (S3, KMS, Lambda, …) and concepts (encryption at rest, cross-account access, …). Short, consistent casing, a fixed vocabulary reused across cards.
- Versions inherit the card's tags (`_versionKeeps` includes `tags`), so tags go on the card doc.
- Authored in Claude Code, never via the API pack pipeline (`darb-content-in-claude-code`). Work in `content/certdeck-versions/`, push to the server with a manage.py shell script like `import.py`, touching only `tags` on card docs.
- From now on, new cards get tags when imported.

## Constraints

- Flutter app in `app/`, Material 3. Build Android arm64-only via `deploy/release-apk.sh`; JDK 17; Gradle capped at 2 GB, never with the emulator running; clean `app/build` after.
- Arabic/RTL must keep working on every changed screen (`t()` strings).
- Local backend tests per `darb-local-tests` if backend touched (it shouldn't be).

## Settled after review (builder's calls unless noted)

- **Me vs `SettingsScreen`:** `SettingsScreen` is shared with students (`easy.dart`). Build Me as a new owner-only screen that reuses the existing setting rows (extract them as widgets where needed). Leave the student `SettingsScreen` layout identical.
- **AI spend:** already in Settings ("AI spend this month", `settings.dart`). Reuse that source; no backend change.
- **Drills schedule normally:** same as the old Weak-area review: `StudyScreen(..., source: 'cram')`, answers update FSRS and the review log as any study answer does.
- **Memorized Drill:** forces a rewrite (`ver` ≥ 1) for each card in that session. Recording `ver` on the review and FSRS updates work as usual; rotation outside the Drill is untouched.
- **Thin version data:** if "Rotate card versions" is off, or no card has both a `ver` 0 hit and a rewrite miss in the window, the Memorized entry simply doesn't appear. No nudge.
- **Tag vocabulary:** before tagging, pull the cards' existing tags from the server and fold them into the vocabulary (normalize casing, merge duplicates). Don't drop tags the owner added by hand.
- **Owner's college data:** hidden, never deleted. No College tab, no courses in the Cards filter or Library, no course cards in weak spots (active cert only). Sync, notifications and stats code stay as they are; college reminders for the owner don't fire because there's no plan to show. If any do, suppress them for the owner.
- **Focus mode scope:** `StudyScreen` with `easy == false`. With College gone for owners, that's the cert study, Drills, and anything else the owner opens.
- **Theme:** pick the `MaterialApp` `darkTheme` by role (`App.isOwner` → refined theme, students → today's theme). `MaterialApp` already rebuilds on role changes, and pushed routes inherit it, so the student app doesn't drift at all.

## Left to the builder

- Weak-spot thresholds and severity formula (defaults above).
- Exact icons, spacing values, ring widget.
- Code structure: where the weak-spot logic lives (likely `logic.dart`), how tabs are wired.
- Order of work (tags first is sensible so weak tags have data).
