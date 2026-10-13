# CertDeck for College: Goal

Extend CertDeck (see SPEC.md, README.md, DECISIONS.md, docs/PROTOCOL.md) so a few college students I invite can
upload their course material (books, lecture slides, notes, photos, past exams), have the AI extract
what matters, and get cards, practice exams, sheets and a plan that raise their marks on quizzes, midterms and finals.

## Context
- CertDeck today is my personal, single-user cert app (DVA-C02 → SAA-C03 → CKAD): offline-first Flutter app,
  Django backend on my VPS, FSRS, confidence ratings, AI generation, exam simulation, diagrams, forced updates.
- **Keep everything I have working exactly as it is.** My certs, cards, review history and FSRS state must survive
  untouched, and my phone must keep working without re-entering a token.
- New: a handful of college students I invite (friends/classmates). I create their accounts. They only see the
  college side; I see certs and college.
- The goal is **higher marks**, not long-term retention. Students take few courses at a time that rarely overlap,
  but they usually start studying late (0–3 days before a quiz). Spaced repetition over weeks often isn't possible,
  so the app must make short windows count, and still use spacing when there is time (finals).
- Subjects: math/physics/engineering (formulas, worked problems), programming/CS, and memorization-heavy courses
  (medicine, biology, law, history).
- Exam formats to prepare for: MCQ / true-false, short answer / definitions (incl. fill-in-the-blank, matching,
  labeling), and problem solving (steps + final answer, partial credit for method). No essays.
- Languages: Arabic and English, often mixed (Arabic explanation, English terms). The UI supports both with RTL.

## Before you start: ask me everything in ONE batch
Then don't stop again unless something is destructive, affects my other VPS projects, or is blocked:
- Real sample material for the end-to-end test: a syllabus, a .pptx lecture, a textbook chapter PDF, a past
  quiz/exam (PDF or photos) and a photo of handwritten notes, ideally in both languages.
