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

## Authoring in Claude Code (owner decision 2026-10-17: the default; the API pipeline above stays as a fallback)
The owner writes pack items, and turns PDFs and slides into items, in Claude Code on their own subscription. The
server only checks, encrypts and serves them.
1. **Write:** one session per pack, given `darb/content/blueprints/<slug>.json`, which sets the topics, their counts
   and the format. Output: `<slug>.jsonl`, one item per line:
   `{"type":"mcq","question":"…","options":["…","…","…","…"],"correct":[1],"explanation":"…","hint":"…","topic":"t1","difficulty":2,"skill":"…"}`
   (or `"type":"basic"` with `"answer"`). For a computable item add
   `"check":{"kind":"numeric","expr":"12/3*7","value":"28","var":null}`. `correct` counts from 0, and `topic` is a
   topic id from the blueprint. Write original items only, never real exam items.
2. **Blind check:** `tools/author_merge.py prep <dir>` shuffles every item's options and the order (writers leave the key
   in a pattern, and a solver once copied the pattern). A *fresh* session then gets the items without `correct`/`answer` and answers them. Drop every item it
   gets wrong or calls flawed (`author_merge.py <dir> <slug>`).
3. **Audit:** a third session reviews a random 60 against the same error list as the API audit. The error count goes
   into this report's table.
4. **Load:** the files are already in `/opt/darb/sources` on the server. On the server run
   `bash /opt/darb/src/darb/deploy/import-packs.sh` (all packs) or `... import-packs.sh <slug>...` (it copies each
   file into the api container and runs `manage.py packs import <slug> <file>`). The code checks run on
   every line: the shape, SymPy, and near-duplicates (also against earlier imports). Lines with an unknown topic are
   counted and skipped. Lines that pass are stored as `verified` with `source = claude-code:<file>`.
5. **Build and publish:** `packs build <slug> --out DIR` (on the server, which holds `DARB_PACK_KEK`), upload to the
   CDN, then `packs publish <slug>`.

### Import + build dry run (2026-10-18)
`bash /opt/darb/src/darb/deploy/tests/packs-dryrun.sh` runs every file in `/opt/darb/sources` through `packs import`
on a throwaway DB and builds it with a throwaway key, then decrypts it back and counts the cards. The live DB and
`DARB_PACK_KEK` are not touched. Result: **all 48 packs build and decrypt; 21,403 of 22,183 lines kept**, about
70 min in all (mostly `qudurat-quant`: SymPy runs on every checked item). Expect the same time for your real import.

The first run dropped a third of every maths pack: the option check and the near-duplicate filter ignored signs and
symbols (`-10` = `10`, `x ≤ 1` = `x ≥ 1`) and treated other questions on one reading passage as repeats. That was
fixed in c00e5f3. The 772 that are still dropped were spot-checked and are real repeats: the same Telegram question
posted again with other spacing or digits, or an English item written twice. The 7 invalid lines are quant items
with two equal options.

