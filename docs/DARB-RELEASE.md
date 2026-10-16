# Darb: release checklist

✔ done and verified · ⏳ Claude, in progress or waiting on an input below · 👤 you (DARB-NEEDS-ME.md)

## Accounts and access (all 👤, in this order)
| Item | Owner | Status |
|---|---|---|
| Company registration, D-U-N-S | 👤 | |
| `darbedu.sa` + Cloudflare + R2 buckets (EU) | 👤 | |
| Google Play Console (organization) | 👤 | |
| Apple Developer Program (organization) + Small Business Program | 👤 | |
| Anthropic API key (Darb workspace, spend limit) | 👤 | ✔ on the server |
| Server: shared CertDeck host 169.58.7.222, `darb.mithaqstay.com` (owner decision 2026-10-16, instead of a Contabo VPS) | 👤 | ✔ deployed, TLS, nightly encrypted backups |
| RevenueCat project + keys; Google Cloud project (OAuth clients, Play Integrity, service account); App Store Connect API key + In-App Purchase key; SMTP; Sentry + Better Stack | 👤 | |

## Build
| Item | Owner | Status |
|---|---|---|
| Bundle/application id `sa.darbedu.app` | Claude | ✔ |
| Play target API 36; Xcode 26 / iOS 26 SDK; minimums Android 7.0 (API 24), iOS 13 | Claude | ✔ (DARB-DEVICES.md) |
| Release signing: Android upload key (generated on your machine, never in git) + Play App Signing; iOS distribution certificate + profile via the ASC API key | Claude, after your accounts | ⏳ |
| Release build obfuscated (`--obfuscate --split-debug-info`), symbols kept in `build/symbols` (Play Console and Xcode Organizer show app crashes; backend errors go to Sentry) | Claude | ✔ `darb/app/build-release.sh` (refuses to build an upload without the upload key) · ⏳ first signed build |
| Signed Android App Bundle uploaded to **internal testing**, then closed testing | Claude | ⏳ needs Play Console |
| iOS archive uploaded to **TestFlight** (CI macOS runner or the Hackintosh on Xcode 26.3) | Claude | ⏳ needs Apple account |
| iPhone only (no iPad screenshots) | Claude | ✔ |
| App icon (iOS set, Android legacy + adaptive), Play 512 icon, feature graphics AR/EN: the sign-in mark (Material `route_rounded`, Apache 2.0) + "درب" in Tajawal (SIL OFL) on the app teal, `darb/store/make-art.py` → `darb/store/out/` | Claude | ✔ placeholder · 👤 replace with a designed logo if you want one (rerun the script with it) |

## Store listing (draft: DARB-STORE-LISTING.md)
| Item | Owner | Status |
|---|---|---|
| Name, subtitle, short and full descriptions, keywords in Arabic and English (within limits) | Claude | ✔ drafted · 👤 review |
| Screenshots per the shot list (phone sizes), feature graphic 1024x500 | Claude, from the release build | ⏳ |
| Category (Education); contact email; privacy policy URL; web deletion URL | Claude drafted · 👤 publish the pages | ⏳ |
| Apple age rating **9+** (Kids Category: Not Applicable); Google target audience incl. 9-12, Families policy declarations; IARC questionnaire | 👤 submit the answers drafted in DARB-STORE-LISTING.md | |
| Google Data safety form + Apple App Privacy labels | 👤 submit the drafted answers | |
| Subscription products `darb_weekly` / `darb_monthly` / `darb_annual` (SAR 19 / 29 / 199), group "Darb Plus"; no intro offer or free trial (owner decision 2026-10-16) | Claude creates them via the APIs once keys exist · 👤 confirm prices (Apple price points; nearest point if SAR 19 / 29 / 199 is missing; no 3-month plan, decided) | ⏳ |
| App Review notes + demo account (adult; the age gate is the only minors flow) | Claude drafted · 👤 create the demo Google/Apple account | ⏳ |
| AI disclosure: in-app consent before the first AI use + AI labels + reporting (built); listing and privacy policy mention AI | Claude | ✔ app · drafted listing |

## Legal and compliance (drafts in `darb/legal/`, DARB-PDPL.md)
| Item | Owner | Status |
|---|---|---|
| Privacy policy, terms, support, deletion, AI-and-minors pages (Arabic + English) | Claude drafted · 👤 lawyer review | ⏳ |
| Pages live at `darbedu.sa/privacy`, `/terms`, `/support`, `/delete-account`, `/ai-and-minors` (+ `/ar/`) | Claude (served by nginx) · 👤 approve the text | ⏳ |
| SDAIA SCCs with processors; transfer risk assessment; DPIA (minors); registration decision; DPO decision | 👤 + lawyer | |
| Lawyer's **written** opinion that the قدرات packs may use student-collected test questions (t.me/MezlaQ3 etc.; verbal OK 2026-10-17, DARB-PACKS.md), including Mezla's "all rights reserved" notice on its sheets (credited, not licensed) | 👤 + lawyer | |
| Lawyer confirms no guardian consent is needed (owner decision 2026-10-16), or the switch (`DARB_GUARDIAN_CONSENT`) goes back on | 👤 | |
| Anthropic's child-safety prompt requested (if they provide one) | 👤 | |

## Product checks (exit checks per phase: DARB-PHASES.md)
| Item | Owner | Status |
|---|---|---|
| Google + Apple sign-in, age gate (guardian consent switch off by default), account deletion (in app + web) | Claude | ✔ built and tested · ⏳ sandbox run on devices |
| RevenueCat sandbox purchases on both platforms; a lapsed subscription loses access | Claude | ✔ backend tested · ⏳ sandbox run |
| AI: Haiku only, < 100k tokens, per-user cap, eval passes per feature | Claude | ✔ built · ⏳ eval run (key) |
| Packs: قدرات, تحصيلي, school subjects built, audited (≤ 2% error) or listed as blocked | Claude | ⏳ key + blueprints (question 6) |
| Light/dark, Arabic RTL, minimal settings, onboarding: small + large screens, old Android (7.0), old iOS (16.4) | Claude | ✔ CI walkthrough passed (runs 38956484671, 38959852858): iOS 16.4 + 18.5 SE, iOS 26.2 Pro Max, Android 7.0 phone + tablet, AR/EN × light/dark |
| Load test at the 100k-student profile; restore test | Claude | ✔ CI runs passed (DARB-LOADTEST.md, DARB-RESTORE.md) · ✔ restore drill on the server 2026-10-17 · 👤 R2 for off-server backups; load test not repeated on the shared host (it would load CertDeck) |
| Devices failing Play Integrity / App Attest get free features only, no Darb Plus content (decided 2026-10-16) | Claude | ⏳ |
| Monitoring: Sentry errors, uptime, AI spend alert | Claude | ✔ built · 👤 accounts |

## Submission (👤)
- Press Submit on both stores; answer reviewers. Google: up to 7 days for new accounts; Apple: usually 24-48 h.
