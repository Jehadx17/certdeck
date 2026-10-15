# Darb: app ↔ backend protocol

Single source of truth for the contract between `darb/app` and `darb/backend`. It is based on CertDeck's
[PROTOCOL.md](PROTOCOL.md), with these differences:
- the sync cursor is per user (no global lock);
- review logs travel in a compact stream of their own;
- students sign in with Google or Apple and each phone gets its own token;
- runtime AI is Haiku only and capped per user;
- pack content never goes through the sync table.

Base URL: `https://<DARB_DOMAIN>/api/` (`darbedu.sa` by default; one config value in the app (`--dart-define=DARB_DOMAIN`)
and the backend (`DARB_DOMAIN`)). JSON in and out. Errors: `{"error": "message"}` with 4xx/5xx. Every endpoint except
`health` and the sign-in/webhook endpoints needs `Authorization: Bearer <device token>`.

## Documents
Everything the app stores is a document `{id, kind, data, updated_at, deleted}`.
- `id` is unique per account, ≤ 64 chars.
- `updated_at` is set by the writer, in ms.
- `deleted` is a soft delete.
- **Last write wins** on `updated_at`. The backend only creates documents; after that the app is their only writer
  (exceptions: `fsrs_params`, `autopilot`, `ingest`, `prep`, `prio`, `kp`, `sheet`, `profile` are backend-owned).
- A document's `data` is at most **64 KB**. Big content belongs in packs.

Kinds kept from CertDeck:
- `card` (personal cards only, e.g. from uploads; pack cards are never synced)
- `settings`, `autopilot`, `fsrs_params`, `exam`, `chat`, `session`, `reteach`
- the uploads kinds: `course`, `material`, `ingest`, `assessment`, `profile`, `kp`, `prep`, `prio`, `sheet`

`settings` gains the onboarding answers: `segment` (`middle|high|university|cert`), `grade`/`track`, `exam`,
`exam_date`, plus `theme` (`system|light|dark`) and `lang` (`ar|en`).

## Reviews (compact stream)
A review is `{ts, card_id, rating 1-4, correct, confidence: guess|unsure|sure|null, misconception, study_first,
source: study|exam|cram|other, duration_ms, score: 0-1|null, error_type: string|null}`.
- `card_id` is a personal card id or a pack card ref `"<pack>:<n>"`.
- `ts` must be within 400 days of now.
- The student's free-text answer stays on the phone.
- Storage: table `core_review`, partitioned by month on `ts`, primary key `(account_id, ts, card_id)`. A resent review is
  stored once. The booleans and small enums are packed into one `flags` smallint.
- Locally the app keeps reviews as docs of kind `review` with the deterministic id `r:<card_id>:<ts>`, so a review
  echoed back by the server is a no-op.

## `POST sync`
Request: `{cursor, review_cursor, docs: [doc...], reviews: [review...]}`, at most 500 docs and 500 reviews.

Response: `{docs: [docs with seq > cursor, by seq, ≤ 1000], cursor, reviews: [reviews with seq > review_cursor, ≤ 1000],
review_cursor, more}`. The app loops while `more` is true. A fresh install sends both cursors as 0 and gets everything.

**Per-user cursor:** each account row holds `seq`. A write reserves seqs with
`UPDATE core_account SET seq = seq + n WHERE id = me RETURNING seq` inside the write's transaction. The row lock
serializes **this user's** writers only, so their seqs commit in order and a pull never skips one. Different students
never wait on each other. (CertDeck locked one global counter row on every write.)

Side effects (queued for the worker, never done in the request):
- pushing reviews queues the account's `daily` job (autopilot + re-teach, at most every 6 h);
- editing a prepared upload assessment queues its re-scoring 2 minutes later.

## Accounts (phase 1)
- `POST auth/google` `{id_token, platform}` and `POST auth/apple` `{id_token, platform, name?}`. The backend verifies the
  ID token (signature against Google's / Apple's JWKS, issuer, audience, expiry). The response is
  `{token, account: {...}, new: bool}`.
- Each phone gets its own token (`Device`). Signing out deletes that device's token.
- Under-18 sign-up asks for a guardian (see DARB-PDPL.md → Guardian consent); details are added in phase 1.
- `GET me` → `{id, name, email, premium, premium_until, month, usd, cap_usd, remaining_usd, resets_on}`.

## Uploads (subscribers)
CertDeck's college protocol is unchanged, except:
- PDF and photos only (no Office files);
- ≤ 30 MB per file, ≤ 20 files and ≤ 60 pages per material;
- every AI call runs on Haiku;
- processing and preparation run on the job queue (worker), never in the request.

## AI (phase 2)
Haiku only, every request under 100k input tokens, hard per-user monthly dollar cap (402 with
`{"error", "resets_on"}` when it is reached). The endpoints are served by the separate `slow` pool.
