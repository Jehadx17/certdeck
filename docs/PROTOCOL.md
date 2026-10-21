# CertDeck data & API protocol

Single source of truth for the app ↔ backend contract.

## Documents

Everything the app stores is a **document**: `{id, kind, data, updated_at, deleted}`.

- `id`: string, globally unique (UUID v4, except fixed ids noted below).
- `kind`: one of the kinds below.
- `data`: JSON object (shape per kind).
- `updated_at`: int, ms since epoch (UTC), set by whoever wrote the doc.
- `deleted`: bool (soft delete, so deletions sync).

**Single-writer rule:** the backend only *creates* documents (AI-generated cards, analyses,
overrides, FSRS params). After creation the app is the only writer, so last-write-wins
on `updated_at` is safe. The only exceptions: `fsrs_params` is always backend-owned, and a backend
JSON import overwrites the cards it imports.

### Kinds

| kind | id | written by | data |
|---|---|---|---|
| `card` | uuid | app / backend (create) | see `docs/cards.schema.json` |
| `review` | uuid | app (append-only) | `{card_id, ts, rating 1-4, confidence: "guess"\|"unsure"\|"sure", correct: bool, misconception: bool, duration_ms, source: "study"\|"exam"\|"cram", answer?: any}` |
| `cert` | cert code, e.g. `DVA-C02` | app | `{code, name, domains:[{id:"1", name, weight:0.32}], exam_date: "YYYY-MM-DD"\|null, active: bool, exam:{questions, minutes, pass_pct, scaled: bool, kind:"mcq"\|"performance"}}` |
| `settings` | `settings` | app | `{new_per_day:20, max_reviews_per_day:200, leech_threshold:5, active_cert:"DVA-C02"}` |
| `fsrs_params` | `fsrs_params` | backend | `{parameters:[21 floats], optimized_at: ms, review_count:int}` |
| `analysis` | uuid | backend | `{created_at, cert, summary, weak_areas:[{rank, domain, topic, diagnosis}], actions:[{label, cert, domain, topic, count}], videos:[{title, url}], override_ids:[...]}` |
| `override` | uuid | backend creates, app applies | `{created_at, analysis_id, reason, card_ids:[...], due_shift_days:int\|null, due_now:bool, priority:int\|null, applied_at:ms\|null, reverted_at:ms\|null, before:{card_id:{due, priority}}}` |
| `chat` | card id | app | `{card_id, messages:[{role:"user"\|"assistant", text, ts}]}` |
| `exam` | uuid | app | cert simulation `{cert, started_at, finished_at, minutes, questions:[{card_id, domain, answer, correct, flagged}], score_pct, scaled, passed}`; college practice exam `{assessment_id, course_id, started_at, finished_at, minutes, questions:[{card_id, section, answer, score 0-1, flagged}], score_pct}` |
| `course` | uuid | app | `{name, code, lang: "en"\|"ar"\|"mixed", created_at}` |
| `material` | uuid | app | `{course_id, kind: "book"\|"slides"\|"notes"\|"photos"\|"syllabus"\|"past_exam", title, files:[{name, size}], created_at}`; the files go up through `upload/` |
| `ingest` | `ingest-<material id>` | backend | processing status `{material_id, course_id, status: "queued"\|"converting"\|"mapping"\|"ready"\|"failed", error, pages, lang, chars:[per page], structure:[{id: "s1", title, level: 1\|2, start, end (pages), kind: "content"\|"exercises"\|"other"}]}` |
| `assessment` | uuid | app; backend proposes | `{course_id, kind: "quiz"\|"midterm"\|"final"\|"test"\|"other", title, date: "YYYY-MM-DD"\|null, weeks, minutes, weight_pct, scope:[{material_id, section_id}], hints, coverage, format, status: "proposed"\|"active", source: "syllabus"\|"manual", created_at}` |
| `profile` | `profile-<course id>` | backend | the professor's past papers: `{course_id, paper_ids, formats:{mcq, true_false, short_answer, problem, other} (shares of marks), difficulty, typical_questions, typical_minutes, topics:[{topic, count}], traps:[...], style, questions:[{text, type, topic, points, page}]}` |
| `kp` | uuid | backend | a knowledge point `{course_id, material_id, section: "<material id>/<section id>", kind, title, content (markdown + LaTeX), loc (page), emphasis 0-3, created_at}` |
| `prep` | `prep-<assessment id>` | backend | preparation job `{assessment_id, status: "queued"\|"running"\|"waiting"\|"done"\|"failed", mode: "now"\|"batch", stage, progress, estimate_usd, cost_usd, cards_added, dropped, unverified, kps, uncovered, error, pending (batch)}` |
| `prio` | `prio-<assessment id>` | backend | `{assessment_id, scores:{kp id: 1-5}, hints (the hints they were scored with), updated_at}` |
| `sheet` | `sheet-<assessment id>-<kind>` | backend | `{assessment_id, course_id, kind: "summary"\|"facts"\|"formulas"\|"night", content (markdown + LaTeX), created_at}` |