| pack | lines | cards built & decrypted | invalid | repeat | size |
|---|---|---|---|---|---|
| `qudurat-quant` | 4,439 | 3,888 | 7 | 543 | 586 KB |
| `school-arabic-h1` | 344 | 344 | 0 | 0 | 37 KB |
| `school-arabic-m1` | 297 | 296 | 0 | 1 | 29 KB |
| `school-arabic-m2` | 296 | 293 | 0 | 3 | 29 KB |
| `school-arabic-m3` | 296 | 296 | 0 | 0 | 31 KB |
| `school-biology-h1` | 349 | 349 | 0 | 0 | 35 KB |
| `school-biology-h2` | 350 | 350 | 0 | 0 | 39 KB |
| `school-biology-h3` | 349 | 349 | 0 | 0 | 36 KB |
| `school-chemistry-h1` | 349 | 347 | 0 | 2 | 34 KB |
| `school-chemistry-h2` | 347 | 347 | 0 | 0 | 38 KB |
| `school-chemistry-h3` | 349 | 349 | 0 | 0 | 37 KB |
| `school-critical-thinking-h1` | 333 | 333 | 0 | 0 | 44 KB |
| `school-digital-h1` | 347 | 347 | 0 | 0 | 34 KB |
| `school-digital-m1` | 250 | 250 | 0 | 0 | 27 KB |
| `school-digital-m2` | 249 | 249 | 0 | 0 | 29 KB |
| `school-digital-m3` | 250 | 249 | 0 | 1 | 28 KB |
| `school-earth-h1` | 349 | 349 | 0 | 0 | 36 KB |
| `school-english-h1` | 347 | 347 | 0 | 0 | 31 KB |
| `school-english-h2` | 425 | 343 | 0 | 82 | 34 KB |
| `school-english-h3` | 349 | 349 | 0 | 0 | 39 KB |
| `school-english-m1` | 298 | 298 | 0 | 0 | 25 KB |
| `school-english-m2` | 298 | 297 | 0 | 1 | 26 KB |
| `school-english-m3` | 297 | 297 | 0 | 0 | 26 KB |
| `school-islamic-h1` | 347 | 347 | 0 | 0 | 40 KB |
| `school-islamic-m1` | 248 | 248 | 0 | 0 | 28 KB |
| `school-islamic-m2` | 246 | 246 | 0 | 0 | 28 KB |
| `school-islamic-m3` | 247 | 247 | 0 | 0 | 26 KB |
| `school-math-h1` | 346 | 346 | 0 | 0 | 31 KB |
| `school-math-h2` | 348 | 348 | 0 | 0 | 30 KB |
| `school-math-h3` | 350 | 349 | 0 | 1 | 31 KB |
| `school-math-m1` | 299 | 299 | 0 | 0 | 28 KB |
| `school-math-m2` | 299 | 299 | 0 | 0 | 27 KB |
| `school-math-m3` | 298 | 297 | 0 | 1 | 26 KB |
| `school-physics-h1` | 345 | 344 | 0 | 1 | 40 KB |
| `school-physics-h2` | 349 | 349 | 0 | 0 | 39 KB |
| `school-physics-h3` | 347 | 347 | 0 | 0 | 40 KB |
| `school-science-m1` | 300 | 300 | 0 | 0 | 32 KB |
| `school-science-m2` | 299 | 299 | 0 | 0 | 32 KB |
| `school-science-m3` | 300 | 300 | 0 | 0 | 31 KB |
| `school-social-h1` | 346 | 346 | 0 | 0 | 38 KB |
| `school-social-m1` | 249 | 249 | 0 | 0 | 26 KB |
| `school-social-m2` | 247 | 247 | 0 | 0 | 28 KB |
| `school-social-m3` | 248 | 248 | 0 | 0 | 27 KB |
| `tahsili-biology` | 696 | 696 | 0 | 0 | 77 KB |
| `tahsili-chemistry` | 697 | 696 | 0 | 1 | 75 KB |
| `tahsili-math` | 699 | 697 | 0 | 2 | 49 KB |
| `tahsili-physics` | 699 | 699 | 0 | 0 | 77 KB |
| `qudurat-verbal` | 1,777 | 1,644 | 0 | 133 | 238 KB |

**Student-collected questions (owner decision 2026-10-17):** the owner chose to use questions that students collect
after the test, starting with the Telegram channel `t.me/MezlaQ3` («تسريبات مظله - قدرات»). This replaces the "never
real items" rule for قدرات packs. The basis is a lawyer's verbal advice that this is lawful in Saudi Arabia. A written
opinion is a release blocker (DARB-RELEASE.md).
- The downloads are kept in `darb/content/sources/qudurat/mezla/`, which git ignores.
- Every item still needs a correct, checkable answer.
- Duplicates are merged. Incomplete items, and items whose answer can't be established, go to the owner as questions;
  nothing is guessed.