- Whether I have a free or paid Apple ID for installing on students' iPhones.
- The first student accounts to create (or confirm I'll create them later with the command you build).

## Ground rules
- All VPS safety rules from SPEC.md still apply: isolate, only add, inspect read-only first, ask before anything that
  could touch my other projects.
- Reuse what exists: the document model and sync, FSRS, confidence → rating, misconceptions, leeches, the cram
  queue, exam simulation, AI generation/explain/variants, Batch API jobs, cost logging, diagrams, forced updates.
  Extend them rather than building parallel versions.
- Keep the single-writer rule. Backend progress (processing status, extraction results) goes into
  backend-owned job docs that the app applies, like the diagram jobs.
- The existing `exam` doc kind is a simulation result. Name the new real-world assessment kind so it doesn't collide.
- Uploaded material is untrusted: check magic bytes, enforce size limits, run conversions sandboxed with no network
  and a timeout, and treat its text as data, never as instructions to the model.
- Verify against official docs before coding: Claude model ids, PDF limits (pages/size per request), Batch API,
  pricing.

## Accounts, isolation and cost
- Users: per-user long-lived tokens replace the single token. My existing token maps to my account (owner) and all
  existing docs and media become mine.
- Roles: `owner` (me: certs + college, no cap unless I set one) and `student` (college only; cert screens hidden).
- Management commands over SSH, no admin UI: create a user (prints the token), disable, rotate token, set cap,
  monthly usage per user.
- **Isolation is a security boundary.** Sync, media, import/export and every AI/job endpoint only ever see the
  caller's data. Media is content-addressed globally today, so add ownership: a user can't fetch another user's
  file by hash. Cover this with backend tests.
- Budget: everything runs on my Anthropic key. Default cap **$10/month per student**, adjustable per user.
  `AiCall` records the user. Before any large job, show the student an estimate ("~$0.80 for chapters 3–5") and
  their remaining budget. The server refuses AI work past the cap with a clear message; studying never needs budget.
- Use the Batch API (50% off) for non-urgent processing (exam more than 3 days away) and synchronous calls when
  the exam is close. The diagram sweep charges the card owner's cap and, for course cards, uses only the kinds
  that fit (flows, comparisons, lifecycles; no AWS icons).
- Models: a cheaper model (Sonnet/Haiku) reads big uploads and extracts; Opus writes cards, questions,
  explanations, rubrics and grading. Before locking this in, run a side-by-side quality check on my sample
  material and record the result in DECISIONS.md. Models stay configurable in `.env`.

## Courses, materials and exams
- A **course** has a name, language(s), materials, a professor profile and assessments.
- **Materials**, any mix:
  - PDF books and notes (books can be 300–800 pages)
  - .pptx slides (convert to PDF on the server, e.g. LibreOffice headless)
  - photos/scans of printed pages, handwritten notes or the whiteboard (several photos = one material)
  - the syllabus
  - past quizzes/exams from the same professor
- Large uploads must survive a phone connection: resumable or chunked uploads with a visible status. Raise the body
  size limit only in our own nginx site file.
- On upload, **map the structure only** (chapters/sections with page ranges, slide titles).
  This is cheap and lets the student pick scope. Deep extraction happens per exam scope (below). Never process a
  whole book upfront.
- **Syllabus →** the AI proposes the course's assessments (quiz/midterm/final, dates if present, weights, topics).
  The student confirms and edits.
- **Assessments:** type, date, duration, scope (chapters/lectures/sections), the professor's hints ("focus on ch.
  3", "no proofs"), and the expected question mix.
- **Past exams →** a professor profile: format mix, difficulty, point weights, topics that repeat, typical traps,
  wording style. Use it for prioritization and to make practice exams look like the real ones.

## Extraction: from material to knowledge
- When an assessment's scope is set (or changes), extract **knowledge points** from exactly that scope:
  definitions, facts, formulas (with variables and units), procedures, worked examples, comparisons, cause/effect,
  diagrams/labels.
- Every knowledge point **cites its source** (material + page/slide/timestamp) and carries importance signals: the
  professor's hints, emphasis in the slides/lecture, the syllabus weight, and frequency in past exams.
- **The professor's version wins.** Use the material's definitions, notation and terminology over general knowledge.
  Anything the AI adds beyond the material is marked "not in your material".
- Dedupe across a course's materials (slides and book often cover the same thing).
- Coverage check: every knowledge point in scope gets at least one card or question. Show coverage per chapter/lecture.

## Cards and questions
- Generate from knowledge points into the existing card types, plus what the exam formats need:
  - true/false
  - short answer / definition with a **rubric** (model answer + key points with weights), graded by the AI with
    partial credit and "what you missed" feedback
  - **problem solving**: a problem, a step-by-step solution, a final answer with tolerance and units, and a rubric
    for method/partial credit
  - fill-in-the-blank, matching and labeling via the existing cloze, MCQ and occlusion where they fit
- **Math rendering:** LaTeX in every card field, question, solution and sheet. This reverses SPEC.md's "no LaTeX".
  It must render correctly inside RTL Arabic text.
- **Numeric answers must be verified, not trusted.** Compute or check them server-side (e.g. the model returns the
  computation in a form the server can safely evaluate, or solve it twice independently) and drop problems that
  fail verification.
- Cards follow the material's language. Mixed Arabic/English stays mixed the way the professor teaches it.
- Students can answer problems by typing the final answer or **photographing their handwritten work** for a method
  check (online).
- Offline: AI grading needs a connection. Offline, the student self-grades against the stored rubric and the
  review syncs later.
- Grading feeds the scheduler: full credit → per the confidence rule, partial → Hard, wrong → Again. Misconceptions
  (Sure + wrong) work as today.

## Study engine: make short windows count
Pick the mode automatically from the days left until the assessment (the student can override):
- **Sprint (0–3 days):**
  - No long intervals. Retrieval-practice sessions where a missed item comes back later in the same session, and an
    item counts as learned after two correct recalls in a row, spaced by other items (successive relearning).
  - Topics are interleaved. The next day relearns before adding new material.
  - Ordered by **expected marks** = importance (hints × syllabus weight × past-exam frequency × format points) ×
    (1 − current recall).
- **Compressed (4–14 days):**
  - Spread sessions over the remaining days with FSRS, max interval = days to the assessment, high desired
    retention.
  - Practice exams at the midpoint and 2 days before.
- **Long (finals, >14 days):** full FSRS as today (exam pacing, retention ramp, final review), plus cumulative
  review of earlier assessments' scope.
- **Time budget:** "I have 90 minutes" builds a session that fits, using the student's own per-item time from
  `duration_ms`. If the scope doesn't fit the time left, **triage**: show what to master, what to skim and what to
  skip, by expected marks.
- **Practice exams:** extend the existing exam simulation with the assessment's format, duration and the professor's
  style. Fresh AI questions the student hasn't seen. Results by chapter/lecture, explanations with source
  citations. Answers feed the scheduler.
- **Readiness:** per assessment, show coverage (seen/mastered per chapter), estimated recall, practice-exam results,
  and a predicted mark shown as a range, honestly labeled as an estimate.
- **Exam morning:** a 10-minute check of the highest-yield weak items and misconceptions. No new material.
- **Against last-minute habits:** when an assessment is added, the plan starts today, and the reminders escalate
  when the student falls behind.

## Study aids
All are generated per assessment scope, stored as docs, readable offline, with source citations and LaTeX:
- Summary of the scope (by chapter/lecture).
- Key-facts sheet and formula sheet (formulas with variables, units and when to use each).
- **Night-before sheet:** one page with the top items by expected marks, plus this student's own misconceptions,
  weak points and must-know formulas.
- **Worked problems:** step-by-step solutions for the professor's examples and past-exam problems, each step
  justified, plus fresh similar problems (verified answers) to practice the same method.
- **Plan + reminders:** a daily plan across the student's courses (minutes per course per day) that re-plans when a
  day is missed. On-device local notifications (no push server), e.g. "Quiz 2 in 3 days: 25 min today". Works on
  Android and iOS.

## App
- Same app, role-aware: students see Courses (and Settings); I see Certs and Courses.
- Arabic and English UI with full RTL, a language setting, and fonts that render Arabic and math well.
- Offline-first stays: studying, sheets, plans and self-graded answers work offline. Uploads, extraction, AI grading
  and generation show "Needs connection".
- Android updates use the existing forced-update flow. iOS: document installing on a student's iPhone through my
  Mac with `app/build-ios.sh` (free Apple ID = re-sign every 7 days, paid = yearly). There's no self-update on iOS.

## Out of scope (don't build)
Public sign-up, an admin UI, sharing material or cards between students, AI tutor chat over the material, grade
logging, essay grading, lecture recordings / audio transcription (removed at my request on 2026-10-13),
push notifications from a server, App Store / Play Store publishing.

## Delivery and workflow
- Work autonomously, same as SPEC.md: small meaningful commits pushed as you go, significant decisions in
  DECISIONS.md, no secrets in git.
- Keep docs/PROTOCOL.md, docs/cards.schema.json, examples/ and README.md current (including the user management
  commands and the iOS install steps for students).
- Verify things actually work:
  - backend tests for isolation, cap enforcement, the ingestion pipeline (AI mocked) and numeric verification
  - app logic tests for mode selection, expected-marks ordering, triage and the sprint loop
  - a real end-to-end run on my sample material
  - device checks on Android and, where possible, iOS

### Milestones (in order, don't stop for approval between them)
1. **Multi-user foundation:**
   - accounts, roles, per-user tokens and data isolation (docs, media, AI, jobs, import/export)
   - caps and cost estimates, management commands
   - my data migrated to my account
   - Arabic/English UI with RTL, LaTeX rendering
   - ship via forced update and verify my certs and history are intact
2. **Courses and ingestion:** course/material/assessment docs; uploads (PDF, pptx→PDF, photos); structure mapping; syllabus → proposed assessments; past exams → professor profile; status and
   estimates in the app.
3. **Extraction and generation:** knowledge points with citations and importance per scope; the new card types with
   rubrics and verified numeric answers; coverage; the model-mix quality check.
4. **Study engine:** modes by window, expected-marks ordering, time-budget sessions and triage, AI grading +
   offline self-grading, practice exams in the professor's style, readiness and predicted mark, exam-morning check.
5. **Study aids:** summaries, key-facts/formula/night-before sheets, worked and similar problems, plan + local
   reminders.
6. **Final pass:**
   - end-to-end with my sample material in both languages, as a student account on a second device
   - isolation check (a student can't see my data or another student's)
   - offline test
   - iOS build
   - a cost report for the sample run
   - release APK via forced update

## Definition of done
- My phone updated itself, and my certs, cards, FSRS state and review history are unchanged.
- I can create a student with one command and give them a token. On their phone they see only Courses, in Arabic or
  English.
- A student can:
  - upload a syllabus, slides, a book, photos and a past exam
  - confirm the proposed assessments, set a quiz's scope and hints
  - get cited cards and problems for exactly that scope, within budget and with an estimate first
- With 2 days left, the app runs a sprint: a time-budget session ordered by expected marks, triage when time is
  short, AI-graded short answers and problems (self-graded offline), a practice exam in the professor's style, a
  readiness range, a night-before sheet, and an exam-morning check.
- Formulas render correctly in Arabic and English. Numeric answers are verified.
- A student can never see another user's data. Caps are enforced. The new services run isolated without
  disturbing my other projects.
- All code is pushed with updated docs and DECISIONS.md. End with a short summary: what was built, how to add a
  student, how students install (Android/iOS), costs from the sample run, and anything I need to do manually.