College cards are ordinary `card` docs with `course` (course id) instead of `certs`, plus `section`, `kp_ids`,
`ref: {material_id, loc}` (the source page), `worked` / `similar_kp` (a professor's worked example / a new problem
in its style), `practice` (assessment id, for fresh practice-exam questions) and two more types: `short`
(`answer` = model answer, `rubric: [{point, weight}]`) and `problem` (`steps`, `answer`, `rubric`,
`check: {kind: numeric|equivalent|derivative|solutions, expr, value, var, tolerance}` and `verified: true` once SymPy
confirmed the answer). Reviews of graded answers carry `score` (0-1; partial credit rates Hard).

Card FSRS state lives inside the card doc (`fsrs` object, times in ms).

## HTTP API

Base: `https://certdeck.mithaqstay.com/api/`. All endpoints except `health`, `login` and
`signup` need `Authorization: Bearer <token>`, the token `login` / `signup` returned to this device. JSON in and out. Errors: `{"error": "message"}` with 4xx/5xx.

### Accounts
Every token belongs to one **account** (`owner` = me: certs + college; `student` = college only). People sign in
with email and password; each sign-in gives that device its own token, so one account works on several devices at
once (`manage.py users signout <name>` revokes them all). **Everything below is per account**: sync, media, import/export, AI and
jobs only ever see the caller's own documents and files. Doc ids are unique per account, so fixed ids such as
`settings` or `DVA-C02` repeat across accounts without colliding. AI work is refused with **402** once the account's
monthly budget (`cap_usd`, default $10 for students, none for the owner) is used up; studying never needs budget.

### `GET health`
`{"ok": true}`.

### `POST login`, `POST signup`
`{email, password}` (8+ characters) → `{token, name, role}`. `signup` creates a student with the default cap.
400 with a message for the person on a bad email, wrong password or taken email; 429 after 10 wrong passwords per
email in 10 minutes.

### `GET me`
`{name, role: "owner"|"student", month: "YYYY-MM", usd, cap_usd|null, remaining_usd|null}`: who is signed
in (the app shows the cert screens only to the owner) and this month's AI spend against the cap.

### `POST sync`
Request: `{"cursor": int, "docs": [doc, ...]}` (the docs the app changed, possibly empty).
The server upserts each doc when `incoming.updated_at >= stored.updated_at` (LWW), and assigns
each accepted write a new global, monotonically increasing `seq`. Writes are serialized,
so a pull never skips a lower `seq` that commits later.

Response: `{"docs": [docs with seq > cursor, ordered by seq, max 1000], "cursor": int, "more": bool}`.
The app loops while `more` is true. A fresh install sends `cursor: 0` and gets everything back.

### Media
Content-addressed images. `name` = `sha256hex.ext` (ext in png|jpg|jpeg|webp|gif).
- `PUT media/<name>`: raw bytes in the body, idempotent. The server checks that the hash matches.
- `GET media/<name>`: returns the bytes; 404 if missing **or not this account's** (an upload, an import, or a
  diagram drawn for one of its cards). Files are stored once on disk; knowing a hash never grants access.

