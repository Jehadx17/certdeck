# Darb: AI eval report (2026-10-16)

Each runtime feature on CertDeck's setup (Opus writes, Sonnet reads; medium effort) and on Darb's (**claude-haiku-5-5**, low effort, tight max_tokens), on the fixed set in `darb/backend/core/eval_set.json`. claude-opus-5-5 scored each pair blind and in random order; grading is checked against hand-set gold scores. Pass rules: judged overall >= 4.0, at most 1.0 below the old setup (was 0.3; owner decision 2026-10-18), at most 1 item judged incorrect; grading mean error <= 0.15 and verdict agreement >= 85%; Arabic language >= 4.0. Re-run: `manage.py ai_eval`.

| feature | n | old setup | Haiku | Haiku $/call | old $/call | Haiku s | result |
|---|---|---|---|---|---|---|---|
| explain | 12 | 4.83 (wrong 1) | 4.08 (correct 4.58, wrong 0) | 0.00061 | 0.03531 | 5.9 | **pass** |
| grade | 10 | MAE 0.000, agree 100% | MAE 0.000, agree 100% | 0.00026 | 0.01100 | 2.3 | **pass** |
| cards | 4 | 4.50 (wrong 0) | 3.75 (correct 4.25, wrong 0) | 0.00473 | 0.07655 | 33.8 | **fail** (3.75 < 4.0; see note) |
| reteach | 6 | 4.17 (wrong 0) | 4.00 (correct 4.17, wrong 0) | 0.00182 | 0.01657 | 16.5 | **pass** |
| Arabic quality (all Arabic outputs) | 15 | | language 4.47 | | | | **pass** |

## Cost per typical session (measured Haiku prices)
- Free session (1 explanation + 1 graded answer): **$0.00086**; 20 sessions/month: $0.0172 (free cap $0.030).
- Plus session (3 explanations, 2 graded answers, a daily re-teach, 10 uploaded pages a week): **$0.00514**; 20 sessions/month: $0.1029 (Plus cap $0.500).
- This eval run cost $1.60 (judge $0.68).

## Runs behind this report (2026-10-17)
- Prompt v1, all features: explain 3.50, cards 3.50, reteach 3.83 FAIL. Grade and Arabic passed (the grade row above
  is from this run). The main fault was explain answering English-UI students in Arabic: the request never named the
  reply language.
- Prompt v2: the reply language is stated; a writing rule (Modern Standard Arabic, no stray English notes, literally
  correct analogies, no duplicate cards); explain, cards and reteach at medium effort. Reteach passed (row above).
- Prompt v3 (current): cloze blanks may not be given away, strict-order ordering cards, recheck every number. The
  explain and cards rows above are from this run. Reteach was not re-run on v3; the v3 rules only tighten
  cloze/ordering cards.
- Result: explain and cards have no wrong answers and are at or above the absolute bar (4.0), but stay about 0.75
  below Opus/Sonnet. They fail only the "at most 0.3 below the old setup" rule. Further prompt tuning stopped
  improving it. Owner decision 2026-10-18: the absolute 4.0 bar decides, so both pass; every feature runs on Haiku.
  Correction 2026-10-19: cards scored 3.75 overall, under that 4.0 bar, so by `core/evals.py` cards **fails**; the
  earlier "pass" was wrong.
  Re-run 2026-10-19 with the tuned prompt (realistic application cards, mistake-based distractors, a final self-check):
  cards still **fails**: 3.75 again (items 4, 3, 4, 4), with no wrong answers.
  - The 3 is the English photosynthesis set, where card text contradicts its explanation, two options say the same
    thing, and a stoichiometry problem goes beyond the source.
  - The Arabic items lost a point for recall-only cards and imprecise wording.
  The self-check now also covers those faults (commit f0440f2).
  Re-run 2026-10-19 on f0440f2: cards **fails**, 3.25 (items 4, 3, 3, 3), no wrong answers. The longer self-check
  made it worse. The judge's faults: duplicate cards, explanation slips (light called a reactant, "left side" in RTL
  text), a meta note leaking into an explanation, English symbols/units in Arabic text, awkward Arabic grammar, and
  recall-only cards. Prompt tuning on Haiku at medium effort has stalled at 3.25-3.75 over four runs.
  Re-run 2026-10-19 with a Haiku review pass over the drafts (76be196): cards **fails**, 3.75 (items 4, 4, 3, 4), no
  wrong answers. The physics, photosynthesis and analogy sets reached 4. The geometry set stayed at 3: the review
  cut it to two plain problems (it treated the recall cards as duplicates), and Haiku wrote Latin units (cm) and
  variables in Arabic text that the source doesn't use. The review rules now keep every angle per point and require
  Arabic units and variables. 👤 Deploy, then re-run `ai_eval cards` (about $0.40).
