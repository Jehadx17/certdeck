# Darb: PDPL position, checklist and privacy-policy wording (draft for the lawyer)

Research only, not legal advice. Checked 2026-10-15. "Unverified" = only secondary sources or nothing found.

## What changes the plan
1. **A draft rule would require storing personal data inside the Kingdom.** SDAIA's draft amendments to the PDPL
   Implementing Regulation are open for comment until **2026-11-05**. Draft Art. 23(2): "The Controller shall store
   Personal Data within the Kingdom". It also makes registration mandatory for controllers that process minors' data or
   transfer data abroad (Darb does both), requires a DPIA for any processing of minors' data, and sets breach notice at
   72 h with no harm test. If adopted, it takes effect 60 days after publication in the Official Gazette
   ([Istitlaa](https://istitlaa.scbc.gov.sa/en/Transportation/NDMO/IRofPDPLAmendments2/Pages/default.aspx)).
   **Effect on Darb:** Contabo (Germany) stays the plan because no current rule forbids it, but the database must be
   movable. That is why it uses one `DATABASE_URL`, a dump/restore, and packs that hold no personal data. In-Kingdom
   options to price if the draft passes: a managed Postgres or VPS in a Saudi cloud region (Oracle Jeddah/Riyadh, Google
   Cloud Dammam, Huawei Cloud Riyadh, STC Cloud). Cloudflare R2 has no Middle East location
   ([R2 data location](https://developers.cloudflare.com/r2/reference/data-location/)). R2 holds only packs (no personal
   data) and **encrypted** backups, which is the part to confirm with the lawyer.
2. **Transfers abroad today: SDAIA's Standard Contractual Clauses are the realistic route.**
   - SDAIA has published no list of adequate countries.
   - The "service to the data subject" exemption needs the recipient to hold an SDAIA-licensed accreditation
     certificate. Contabo, Cloudflare and Anthropic don't, as far as I could find (unverified).
   - So transfers need the **SDAIA SCCs** (4 modules, not modifiable, Saudi law) plus a written **transfer risk
     assessment** before transferring (Transfer Regulation Art. 4, 7(1)(a);
     [regulation](https://dgp.sdaia.gov.sa/wps/portal/pdp/knowledgecenter/details/RegulationonPersonalDataTransferOutsidetheKingdom),
     [SCCs](https://dgp.sdaia.gov.sa/wps/portal/pdp/knowledgecenter/details/StandardContractualClauses)).
   - Anthropic's DPA uses the EU SCCs ([DPA](https://www.anthropic.com/legal/data-processing-addendum)). Getting vendors
     to sign SDAIA's text unmodified is a practical problem for the lawyer.
3. **Every student under 18 needs a guardian's consent where consent is the legal basis.**
   - PDPL Art. 5 and Implementing Regulation Art. 13 require guardian consent, and the controller must verify the
     guardianship by appropriate means ([PDPL](https://dgp.sdaia.gov.sa/wps/portal/pdp/knowledgecenter/details/PDPL2)).
   - Majority is 18 Hijri years, about 17.5 Gregorian (Civil Transactions Law Art. 12,
     [text](https://misa.gov.sa/app/uploads/2025/07/Civil-Transactions-Law.pdf)).
   - The "under 13" threshold in some blogs is not in the official text.
   - Google lets users manage their own account from 13 ([Google](https://support.google.com/accounts/answer/1350409)).
     Apple requires parents to create accounts under 13 ([Apple](https://support.apple.com/en-us/102617)). So a
     12-year-old signs in with a parent-managed account, and neither sign-in proves guardianship.
   - **Built in Darb (switchable, see DARB-PROTOCOL.md → guardian):** under-18 sign-up asks for a guardian's email; the
     guardian gets a link, reads a short notice and confirms. Until then the account can study the free sample on the
     phone, but nothing is synced, no AI runs and no purchase is offered. The time and method of the consent are
     recorded, and the guardian can withdraw it from the same link. The lawyer decides whether a confirmed email is
     "appropriate means" or whether more is needed.
   - Whether a minor may enter the subscription contract is also for the lawyer. Purchases go through the store account,
     which for minors is usually a parent-managed account (Ask to Buy / Family Link).

## Other obligations found
- **Registration** with SDAIA's National Register: required today for public entities, controllers whose core
  activity is processing personal data, and those processing sensitive data
  ([rules](https://dgp.sdaia.gov.sa/wps/portal/pdp/knowledgecenter/details/Rulesandguidelinesp2)). Registration for
  controllers outside the Kingdom opened in Oct 2026 ([Clyde & Co, 2026-10-08](https://www.clydeco.com/en/insights/2026/10/sdaia-opens-controller-registration-for-overseas-o)).
  The draft would make it mandatory for Darb.
- **DPO** if core activities involve "regular and systematic monitoring" ([DPO rules](https://dgp.sdaia.gov.sa/wps/portal/pdp/knowledgecenter/details/AppointingPersonalDataProtectionOfficer)).
  Whether tracking study progress counts is the lawyer's call.
- **Breach:** notify SDAIA within 72 h where harm is possible (IR Art. 24), and the affected students without undue delay.
- **Rights:** information, access, copy, correction, destruction, withdrawal of consent; answer within 30 days, plus 30
  with notice (IR Art. 3). Darb provides in-app deletion and a web request page; copy/export is on request by email in v1.
- **Privacy notice contents** (PDPL Arts. 12-13, IR Art. 4, [guideline](https://dgp.sdaia.gov.sa/wps/portal/pdp/knowledgecenter/details/ElaborationandDevelopingPrivacyPolicyGuideline)):
  identity, DPO contact, purposes, legal basis, retention, recipients, transfers abroad, rights, complaint route
  (escalation to SDAIA), change log.
- **Destruction** when the purpose ends, including backups, and recipients must be told (PDPL Art. 18, IR Art. 8).
  Processing records are kept for the life of the processing plus 5 years (IR Art. 33). Processor contracts must carry
  set terms (IR Art. 17). A DPIA is required for large-scale processing of minors' data (IR Art. 25).
- **Fines** up to SAR 5m, doubled for repeat violations (PDPL Art. 36).
- **Localization today:** NCA's CCC-2:2024 binds government and critical infrastructure only
  ([CCC](https://cdn.nca.gov.sa/api/files/public/upload/6d5408a3-d8e6-4e96-963b-2c7198e5b7c2_CCC-2-2024-EN-.pdf)). The
  CST cloud rules' transfer ban covers government data (unverified). I found no education-sector rule for private apps.

## Anthropic (AI provider)
- **Minors.** The Usage Policy treats under-18s as minors. Products that let minors use Claude must follow the
  guidelines for organizations serving minors ([guidelines, updated 2026-03-16](https://support.claude.com/en/articles/9307344)):
  age verification, content filtering, monitoring and reporting, safety guidance, Anthropic's child-safety system
  prompt, compliance with child-privacy law plus a public statement, and telling users they are talking to an AI.
- **New Usage Policy from 2026-11-12** ([AUP](https://www.anthropic.com/legal/aup)): the AI disclosure goes at the start
  of each session or in the interface. Grading that decides certification or admission needs human review. Darb's
  grading is practice only, and the app says so.
- **Built in Darb:**
  - Every runtime AI call carries a child-safety and on-topic system block.
  - AI text is labelled "AI" where it appears.
  - There is a one-time AI consent screen naming Anthropic, and every AI answer has "report".
  - No name, email or account id is sent in prompts.
  - Students cannot chat freely: only about the card or upload in front of them.
- **Data handling:**
  - API data is deleted within 30 days (flagged content longer) ([retention](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data)).
  - It is not used for training by default ([training](https://privacy.claude.com/en/articles/7996868-is-my-data-used-for-model-training)).
  - Zero data retention is available on request but excludes the Batch API
    ([ZDR](https://platform.claude.com/docs/en/manage-claude/api-and-data-retention)).
  - Stored data is in the US only. Inference is "global" by default or "us" at 1.1x; there is no EU or Middle East option
    ([residency](https://platform.claude.com/docs/en/manage-claude/data-residency)).

## Pre-launch checklist (for you and the lawyer)
| # | Item | Who |
|---|---|---|
| 1 | Data-flow map: phones → Cloudflare → Contabo DE (account, study data); R2 `eu` bucket (packs, encrypted backups); Anthropic US (card text, answers, uploaded pages; no names/emails) | done here, lawyer reviews |
| 2 | SDAIA SCCs (controller-to-processor) with Contabo, Cloudflare, Anthropic, RevenueCat, Sentry, the email provider, or another documented basis | you + lawyer |
| 3 | Transfer risk assessment per destination (Art. 7) | lawyer, from item 1 |
| 4 | DPIA for minors' data | lawyer, from item 1 |
| 5 | Legal basis per purpose; confirm the guardian email flow is enough verification | lawyer |
| 6 | Under-13: sign-in needs a parent-managed Google/Apple account (stated in the sign-up screen) | built |
| 7 | Register with SDAIA (arguable now, mandatory if the draft passes); track the draft after 2026-11-05 | you |
| 8 | DPO decision; publish the contact in the privacy policy | you + lawyer |
| 9 | Processor contracts per IR Art. 17; sub-processor list (in the privacy policy draft) | lawyer |
| 10 | Processing records kept 5 years after processing ends | ops runbook (DARB-OPS.md) |
| 11 | Breach runbook with a 72-hour SDAIA notice | DARB-OPS.md |
| 12 | Rights: in-app deletion (built), web deletion page (drafted), copy on request within 30 days | built + you |
| 13 | Retention schedule (below) | lawyer confirms |
| 14 | Anthropic minors guidelines: child-safety prompt, AI label, reporting; publish the compliance statement (in the legal drafts) | built + you publish |
| 15 | Privacy policy in Arabic and English, child-friendly summary, change log, SDAIA complaint route | drafted in `darb/legal/`, lawyer reviews |
| 16 | Budget an in-Kingdom hosting option in case draft Art. 23(2) passes | you |

## Retention schedule (draft)
| Data | Kept | Deleted |
|---|---|---|
| Account (name, email from Google/Apple, birth year, guardian email and consent record) | while the account exists | within 30 days of deletion; backups age out within 35 days (backup retention) |
| Study data (settings, sessions, review log, uploads, AI outputs) | while the account exists | same as above; uploads deleted at once |
| Subscription status | while the account exists | entitlement records kept by Apple/Google/RevenueCat under their own terms |
| AI call log (tokens, cost; no content) | 13 months | then dropped |
| Server logs (IP, path) | 14 days | rotated |
| Consent records | life of the account + 5 years | IR Art. 33 |

## Draft privacy-policy wording
The full drafts are in `darb/legal/` (privacy, terms, deletion, support), in Arabic and English. Key paragraphs:

> **Where your data goes.** We store your account and study data on servers run by Contabo in Germany, and backups (encrypted) in Cloudflare R2 storage restricted to the European Union. When you use AI features, the study content you send is processed by Anthropic in the United States [and other countries where Anthropic runs its models]. These transfers are needed to provide the app. We protect them with the Standard Contractual Clauses issued by the Saudi Data and AI Authority (SDAIA). We assessed their risks before starting, and we send each service only what it needs.

> **Students under 18.** Under Saudi law, you need a parent or legal guardian's consent to use Darb until you reach 18. When you sign up, we ask for your guardian's email and they confirm by opening the link we send them. Guardians can see, correct or delete their child's data, and can withdraw consent at any time. Students under 13 need a Google or Apple account that a parent manages. We do not sell children's data, show ads, or use any data for advertising.

> **AI features.** Some features, such as explanations, grading of practice answers and making cards from your uploads, send the text of your cards, answers and uploaded pages to Anthropic's Claude AI. We never send your name or email with these requests. AI responses are generated by a computer, not a teacher, and may contain mistakes; every AI answer has a Report button. Grading in Darb is for practice only. Anthropic does not use this data to train its models and deletes it within 30 days, unless it is needed to investigate misuse or the law requires it.

> **How long we keep data.** We keep your account and study history while your account is active. If you delete your account, we delete your data within 30 days, and it disappears from our backups within 35 more days. We ask our providers to delete their copies.

> **Your rights.** You, or your guardian, can ask to know what data we hold, get a copy, correct it, delete it, or withdraw consent: in the app (Settings → Account) or by email to support@darbedu.sa. We reply within 30 days; if we need up to 30 more, we will tell you why. If you are not satisfied, you can complain to SDAIA.
