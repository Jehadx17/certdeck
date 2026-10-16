# Darb: what I need from you (ordered)

Do these in order: later steps depend on earlier ones. Fees and times are from [DARB-STORES.md](DARB-STORES.md) and
[DARB-INFRA.md](DARB-INFRA.md) (checked 2026-10-15). "?" = not on an official page.
**Never paste secrets into chat or git.** Put them in `darb/backend/.env` or `darb/deploy/.env` on your machine (both
gitignored), or on the server in `/opt/darb/.env`, and tell me the file is ready.

| # | What | Cost | Expected time | Unblocks |
|---|---|---|---|---|
| 1 | **Finish the company registration** (commercial registration) | your current process | ? | 2, 3, 4, 5 |
| 2 | **D-U-N-S number** for the company (free; request through [Apple's lookup](https://developer.apple.com/enroll/duns-lookup/)) | free | up to 5 business days + 2 for Apple; Google says up to 30 days | 4, 5 |
| 3 | **Buy/confirm `darbedu.sa`** and add it to a **Cloudflare** account (free plan). Turn on **R2** (needs a card; free tier covers launch). Create an R2 bucket `darb-packs` and `darb-backups` with **EU jurisdiction**. Create an R2 API token (read/write on both) and a Cloudflare API token (DNS edit, Zone settings) | domain ~SAR 100-200/yr (?), Cloudflare free, R2 < $1/mo at launch | domain: hours to days (.sa may ask for the CR) | website verification for Google, legal pages, packs CDN, backups |
| 4 | **Google Play Console, organization account** (avoids the 12-tester/14-day closed test that personal accounts need) | US$25 once | days to weeks (identity + D-U-N-S + website verification) | Play uploads, Android sign-in client, Play billing, Play Integrity |
| 5 | **Apple Developer Program, organization** + enroll in the **Small Business Program** (15%) | US$99/yr | days (after D-U-N-S) | TestFlight, Sign in with Apple, StoreKit, App Attest |
| 6 | ✔ **done** · **Anthropic API key** in a new workspace "Darb" (separate from CertDeck), with a spend limit. Prepay credits | eval ~$20-40; content generation ~$600-1,500 (estimate, Phase 4 measures it); runtime capped per user | minutes | AI eval (Phase 2), packs (Phases 3-4) |
| 7 | ✔ **replaced**: Darb runs on the CertDeck server (169.58.7.222) at `darb.mithaqstay.com` in `/opt/darb`, own containers and DB (your decision 2026-10-16). A Contabo VPS is only needed when Darb outgrows that box (DARB-INFRA.md). Was: **Contabo Cloud VPS 8, Germany** (Ubuntu 24.04), with my SSH key (`~/.ssh/id_ed25519.pub` on this laptop) as root | €14/mo (€11.90 on a 12-month term) | minutes | backend deploy, load test, restore test |
| 8 | **RevenueCat** account (free tier). Project "Darb"; give me the secret API key (v1) and choose a webhook auth string; I give you the webhook URL | free at launch (? check their pricing page for the revenue threshold) | minutes | billing |
| 9 | **Google Cloud project "darb"**: OAuth consent screen (external, app name Darb), enable Play Integrity API and Google Play Android Developer API, a service account JSON (for RevenueCat and Play Integrity), link it in Play Console → API access | free | 1 hour; consent screen verification may take days | Google sign-in, attestation, RevenueCat ↔ Play |
| 10 | **App Store Connect API key** (Admin role, .p8 + key id + issuer id) and an **In-App Purchase key** (.p8, for RevenueCat) | free | minutes | I create the app record, subscriptions, TestFlight uploads |
| 11 | **Mac for iOS builds**: boot the Hackintosh into macOS, update to **Sequoia 15.6 or later**, install **Xcode 26.3** (the last Xcode that runs on Sequoia; Apple requires Xcode 26 since 2026-04-28). If it can't reach 15.6, say so and I set up a cloud macOS runner (cost in DARB-DEVICES.md) | free (or runner cost) | 1-2 h | iOS simulator checks, iOS archive |
| 12 | **Email sending** for support@darbedu.sa and the guardian consent emails: pick a provider with SMTP (Amazon SES ~$0.10 per 1,000 emails, or Resend/Postmark free tiers) and give me SMTP credentials | ~$0-1/mo | SES may need a sandbox exit (~1 day) | guardian consent, deletion requests |
| 13 | **Sentry** (free Developer plan) and **Better Stack** (free) accounts: Sentry DSNs for the backend and the app | free | minutes | errors and uptime alerts |
| 14 | **Content**: the PDFs (قدرات, تحصيلي, school subjects), any tutor videos, and each tutor's written permission | | your pace | tutor-reviewed packs (AI-only packs don't wait for this) |
| 15 | **Lawyer**: review DARB-PDPL.md and `darb/legal/` (privacy, terms, deletion, support), the SDAIA SCCs, and the guardian-consent method | lawyer fees | | release |
| 16 | **Store submissions**: press Submit, answer reviewers | | Apple ~24-48 h; Google up to 7 days for new accounts | launch |

## Where things stand
Updated as phases finish; see [DARB-PHASES.md](DARB-PHASES.md) for the per-phase reports.

## Your answers (2026-10-16)
| # | Question | Answer | Done |
|---|---|---|---|
| 1 | Guardian email consent for under-18s? | **No** | `DARB_GUARDIAN_CONSENT` defaults to off (the code stays; the lawyer confirms another legal basis or it goes back on, DARB-PDPL.md) |
| 2 | Nearest Apple price point if SAR 19/29/199 isn't exact? | Yes | applied when the products are created |
| 3 | Certification segment = your own uploads only? | Yes | as built |
| 4 | Free trial? | **No trial; the free plan (limited access) is the trial** | paywall trial labels removed; no intro offers |
| 5 | Keep the server in Germany (Contabo)? | Yes | as planned; the lawyer covers the transfer |
| 6 | Restart the exam-outline (blueprint) research? | Yes | running |
| 7 | Phones failing the genuine-device check? | Free features only | the spec default; enforced once Play Integrity / App Attest keys exist |
| 8 | 3-month plan or a lower annual price? | No | weekly / monthly / annual only |
