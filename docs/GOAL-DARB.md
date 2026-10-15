# Goal: build Darb (درب) and get it ready to submit to Google Play and the App Store

> Paste everything below the line into Claude Code. This is the build goal. The decisions below are made; execute and verify each phase. If something is genuinely unclear or a new decision comes up mid-build, ask me (batch questions, don't guess) and keep working on whatever isn't blocked.

---

## Outcome
Darb is a public, subscription study app for Saudi students (middle school, high school, university, certifications), built from this repo's CertDeck code as a **new app on a new bundle ID and a new backend**. The private CertDeck app, its server, its users and the `qa-student` account stay untouched. Done means: both store builds are signed and uploaded to internal/TestFlight tracks, the backend is deployed and load-tested, all content packs are built and verified, and only my own actions (below) remain before pressing Submit.

## Fixed decisions (treat as settled; raise a question only if one proves wrong or impossible)
**Identity**
- Name: Darb / درب. Bundle/application ID: `sa.darbedu.app` on both stores. Domain: `darbedu.sa` (keep it in one config value; I may not own it yet). Arabic-first RTL UI with English available. Prices in SAR.

**Stack**
- Keep Flutter + Django/DRF. Move SQLite to Postgres, hosted on **Contabo VPS** (my current provider) with a new Docker stack, nginx, HTTPS, Cloudflare in front. Start on one VPS and grow to the 100k-student layout below. Postgres uses continuous archiving and backups to R2 (pgBackRest or equivalent) with a **restore test before launch**; the connection is a single `DATABASE_URL` setting so the database can move to a managed service (e.g. RDS) later with only a dump/restore. Check Contabo's current prices and datacenter locations from its site, and report latency from Saudi.
- **Design for 100k registered students** (about 30k monthly active, peak around 100 requests/second). Target layout at that size, about 5 VPS and under €100/month: 2 app containers, a Postgres primary and a standby, and 1 worker server. Fix these before launch, because they are cheap now and costly later:
  1. **Sync write lock:** `save_docs` in `backend/core/models.py` locks one global `Counter` row on every write, serializing all students. Replace the global `seq` with a per-user cursor (update `docs/PROTOCOL.md` and the app's sync client together).
  2. **Table size:** every card and review log is a JSON row in one `Doc` table, which reaches hundreds of millions of rows at 100k students. Store review logs in a compact partitioned table (or aggregates) and keep documents small; plan indexes, vacuum settings, backup size and restore time.
  3. **Blocked workers:** gunicorn runs 2 workers x 8 threads and AI calls can take up to 300 seconds. Run AI and other slow work on the job queue and a separate worker pool so slow AI calls can never block sync.
  4. Add PgBouncer; keep the app containers stateless; use Cloudflare for caching and basic protection. Packs and media in S3-compatible storage with a CDN (Cloudflare R2). Background jobs on a Postgres-backed queue (no Redis/Celery). Google and Apple ID-token verification in the backend (no Firebase Auth). Sentry and uptime monitoring on free tiers. Billing via RevenueCat with webhook-verified entitlements on our backend (the backend, not the app, decides who is subscribed).
- Backend must be **stateless and horizontally scalable** (several identical containers behind nginx), with a pooler for Postgres, a read-replica option, and packs served from storage/CDN, never from Django. Document the upgrade path (bigger VPS, then managed services) with the trigger metric for each step.
- **Flutter/tooling:** upgrade only as far as Google Play's current target-API rule and Apple's current Xcode/SDK rule require. Choose the oldest Flutter version that satisfies both and keep the **lowest minimum Android and iOS version** that version and every dependency (RevenueCat, Google/Apple sign-in, attestation, notifications, local DB) allow. Record the resulting minimums and every dependency that forced a floor in `docs/DARB-DEVICES.md`. If the Hackintosh cannot run the Xcode Apple requires, use the cheapest fix (free CI macOS runner, then a rented/used Mac) and tell me the cost.
- Weak devices: low-RAM phones, small screens, slow networks. Pack downloads must resume. Where Play Integrity / App Attest is unavailable, degrade (stricter rate limits, no premium keys issued) instead of blocking the student. Test on at least one old Android emulator/device and one old iOS simulator.

**Sign-in and accounts**
- Google and Apple sign-in only (Sign in with Apple is mandatory on iOS). No passwords or tokens. Minors (12–17): age gate at sign-up, minimum data (name/email from the provider), no ads, no third-party tracking, in-app account deletion plus a public web deletion URL, PDPL-aware.

**Product**
- One short onboarding: segment (middle / high / university / certification), then grade or track, then exam or goal date. After that the existing autopilot tunes difficulty, session length and new-card load silently. Home screen, vocabulary and default plan differ per segment.
- Settings contain only: theme (light/dark/system), language, account, subscription, notifications, study goal/exam date, delete account, and one collapsed **Advanced** section. Everything else is automatic. Light and dark themes everywhere from day one, RTL tested on every screen.
- Free tier is permanent and limited: study existing cards, sample exam questions, a small daily AI quota. Subscribers get the full exam banks, higher AI limits and **uploads** (PDF/photos with strict size and page limits).
- Subscriptions (SAR): weekly **19**, monthly **29**, annual **199**. Weekly is a deliberate decoy; highlight annual. Use store free-trial/intro offers where allowed.
- Built-in support: one support email, in-app help/FAQ and "report a mistake" on every question, and an admin page where I can look up an account, check entitlement, reset a quota and see AI spend.

**AI**
- Runtime AI uses **only `claude-haiku-5-5`**, every request under **100k input tokens** (cheap price tier; see `PRICES`/`LONG_PRICES` in `backend/core/ai.py`). Students never trigger Opus/Sonnet; those are used by us offline for content generation, verification and prompt tuning.
- Quality must not drop. Build a small fixed eval set (cards, explanations, grading, re-teach, Arabic quality), run it on the current Opus/Sonnet setup and on Haiku, and switch each feature to Haiku only when it passes; otherwise fix with prompts, structured output, validation and retries before considering a bigger model.
- Cost levers: prompt caching, Batch API for uploads and pack generation, caching AI answers per card/lesson across users, precomputed explanations in packs, tight `max_tokens`, no resending of full chat history.
- Hard monthly dollar cap per user, tracked from real usage (extend `AiCall`/`cost_usd`). Defaults: free about $0.03/month, paid about $0.50/month, adjustable from admin without an app update. The user sees a friendly "resets on <date>" message and never a settings screen.

**Content (قدرات, تحصيلي, school subjects)**
- Pre-built packs are the core product: قدرات (verbal + quantitative), تحصيلي (all tracks and subjects), and **all middle- and high-school subjects**, aligned to the blueprint of هيئة تقويم التعليم والتدريب and the Ministry of Education curriculum.
- Sources: PDFs I provide (mostly already tutor-reviewed; tag `tutor-reviewed`), web examples used **only for format, style and difficulty distribution**, and tutor videos I may provide (transcribe cheaply, e.g. local Whisper; use as teaching material). Never copy or closely paraphrase copyrighted questions, tutors' exact words or slides. Keep a source log per pack and flag any item with unclear rights for me.
- Anything not tutor-reviewed is verified by AI only, so the pipeline must include: an independent blind-solve pass that must match the key, duplicate and difficulty checks, code-based checking of math/science answers where possible, quarantine of anything the verifiers disagree on, and a report with the measured error rate per pack. If a subject cannot reach an acceptable measured error rate, do not ship it silently: list it for me.
- Build order: قدرات, then تحصيلي, then core school subjects, then the rest. Everything ships in the first release, so keep the pipeline resumable and Batch-API based.

**Content delivery and anti-scraping**
- Free users get a small plaintext sample. Subscribers download **encrypted packs**, keys bound to account and device and issued only after an entitlement and attestation check. Layers: per-account/device/IP rate limits; signup throttling and disposable-email checks; Play Integrity and App Attest; short-lived signed requests; certificate pinning; non-enumerable IDs; per-user watermarking of served questions so leaks can be traced; release obfuscation with no secrets in the binary; anomaly detection with automatic suspension and an appeal path. AI endpoints require auth, entitlement, attestation and the cost cap so they cannot be used as a free Claude proxy.
- State in the docs honestly that this raises the cost of scraping but cannot stop a determined attacker on a rooted device.

## Phases (finish and verify each before the next; commit per phase)
0. **Foundation:** new app/backend scaffolding with the new bundle ID; Postgres migration; Docker stack; Flutter/tooling upgrade to the chosen versions; `docs/DARB-DEVICES.md`; CI that runs backend and Flutter tests. *Exit:* both apps build and launch on Android and iOS simulators, tests green.
1. **Accounts and billing:** Google/Apple sign-in, onboarding, age gate, account deletion, RevenueCat products and webhook, entitlement checks, free/paid gating. *Exit:* end-to-end sandbox purchases on both platforms; a lapsed subscription loses access.
2. **AI gateway:** Haiku-only, caps, caching, quotas, admin spend view, eval harness. *Exit:* eval report shows Haiku passes per feature; cost per typical session measured.
3. **Pack pipeline and delivery:** pack format, generation and verification pipeline, encryption and key issuing, resumable downloads, CDN. *Exit:* a sample pack of each type is generated, verified, downloaded and studied offline on an old device.
4. **Content at scale:** run the pipeline for all packs in the build order above; produce per-pack quality reports and the list of items needing my attention. *Exit:* all packs built and verified or explicitly listed as blocked.
5. **Segment UX and polish:** per-segment home screens, minimal Settings, paywall, light/dark, Arabic/RTL, empty/error/offline states, accessibility basics, support screens. *Exit:* walkthrough of each segment on small and large screens in both themes.
6. **Hardening and scale:** attestation, rate limits, watermarking, pinning, obfuscation, anomaly rules; load test at the 100k-student profile (about 100 requests/second sync mix, plus AI calls and a pack-download spike; also report launch traffic of about 500 new students/week) and report which metric triggers each scaling step; backups restore-tested; monitoring and alerts on errors and AI spend. *Exit:* load-test and restore reports in `docs/`.
7. **Release prep:** signed Android App Bundle and iOS archive; store listings in Arabic and English (text, screenshot specs, age rating, data-safety and privacy labels, subscription products, review notes with a demo account); privacy policy, terms, support and deletion pages drafted for my review; uploads to Play internal/closed testing and TestFlight. *Exit:* a release checklist with every store requirement ticked or assigned to me.

## Needs me (stop and tell me exactly what to do, then continue with the rest)
- Create and pay for the Google Play Console and Apple Developer accounts, finish the company registration, buy/confirm `darbedu.sa`, and hand you the access you need (App Store Connect API key, Play service account, RevenueCat keys, Cloudflare and VPS access, Anthropic API key). At the start of Phase 0 give me an ordered checklist with cost and expected approval time; Google's closed-testing requirement for new accounts must be checked against its current rule.
- Provide the PDFs and any tutor videos; confirm each tutor's permission before their material ships; review the legal pages; decide any item the content pipeline lists as blocked.
- Run the Google/Apple review submissions and respond to reviewer messages.
- Confirm the PDPL position on keeping student data on servers outside Saudi Arabia (Contabo's datacenters, R2, Anthropic API). Research the current rule and draft the checklist and wording for the privacy policy; I take it to a lawyer.
- Decide whether AI-generated content needs a disclosure in the stores and in-app (recommend an answer after checking current policy).

## Rules
- Don't touch the private CertDeck app, server or users. Never put the Anthropic key or any secret in the app or in git.
- Keep it simple: build what a student needs in v1 and list anything cut. Verify store, pricing and SDK facts from current official docs, not memory, and cite them in the relevant `docs/` file.
- Each phase ends with a short report: what was built, how it was verified, cost measured (AI and infra), and what is next. Do not claim a phase is done without running its exit check.
- Budget guidance (my estimates; replace with measured numbers as you go): one-time about $1,100–3,700 (accounts, registration, legal, content generation); monthly about $50–150 at launch and $150–400 around month six; ads are my separate decision. Tell me early if any phase will exceed these.
