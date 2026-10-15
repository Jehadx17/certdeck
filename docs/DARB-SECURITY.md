# Darb: anti-scraping and abuse protection

**Honest statement:** these layers raise the cost of scraping Darb's question banks and of using its AI as a free
proxy. They **cannot stop a determined attacker with a rooted or jailbroken phone**, who can read the decrypted
questions from memory. The goal is that copying at scale is slow, traceable to an account, and gets that account
suspended, not that it is impossible.

| Layer | Where | Status |
|---|---|---|
| Free users get only a small plaintext sample; full packs are encrypted (AES-256-GCM, a key per version) | core/packs.py, app lib/packs.dart | built, tested |
| Keys only for a subscribed account's device, max 40 a day per device, every grant logged | `PackGrant`, packs.issue_key | built, tested |
| Per-account watermark (option order + invisible marker) | app watermark() | built, tested |
| Rate limits per IP (nginx, Cloudflare's one rule) and per account/device in Django: sign-in, sign-up, guardian emails, reports, uploads, AI quotas | core/limits.py, nginx.conf | built, tested |
| Sign-up throttling (8 new accounts per IP per day). Disposable-email checks don't apply: only Google/Apple accounts | limits | built |
| Anomaly rules hourly: pack keys on > 5 devices or from > 12 IPs a day, > 20,000 reviews a day → automatic suspension; the student sees the support address to appeal, the admin restores | core/limits.py, admin | built, tested |
| AI endpoints: auth, guardian consent, monthly dollar cap and daily quota per account, Haiku only, on-topic safety prompt, no free-form chat (only about the card in front of the student) | core/ai.py | built, tested |
| Non-enumerable ids: account public ids are random; tokens are 256-bit random, stored hashed | models | built |
| Play Integrity / App Attest; devices that can't attest get stricter limits | phase 6 | **open: question 7 (key policy)**, then the server verifier and the `app_device_integrity` plugin |
| Short-lived signed requests | phase 6 | per-device tokens + TLS today; request signing with the attested key comes with App Attest |
| Certificate pinning: the app trusts only 13 roots (Let's Encrypt ISRG X1/X2, Google Trust Services R1-R4, SSL.com 2022 and older roots, plus the Certum and GlobalSign cross-signers), not the phone's store. A user-installed proxy CA can't read the API. Checked live: Let's Encrypt and GTS sites, including Cloudflare's edge, are accepted; DigiCert and Sectigo sites are rejected. **Risk:** Cloudflare's docs advise against pinning because Universal SSL may change CA. Pinning every root of its three CAs avoids the usual breakage; if Cloudflare ever adds a fourth CA, an app update is needed (DARB-OPS.md: watch Cloudflare's CA announcements) | app lib/api.dart, assets/roots.pem | built, verified |
| Release obfuscation, no secrets in the binary | build | `--obfuscate --split-debug-info` in release builds; the app holds only public ids (Google client ids, RevenueCat public SDK keys) |
| Admin behind Cloudflare Access + a non-default path | deploy | documented in DARB-OPS.md |
