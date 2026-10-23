# CertDeck: Full Specification

Personal AI-powered spaced-repetition study app (Android + Django backend).

## Context
I'm a backend developer studying for software certifications, one at a time: AWS Certified Developer – Associate (DVA-C02) first, then AWS Solutions Architect – Associate (SAA-C03), then CKAD. This app fully replaces Anki for me. It is for my personal use only (single user, never published). Build it as fast as possible, working autonomously until the app is finished, installed on my phone, and the backend is deployed.

## Before you start: ask me everything in ONE batch
Ask me once for all of the following, then do not stop again unless something is destructive or blocked:
- VPS SSH host/user (I'll provide SSH access from this laptop)
- My domain, and the subdomain to use for the backend
- Anthropic API key (it lives ONLY on the backend, never in the app)
- GitHub: confirm `gh` auth on this machine; create a PRIVATE repo
- Phone connection: USB or wireless ADB for my OnePlus 12

## Tech stack
- **App:** Flutter (Android only, no iOS). Dark mode only, English only. Use a local SQLite-based database (e.g. Drift) and any state management you prefer.
- **Backend:** Django + Django REST Framework + PostgreSQL, deployed to my VPS (Ubuntu 24.04), served over HTTPS on the subdomain.
- **AI:** Anthropic API from the backend only, model `claude-opus-5-5` at medium effort. Verify the current model string and effort parameter in the official docs (docs.claude.com) before coding against it.
- **Scheduler:** FSRS. Use established, maintained FSRS libraries rather than writing the algorithm yourself: a Dart FSRS package in the app, and the Python `fsrs` package (including its optimizer) on the backend.
- Set up the Android SDK and any tooling yourself if missing.

## VPS safety rules (important)
The VPS already runs other production projects. Before deploying:
- Inspect the existing setup (reverse proxy, ports, Docker or not, Postgres) in read-only mode first.
- Isolate this project completely: its own directory, its own DB/user, its own service (Docker Compose or systemd), and an unused port.
- Only ADD a new server block/site for the subdomain. Never modify, restart, or reload anything belonging to other projects beyond a config test plus a graceful reload of the reverse proxy.
- Obtain a TLS certificate (e.g. Let's Encrypt) for the subdomain.
- Ask me before any action that could affect other projects.

## Architecture: offline-first
- All studying, scheduling, card browsing, and exam simulations work 100% offline from the local DB.
- Every review is stored as an append-only review log and queued for sync. Sync automatically whenever online (on app open, after sessions, plus a manual "Sync now" button).
- The backend is the full backup: all cards, images, review logs, settings, exam dates, and AI analyses. On a fresh install, logging in restores everything as if I never lost my phone.
- Auth: a single user with a long-lived API token, entered once in the app and stored in secure storage.
- AI features show a clear "Needs connection" state when offline. Per-card explanations are generated at card-creation time and stored locally, so they work offline.

## Data model essentials
- **Certifications:** name, code, official domains with weightings, my exam date, active flag. I study one certification at a time but can switch.
- **Cards** are stored ONCE and can be tagged with MULTIPLE certifications and domains, to handle overlap (e.g. DVA ↔ SAA).
  - When I switch certs, cards I've already mastered count toward the new cert's readiness and are not re-taught.
  - AI generation for a new cert targets only the gaps not covered by existing cards.
  - Deduplicate on generation by checking semantically against existing cards.
- Card fields: type, content per type, explanation (why the right answer is right AND why each wrong option is wrong), tags/domains, optional images, source, FSRS state.

## Card types
Support all of these, rendered well on a phone:
1. Basic (front/back)
2. MCQ single-answer (AWS-exam style, scenario-based)
3. MCQ multiple-answer ("choose 2/3")
4. Cloze deletion
5. Typed answer (e.g. a CLI command or service name), with lenient matching
6. Code/YAML/JSON snippet cards with syntax highlighting (for IAM policies, CloudFormation, Kubernetes manifests)
7. Image occlusion: hide regions of an image such as an architecture diagram; I can create these on the phone from a gallery/camera image
8. Ordering (arrange steps in the correct sequence)

Images can be attached to any card's question or answer (gallery, camera, or URL), stored locally, and backed up to the server. No audio, no LaTeX.

## Study session and confidence rating
- Before revealing the answer, I pick a confidence level: **Guessing / Unsure / Sure**.
- Map confidence plus correctness to an FSRS rating:
  - **Sure + correct** → Good, pushed out further (never Easy)
  - **Unsure + correct** → Hard (Good while the card is still learning, so it graduates)
  - **Guessing + correct** → Hard (Good while learning, same reason)
  - **Any wrong** → Again
- **Sure + wrong** is a "misconception": flag the card, show the AI explanation prominently, bring it back sooner, and weight it heavily in weakness analysis.
- After every answer, show the explanation, including why my chosen wrong option is wrong.
- Settings: adjustable new-cards-per-day limit and max reviews per day.

## Scheduling: FSRS core, with AI override
- FSRS decides due dates. Periodically re-optimize FSRS parameters on the backend from my review history and sync them to the app.
- **Exam-date awareness:** given my exam date, pace new cards so all domains (weighted by official exam weighting) are introduced with a buffer before the exam. Raise desired retention as the exam approaches, and include a final-days review mode that focuses on weak domains and misconceptions.
- **AI override** (when online): the AI may adjust due dates or priority for specific cards or domains when justified, e.g. misconceptions, weak domains near the exam date, or cards it judges mastered.
  - Every override is bounded, logged with a reason, visible in the card's history, and reversible.
  - FSRS remains the default for everything else.

## Leech handling
- Detect leeches (cards failed repeatedly; choose a sensible lapse threshold and make it adjustable).
- For a leech, the AI rewrites the explanation in a different way, generates 1–3 variant questions testing the same concept from different angles, and suggests learning content. I can also suspend it.

## AI features (backend endpoints, called from the app)
1. **Generate cards.** Inputs, any combination:
   - Certification + domain/topic (use the official exam guide as reference)
   - Pasted text (e.g. my course notes)
   - Uploaded PDFs
   - Screenshots/images

   Choose the best mix of card types for the material. Default count is 20 per request, adjustable. Cards go straight into the deck with no review queue. Every card includes full explanations and correct cert/domain tags.
2. **Explain.** Deeper "explain this to me" on any card, as a follow-up chat on that card.
3. **Weakness analysis.** Analyze review history per domain (accuracy, lapses, misconceptions, confidence calibration) and produce:
   - A ranked list of weak areas with a plain-language diagnosis
   - Specific actions, e.g. "generate 15 cards on X" as a one-tap action
   - Suggested video topics with YouTube search links (`https://www.youtube.com/results?search_query=...`)
   - Any scheduling overrides (see above)
4. **Variant generation** for leeches and for mastered cards I may have memorized by answer letter. Shuffle MCQ option order on every display regardless.

Use structured output (JSON schema / tool use) for all AI responses and validate before saving. Handle API errors and timeouts gracefully. Log token usage per request.

## Exam simulation
- **Defaults:** the official format of the selected exam (question count, time limit, domain weighting, scoring scale and passing score). Verify the current official exam guides before hardcoding these.
- For CKAD, which is performance-based, simulate with typed-command / YAML tasks under a timer.
- Everything is adjustable: question count, time, and domains.
- Draws from my cards, preferring scenario MCQs, and can ask the AI (if online) to generate fresh exam-style questions I haven't seen.
- Includes a flag-for-review feature, a review screen before submitting, and a results screen with score, per-domain breakdown, and explanations for every question.
- Exam answers feed back into FSRS and weakness analysis.

## Import / export
- Define and document a JSON schema for cards (all types, images as base64 or a referenced zip).
- Import/export works both as a file on the phone (share/save) and through the backend.
- Include an example JSON file in the repo.

## Stats (minimal, only what changes what I do)
- Today: due count and new-card count
- Per-domain readiness % for the active certification
- Predicted exam readiness/score against the exam date
- Leech list and misconceptions list

Nothing else.

## Delivery and workflow
- Work autonomously. Make sensible decisions yourself; note significant ones in `DECISIONS.md`.
- Private GitHub repo, monorepo (`/app`, `/backend`), with small meaningful commits pushed as you go. Never commit secrets: use `.env` files and add an `.env.example`.
- Formal test suites are not required, but you must verify things actually work: run the backend, hit the endpoints, build the app, and exercise the main flows on the device.
- README: how to run, deploy, and update the backend and the app, and how to change the API token.

### Milestones (do in order, but don't stop for approval between them)
1. Flutter app with local DB, all card types, the study session with confidence + FSRS, and manual card creation. Build and install on my OnePlus 12.
2. Django backend deployed on the VPS subdomain with HTTPS, token auth, sync, and full backup/restore.
3. AI card generation (all input types), explanations, and leech variants.
4. Exam date pacing, weakness analysis with AI overrides and video suggestions.
5. Exam simulation, JSON import/export, and minimal stats.
6. Final pass:
   - Polish the dark-mode UI
   - Test offline behavior (airplane mode)
   - Test restore on a clean install
   - Install the final release APK on my phone

## Definition of done
- The release APK is installed on my OnePlus 12, starts empty, and works fully offline for studying.
- The backend runs on my subdomain with HTTPS and hasn't disturbed my other projects.
- I can generate cards with AI, study with confidence ratings, take a timed exam simulation, see weak domains with suggestions, set an exam date, and import/export JSON.
- Uninstalling and reinstalling the app, then entering my token, restores everything.
- All code is pushed to the private GitHub repo with the README and `DECISIONS.md`.
- Give me a short summary at the end: what was built, the URLs, how to update, and anything I need to do manually.
