# Darb: content packs (pipeline, delivery, quality report)

## What a pack is
A pack is one exam or subject for one segment and grade, for example "قدرات - لفظي" or "رياضيات ثالث متوسط". Its items
live in Postgres (`PackItem`). Students download a built file:
- `DPK1 | nonce | AES-256-GCM(gzip(JSON))`, with the AAD bound to `darb:<slug>:<version>` (a file can't pass for another
  pack or version);
- served by Cloudflare's CDN from R2 (`https://cdn.<domain>/packs/<slug>/<version>.dpk`), never through Django;
- each version gets a fresh random key, stored only wrapped with `DARB_PACK_KEK`;
- a plaintext sample (`sample-<version>.json.gz`, default 20 items) is free.

On the phone the cards are imported into the local database and **never synced**: the server drops any pack card a
client sends. Their schedule is rebuilt from the synced review log after a reinstall. The pack's blueprint topics are
the study "domains", so new cards interleave by topic weight and readiness is per topic.

## Pipeline (`manage.py packs run <slug>`, resumable, Batch API: half price)
| Step | Model / tool | Rule |
|---|---|---|
| blueprint | `darb/content/blueprints/<slug>.json` | official format and topic weights only (ETEC/MOE), sources cited; never real items |
| generate | Opus 5.5, high effort, Batch | 15 original items per request per topic, with explanation, hint, difficulty, skill and a SymPy check when computable; the existing stems are sent to avoid repeats; a topic stops after 1.5x its share of attempts |
| clean | code | shape (4 distinct options, one key), SymPy check must pass **and** match the keyed option, near-duplicate rejection (difflib ≥ 0.88) |
| blind solve | Sonnet 5.5, Batch | an independent model answers without the key. MCQ: must pick the keyed option. Other items: same text, else Haiku decides equivalence. Disagreement, a "flawed" flag or no answer = **quarantined** (not shipped, listed) |
| audit | Opus 5.5, max effort, Batch | random sample of 60 verified items; error = wrong key, wrong question, wrong explanation, bad language, unsuitable for 12-18, or a likely verbatim exam item. The measured error rate has a 95% Wilson interval; items found wrong are rejected |
| build | `packs build --out` (then uploaded to R2) | verified items only; a new version and key each build |

**Ship rule:** a pack ships only if its audited error rate is at most **2%** (`content.MAX_ERROR_RATE`). Otherwise it is
listed as blocked in the per-pack report below for you to decide.

**Tutor-reviewed PDFs** (when you send them) are imported with `source = pdf:<file>` and `tutor_reviewed = true`. They
still go through the code checks; the blind solve only flags them for your review, never drops them. Tutor videos
would be transcribed locally (Whisper) and used as teaching material only. Your permission per tutor is recorded in
the pack's `sources`.

**Rights:** every pack's `sources` log lists the official blueprint documents (facts and format only), the generator,
and any PDF/tutor material with its rights status. Anything unclear is flagged in the report.

**Estimated cost** (to be replaced with measured numbers in phase 4): about $7 generation + $2 solving + $1.5 audit
per 1,200-item pack, so about $10-12 per pack.

## Watermark (leak tracing)
Each subscriber's key response carries a seed derived from their account (HMAC of the server secret). At import, the
app shuffles each multiple-choice card's options in an order derived from the seed and the card id, and appends an
invisible 32-bit zero-width marker to the explanation. A leaked dump of a phone's database or copied text points back
to the account. A memory dump of the raw decrypted file before import would not, which needs a rooted phone and
skill; see DARB-SECURITY.md.

## Per-pack quality report
Filled by `manage.py packs status` after phase 4 runs (needs the Anthropic key).

| pack | items | verified | quarantined | rejected | audited error rate (95% CI) | ships | cost |
|---|---|---|---|---|---|---|---|
| (none built yet) | | | | | | | |

Blueprints ready: `qudurat-verbal` (5 topics, 1,200 items) and `qudurat-quant` (9 topics, 1,200 items), both from
ETEC's official GAT guide.

Since 2026-10-16: 46 more (48 packs, 18,402 planned items; table in `darb/content/blueprints/README.md`, gaps in
`TODO.md`): تحصيلي math, physics, chemistry and biology (700 each); middle school m1-m3 × 7 subjects; high school h1 × 11
subjects and h2/h3 general track × 5. Their topic lists are **unverified**: ETEC's تحصيلي specification wasn't
reachable online and the MOE textbook portal (ien.edu.sa) needs a login, so they follow secondary sources and the
usual course scope. 👤 If you have the official تحصيلي guide or an ien.edu.sa login, I swap them for the real tables of
contents. Packs generated from an unverified blueprint are audited like any other (≤ 2% error) and say "unverified
outline" in the per-pack report.