- Each item's `source` records the post it came from.
- Mezla's sheets say «جميع الحقوق محفوظة لمنصة مظلة التعليمية». The owner's choice (2026-10-17) is to credit Mezla
  for every item taken from them; the credit goes in the pack's `sources`, the item's `source` and an in-app sources
  list. What is reused is only the question (ETEC's, as recalled by students) and the fact of its answer. Every
  question is re-typed in Darb's format and every answer is re-solved. The explanations are written by us. Mezla's
  images, layout and wording of explanations are never reused.

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
Filled by `manage.py packs status` after phase 4 runs. The قدرات packs come from Mezla's own Telegram material (credited). Each item
was re-solved blind and its maths re-checked with SymPy, then a random 60 per pack was audited (2026-10-18). The audit found no errors.
The import is yours to run (live DB). "items" here are the authored lines; the import keeps 21,403 of them (repeats and invalid lines dropped, see the dry run above).

| pack | items | verified | quarantined | rejected | audited error rate (95% CI) | ships | cost |
|---|---|---|---|---|---|---|---|
| `qudurat-quant` | 4,439 | 4,439 | — | held for you: see `review/*-owner.md` | 0/60 = 0% (0–6.0%) | ✅ ships once you run the import | $0 API (solved in Claude Code) |
| `qudurat-verbal` | 1,777 | 1,777 | — | held for you: see `review/*-owner.md` | 0/60 = 0% (0–6.0%) | ✅ ships once you run the import | $0 API (solved in Claude Code) |
| `school-arabic-h1` | 344 | 344 | — | 6 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-arabic-m1` | 297 | 297 | — | 3 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-arabic-m2` | 296 | 296 | — | 4 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-arabic-m3` | 296 | 296 | — | 4 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-biology-h1` | 349 | 349 | — | 1 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-biology-h2` | 350 | 350 | — | 0 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-biology-h3` | 349 | 349 | — | 1 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-chemistry-h1` | 349 | 349 | — | 1 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-chemistry-h2` | 347 | 347 | — | 3 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-chemistry-h3` | 349 | 349 | — | 1 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-critical-thinking-h1` | 333 | 333 | — | 19 (blind solver or audit) | first audit 2/60 (explanations naming an option by position; 17 such items dropped); re-audit on a fresh sample: 1/60 = 1.7% (0.3%–8.9%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-digital-h1` | 347 | 347 | — | 3 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-digital-m1` | 250 | 250 | — | 0 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-digital-m2` | 249 | 249 | — | 1 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-digital-m3` | 250 | 250 | — | 0 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-earth-h1` | 349 | 349 | — | 3 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-english-h1` | 347 | 347 | — | 3 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-english-h2` | 425 | 425 | — | 8 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-english-h3` | 349 | 349 | — | 1 (blind solver or audit) | first audit 2/60 (explanations); all 349 explanations reviewed, 6 rewritten; re-audit on a fresh sample: 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-english-m1` | 298 | 298 | — | 2 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-english-m2` | 298 | 298 | — | 3 (blind solver or audit) | 1/60 = 1.7% (0.3%–8.9%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-english-m3` | 297 | 297 | — | 3 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-islamic-h1` | 347 | 347 | — | 3 (blind solver or audit) | 1/60 = 1.7% (0.3%–8.9%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-islamic-m1` | 248 | 248 | — | 2 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-islamic-m2` | 246 | 246 | — | 4 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-islamic-m3` | 247 | 247 | — | 3 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-math-h1` | 346 | 346 | — | 4 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-math-h2` | 348 | 348 | — | 3 (blind solver or audit) | 1/60 = 1.7% (0.3%–8.9%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-math-h3` | 350 | 350 | — | 0 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-math-m1` | 299 | 299 | — | 1 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-math-m2` | 299 | 299 | — | 1 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-math-m3` | 298 | 298 | — | 2 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-physics-h1` | 345 | 345 | — | 6 (blind solver or audit) | 1/60 = 1.7% (0.3%–8.9%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-physics-h2` | 349 | 349 | — | 1 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-physics-h3` | 347 | 347 | — | 3 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-science-m1` | 300 | 300 | — | 0 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-science-m2` | 299 | 299 | — | 1 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-science-m3` | 300 | 300 | — | 0 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-social-h1` | 346 | 346 | — | 4 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-social-m1` | 249 | 249 | — | 1 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-social-m2` | 247 | 247 | — | 3 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `school-social-m3` | 248 | 248 | — | 2 (blind solver or audit) | 0/60 = 0.0% (0.0%–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `tahsili-biology` | 696 | 696 | — | 4 (3 blind solver, 1 audit) | 1/60 = 1.7% (0.3–8.9%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `tahsili-chemistry` | 697 | 697 | — | 3 (blind solver disagreed or flagged) | 0/60 = 0% (0–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `tahsili-math` | 699 | 699 | — | 1 (blind solver disagreed) | 0/60 = 0% (0–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |
| `tahsili-physics` | 699 | 699 | — | 1 (blind solver: arguable) | 0/60 = 0% (0–6.0%) | ✅ ships once you run the import; unverified outline | $0 API (Claude Code) |

Status 2026-10-18: all 48 packs are authored, blind-solved, checked and audited (22,183 items), each at or under the
2% ship line. None is in the live DB yet: the import (and then `packs build` / publish, which read from it) is yours to run.
Items were written and solved in Claude Code, not through the API pipeline (which is built and tested; Phases 3-4 report).

Blueprints ready: `qudurat-verbal` (5 topics, 1,200 items) and `qudurat-quant` (9 topics, 1,200 items), both from
ETEC's official GAT guide.

Since 2026-10-16: 46 more (48 packs, 18,402 planned items; table in `darb/content/blueprints/README.md`, gaps in
`TODO.md`): تحصيلي math, physics, chemistry and biology (700 each); middle school m1-m3 × 7 subjects; high school h1 × 11
subjects and h2/h3 general track × 5. Their topic lists are **unverified**: ETEC's تحصيلي specification wasn't
reachable online and the MOE textbook portal (ien.edu.sa) needs a login, so they follow secondary sources and the
usual course scope. 👤 If you have the official تحصيلي guide or an ien.edu.sa login, I swap them for the real tables of
contents. Packs generated from an unverified blueprint are audited like any other (≤ 2% error) and say "unverified
outline" in the per-pack report.
