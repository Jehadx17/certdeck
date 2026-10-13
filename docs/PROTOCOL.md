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
| `exam` | uuid | app | `{cert, started_at, finished_at, minutes, questions:[{card_id, domain, answer, correct, flagged}], score_pct, scaled, passed}` |

Card FSRS state lives inside the card doc (`fsrs` object, times in ms).

## HTTP API

Base: `https://certdeck.mithaqstay.com/api/`. All endpoints except `health` need
`Authorization: Bearer <token>`. JSON in and out. Errors: `{"error": "message"}` with 4xx/5xx.

### Accounts
Every token belongs to one **account** (`owner` = me: certs + college; `student` = college only), created with
`manage.py users` (no sign-up, no admin UI). **Everything below is per account**: sync, media, import/export, AI and
jobs only ever see the caller's own documents and files. Doc ids are unique per account, so fixed ids such as
`settings` or `DVA-C02` repeat across accounts without colliding. AI work is refused with **402** once the account's
monthly budget (`cap_usd`, default $10 for students, none for the owner) is used up; studying never needs budget.

### `GET health`
`{"ok": true}`.

### `GET me`
`{name, role: "owner"|"student", month: "YYYY-MM", usd, cap_usd|null, remaining_usd|null}`: who the token
belongs to (the app shows the cert screens only to the owner) and this month's AI spend against the cap.

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

### Import / export
- `GET export` → export JSON (`docs/cards.schema.json`, `format: "certdeck"`), with every card, cert and media file inlined as base64.
- `POST import` (export JSON body) → `{imported: n}`. Validates against the schema and stores cards (updated_at = now) and media.