### AI (all synchronous; long timeouts, up to 5 min)
Every AI response also stores what it creates as documents, so a dropped connection loses
nothing: the next sync pulls it. Each call logs its token usage server-side.
Offline or failing calls return an `{"error"}` that the app shows as "Needs connection" / an error.

- `POST ai/generate`: `{cert, domain?, topic?, text?, files?:[{name, media_type, data(base64)}], count:20, types?:[...], exam_style?:bool}`
  → `{cards:[card docs' data with id], retag:[{card_id, cert, domain}], skipped_duplicates:int}`.
  Uses the official exam guide for the cert/domain, picks the best mix of card types,
  and dedupes against existing cards. It may also suggest tagging existing cards from other certs
  that cover this cert's domains (`retag`; the app applies these). PDFs and images are passed
  straight to Claude as document/image blocks.
- `POST ai/explain`: `{card, messages:[{role, text}]}` → `{reply}` (follow-up chat about one card).
  With `mode:"fill"` → `{explanation, option_explanations}` (fills the explanation of a manual card).
- `POST ai/variants`: `{card, count:1-3, leech:bool}` → `{variants:[cards], explanation?, learn?, videos?:[{title,url}]}`.
  With `leech:true` it also rewrites the explanation a different way and suggests learning content.
  Variants carry `variant_of` and are stored as new card docs.
- `POST ai/analyze`: `{cert}` → the `analysis` doc data (plus `id`) and `overrides:[override docs]`.
  The server computes per-domain stats from synced reviews and cards (accuracy, lapses,
  misconceptions, confidence calibration, retrievability), and the AI ranks weak areas and
  proposes actions, videos (YouTube search links) and bounded overrides.
- `POST fsrs/optimize`: runs the py-fsrs optimizer over every review, writes the `fsrs_params` doc, and returns it.
  It also runs weekly from a timer.

### College (all per account; AI calls count against the monthly cap)
- `PUT upload/<material id>/<n>?offset=<bytes>`: raw chunk (≤ 8 MB) of file n, appended only at the offset the server
  has (409 with the right offset otherwise), so an interrupted upload resumes. `GET upload/<material id>/<n>` →
  `{size, done}`. `POST upload/<material id>/<n>/done` `{sha256}` → `{ok, type}`: verifies the hash and the type from
  magic bytes (PDF, PowerPoint/Word/ODF, JPEG/PNG/WebP/GIF; anything else 415). Files ≤ 600 MB.
- `POST college/process` `{material_id}`: after every file is up. The `certdeck-college` worker converts everything into
  one PDF (LibreOffice for slides/docs, Pillow for photos), maps sections (PDF outline, or the READ model), turns
  syllabus pages into proposed `assessment` docs and past papers into the `profile`. Progress arrives as the `ingest` doc.
- `GET college/page/<material id>/<page>` → that page as a PNG (a card's source).
- `POST college/prepare` `{assessment_id}` → `{estimate: {usd, usd_batch, pages, sections, new_sections, cards, unprocessed}}`;
  with `confirm: true` it queues the `prep` job (Batch API when the date is more than 3 days away, or `now: true`):
  extract → prioritize → generate → fill → sheets. Sections already extracted aren't read again.
- `POST college/suggest_scope` `{assessment_id}` → `{scope}` (the app applies it). `POST college/prioritize`
  `{assessment_id}` → a new `prio` doc after the hints changed.
- `POST college/grade` `{card, answer, images?: [{media_type, data}]}` → `{score, verdict, points:[{point, met, note}], feedback}`.
- `POST college/practice` `{assessment_id, count}` → `{cards}`: fresh questions in the professor's style (saved as cards).
- `POST college/night` `{assessment_id}` → the personal night-before `sheet`.

### Import / export
- `GET export` → export JSON (`docs/cards.schema.json`, `format: "certdeck"`), with every card, cert and media file inlined as base64.
- `POST import` (export JSON body) → `{imported: n}`. Validates against the schema and stores cards (updated_at = now) and media.
