# Darb: store listings, disclosures and review notes (draft, 2026-10-16)

Everything here is ready to paste into App Store Connect and Play Console after the owner fills the `[...]` placeholders.
Store limits were read on the official pages on **2026-10-16** (table below). "UNVERIFIED" means I could not confirm it
on an official page; check it in the console before submitting. The legal pages are in `darb/legal/`; facts come from
DARB-PDPL.md, DARB-STORES.md, DARB-PROTOCOL.md and DARB-DEVICES.md.

## 0. Limits used
| Field | Limit | Source |
|---|---|---|
| Apple app name | 2-30 characters | [app-information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information) |
| Apple subtitle | 30 characters | same page |
| Apple promotional text | 170 characters | [platform-version-information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information) |
| Apple description | 4,000 characters, plain text | same page |
| Apple keywords | **100 bytes** (an Arabic letter is 2 bytes in UTF-8, so about 50 Arabic letters); each keyword longer than 2 characters. Whether commas count: UNVERIFIED (counted below as 1 byte each, to be safe). | same page |
| Apple App Review notes | 4,000 bytes; "Sign-in required" username and password fields; the demo account "must not expire" | same page |
| Apple in-app purchase | product ID up to 100 characters (letters, numbers, `-`, `.`, `_`), not editable or reusable; display name 2-30 characters; description up to 45 characters; review notes up to 4,000 characters | [in-app-purchase-information](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information) |
| Apple subscription group and subscription display names | no control characters, markup, emoji or **diacritics** (so no Arabic tashkeel). Length limits for subscriptions: UNVERIFIED (the 30/45 in-app purchase limits are used below). | [auto-renewable-subscription-information](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/auto-renewable-subscription-information) |
| Play app name, short description, full description | 30 / 80 / 4,000 characters | [9859152](https://support.google.com/googleplay/android-developer/answer/9859152) |
| Play subscription | product ID up to 40 characters, starts with a lowercase letter or number, then lowercase letters, numbers, `_` or `.`, and can never be reused; base plan ID uses lowercase letters, numbers and `-` only; name up to 55 characters; up to 4 benefits of 40 characters each | [140504](https://support.google.com/googleplay/android-developer/answer/140504) |

Character counts in this file were measured with a script (`len()` for characters, UTF-8 for Apple keywords).

## 1. Short texts
Arabic is the primary language on both stores; English is the second localization.

| Field | Arabic | chars | English | chars |
|---|---|---|---|---|
| App name, both stores (≤30) | درب: تدريب قدرات وتحصيلي | 24 | Darb: Qudurat & Tahsili Prep | 28 |
| Apple subtitle (≤30) | مذاكرة يومية ذكية بلا إعلانات | 29 | Smart daily practice, no ads | 28 |
| Play short description (≤80) | تدريب يومي للقدرات والتحصيلي ومواد المدرسة بمساعدة الذكاء الاصطناعي، بلا إعلانات | 80 | Daily practice for Qudurat, Tahsili and school subjects. AI-assisted. No ads. | 77 |
| Apple promotional text (≤170) | ذاكر للقدرات والتحصيلي ومواد المدرسة بخطة تتكيّف معك، مع شروح بمساعدة الذكاء الاصطناعي ومذاكرة دون إنترنت وبلا إعلانات. | 119 | Study for Qudurat, Tahsili and school subjects with a plan that adapts to you. AI-assisted explanations, offline study and no ads. | 130 |
| Apple keywords (≤100 bytes) | `اختبار,مذاكرة,اسئلة,رياضيات,فيزياء,كيمياء,احياء,علوم` | 97 bytes | `exam,study,flashcards,quiz,math,physics,chemistry,biology,english,review,practice,test,school,grade` | 99 bytes |

Notes:
- Keywords leave out the words already in the name and subtitle (Apple indexes those), and leave out "Qiyas", "STEP" and
  competitor names (trademarks, guideline 2.3.7). Which localizations the Saudi storefront indexes is UNVERIFIED, so both
  sets are filled.
- Don't use "official", "#1", "guaranteed", "free" in the name or graphics, or "For Kids" anywhere (2.3.8). "قدرات" and
  "تحصيلي" name the exams the material prepares for, and the description states that Darb is not affiliated with Qiyas.

## 2. Full description (Play ≤4,000; the same text goes in the Apple description)

### Arabic (1,839 characters; 3,204 bytes)
```
درب تطبيق مذاكرة للطلاب في المملكة: القدرات (اللفظي والكمي)، والتحصيلي، ومواد المرحلتين المتوسطة والثانوية. عشر دقائق مركّزة كل يوم، ودرب يختار لك ما تراجعه حتى تتذكره يوم الاختبار.

كيف يعمل
- أخبر درب بمرحلتك ومسارك وموعد اختبارك، فيبني لك خطة يومية ويضبط الصعوبة وطول الجلسة كلما تقدّمت.
- تعود إليك الأسئلة التي أوشكت على نسيانها في الوقت المناسب (التكرار المتباعد).
- حدّد مدى ثقتك في إجابتك، فتعود إليك الأسئلة التي خمّنتها أسرع.
- ذاكر دون إنترنت، ويُحفظ تقدّمك في حسابك عند عودة الاتصال.

مساعدة بالذكاء الاصطناعي
- احصل على شرح لأي سؤال تدريبي، وعلى ملاحظات على إجاباتك المكتوبة.
- يعيد درب شرح البطاقات التي تتكرر أخطاؤك فيها.
- تحمل إجابات الذكاء الاصطناعي علامة "ذكاء اصطناعي" وقد تخطئ. وفي كل سؤال وكل إجابة زر للإبلاغ، ونخبرك عند تصحيح الخطأ الذي أبلغت عنه.

مجانًا
- ذاكر مع أسئلة نموذجية من كل حزمة
- قدر يومي محدود من مساعدة الذكاء الاصطناعي
- بلا إعلانات، أبدًا

درب بلس
- بنوك الأسئلة كاملة للقدرات والتحصيلي ومواد المدرسة
- مساعدة أكبر من الذكاء الاصطناعي كل يوم وكل شهر
- ارفع ملفات PDF والصور وحوّلها إلى بطاقات وتمارين

الاشتراك: أسبوعي 19 ريالًا، شهري 29 ريالًا، سنوي 199 ريالًا. يُخصم المبلغ من حسابك في App Store أو Google Play، ويتجدد الاشتراك تلقائيًا ما لم تلغِه قبل نهاية الفترة بـ24 ساعة على الأقل. يمكنك إدارة الاشتراك أو إلغاؤه من إعدادات حسابك في المتجر.

بصراحة عن المحتوى
أسئلة درب مادة تدريبية أصلية كُتبت بمساعدة الذكاء الاصطناعي وروجعت قبل نشرها، وليست أسئلة اختبارات رسمية. ودرب غير تابع لهيئة تقويم التعليم والتدريب (قياس) ولا لوزارة التعليم. ولا نعدك بأي درجة.

الخصوصية
سجّل الدخول بحساب Google أو Apple. يحتاج الطالب دون 18 سنة إلى موافقة أحد والديه أو وليّه عبر البريد الإلكتروني. لا إعلانات، ولا تتبّع، ولا بيع للبيانات. ولا تصل ميزات الذكاء الاصطناعي إلى اسمك أو بريدك أبدًا.

شروط الاستخدام: https://darbedu.sa/ar/terms
سياسة الخصوصية: https://darbedu.sa/ar/privacy
الدعم: support@darbedu.sa
```

### English (2,081 characters)
```
Darb is a study app for students in Saudi Arabia: Qudurat (verbal and quantitative), Tahsili, and middle- and high-school subjects. Ten focused minutes a day, and Darb picks what to review so you remember it on exam day.

HOW IT WORKS
- Tell Darb your stage, your track and your exam date. It builds a daily plan and adjusts difficulty and session length as you go.
- Questions you are about to forget come back at the right time (spaced repetition).
- Say how sure you are, and Darb brings back your guesses sooner.
- Study offline. Your progress is saved to your account when you are back online.

AI-ASSISTED HELP
- Get an explanation of any practice question, and feedback on your written answers.
- Darb re-teaches the cards you keep missing.
- AI answers are labelled "AI" and can be wrong. Every question and every answer has a report button, and we tell you when a mistake you reported is fixed.

FREE
- Study with sample questions from every pack
- A small daily allowance of AI help
- No ads, ever

DARB PLUS
- Full question banks for Qudurat, Tahsili and school subjects
- More AI help every day and every month
- Upload your PDFs and photos and turn them into cards and practice

Subscription: weekly SAR 19, monthly SAR 29, annual SAR 199. Payment is charged to your App Store or Google Play account. The subscription renews automatically unless you cancel it at least 24 hours before the end of the period. Manage or cancel it in your store account settings.

HONEST ABOUT THE CONTENT
Darb's questions are original practice material written with the help of AI and checked before release. They are not official exam questions. Darb is not affiliated with the Education and Training Evaluation Commission (Qiyas) or the Ministry of Education. We do not promise any score.

PRIVACY
Sign in with Google or Apple. Students under 18 need a parent's or guardian's consent by email. No ads, no tracking, no data sale. AI features never receive your name or email.

Terms of use: https://darbedu.sa/terms
Privacy policy: https://darbedu.sa/privacy
Support: support@darbedu.sa
```

## 3. URLs and contact
| Field | Value |
|---|---|
| Privacy policy (both stores, required) | https://darbedu.sa/privacy (Arabic: https://darbedu.sa/ar/privacy) |
| Terms of use / EULA (Apple: in the description and the License Agreement field, or use Apple's Standard EULA; see `terms.en.md` section 11) | https://darbedu.sa/terms |
| Support URL (Apple, required) | https://darbedu.sa/support |
| Account deletion URL (Play Data safety) | https://darbedu.sa/delete-account |
| AI and minors statement | https://darbedu.sa/ai-and-minors |
| Marketing URL (optional) | https://darbedu.sa |
| Play contact | support@darbedu.sa, [PUBLIC PHONE] (required for organization accounts), https://darbedu.sa |
| Apple review contact | [NAME], [PHONE], support@darbedu.sa |

The URLs follow one pattern: English at the bare path, Arabic under `/ar/`. [OWNER: publish all pages before submitting;
the guardian consent page already links to `/privacy`]

## 4. Category
- **Apple:** primary **Education**, no secondary. Kids Category: **Not Applicable** (DARB-STORES.md).
- **Play:** app, category **Education**. Contains ads: **No**.

## 5. Age rating

### Apple (target **9+**)
Apple's tiers are 4+, 9+, 13+, 16+ and 18+, with no 12+. The aim is to rate Darb no higher than 9+ so that 12-year-olds
see it (DARB-STORES.md). Definitions are from [age-ratings-values-and-definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/),
read on 2026-10-16 (only part of the page could be read, so the questionnaire wording itself is UNVERIFIED).

| Questionnaire item | Answer | Why |
|---|---|---|
| Parental Controls | No | Guardians consent, can withdraw consent and delete the account, and can get a weekly summary. They cannot restrict content, so this is not a parental control. |
| Age Assurance | Yes | Birth-year gate at sign-up: under 12 is refused, under 18 needs a guardian. It is self-declared. Whether self-declaration counts as age assurance: UNVERIFIED. Either answer stays in the 4+ tier. |
| Unrestricted Web Access | No | Links open only Darb's own pages and the store's subscription page |
| User-Generated Content | No | Uploads and cards are private to their owner; nothing is shown to other users |
| Messaging and Chat | No | No user-to-user messaging. AI help is tied to the question on screen. |
| Advertising | No | |
| Health or Wellness Topics | **Yes** | School biology and health-education lessons. This is the item that makes the rating **9+**. |
| Medical or Treatment Information | None | School-level science, not medical advice. [OWNER: if a certification pack covers medicine, nursing or pharmacy, the answer becomes Infrequent, which rates 13+] |
| Alcohol, Tobacco or Drug Use or References | None | [OWNER: scan the packs. If health lessons mention smoking or drugs, decide with the lawyer whether factual school content counts. "Infrequent" rates 13+.] |
| Violence (cartoon, fantasy or realistic), guns and weapons | None | History content is text only, with no depictions |
| Horror or fear, profanity or crude humor, mature or suggestive themes, sexuality or nudity | None | |
| Gambling, simulated gambling, contests, loot boxes | None | |

Expected result: **9+**.

### Google Play: IARC questionnaire (Play Console → App content → Content rating)
The questions appear only inside Play Console, and [9898843](https://support.google.com/googleplay/android-developer/answer/9898843)
does not list them, so the category name and wording are UNVERIFIED.

| Topic | Answer |
|---|---|
| Category | Reference, news or educational |
| Violence, blood, fear | No |
| Sexuality, nudity | No |
| Language (profanity, crude humor) | No |
| Controlled substances (alcohol, tobacco, drugs) | No (see the Apple note above about health lessons) |
| Gambling or simulated gambling | No |
| Users can interact or exchange content with other users | No |
| Shares the user's location with other users | No |
| Digital purchases | Yes (auto-renewing subscriptions) |
| Unrestricted internet access | No |

Expected: IARC 3+ / Everyone. Saudi Arabia gets the IARC generic rating (DARB-STORES.md).

## 6. Google Play target audience and Families
- **Target age groups:** **9-12, 13-15, 16-17 and 18+**. Not "5 and under" or "6-8". 12-year-olds fall in 9-12, and
  Play treats 9-12 as children, so the **Families policy applies** ([9867159](https://support.google.com/googleplay/android-developer/answer/9867159),
  [9893335](https://support.google.com/googleplay/android-developer/answer/9893335)).
- **Mixed audience:** Darb serves students from 12 to university and certification. The birth-year screen is neutral (it
  doesn't suggest an answer). Under-12s are refused, and under-18s go through the guardian step.
- **Families declarations:**
  - Ads: none, and no ad SDKs.
  - Advertising ID: not used. The manifest removes `com.google.android.gms.permission.AD_ID`; answer "No" in the
    Advertising ID declaration.
  - No location, contacts, or hardware identifiers (IMEI, MAC, SSID and similar).
  - SDKs: RevenueCat (purchases), Google Sign-In, Sentry (crashes, PII off), Play Integrity, local notifications.
    [OWNER: check each one against the Families SDK requirements on 9893335 before submitting]
  - The privacy policy discloses children's data (section 7) and has a privacy policy link.
  - AI-generated content: in-app reporting on every AI answer ([13985936](https://support.google.com/googleplay/android-developer/answer/13985936)).
    Any extra Families rules for generative AI: UNVERIFIED.
- **Teacher Approved:** optional, and Google doesn't guarantee inclusion. Leave it for after launch.
- **Other App content answers:** News app No · Government app No · Financial features None · Health app No · App access:
  credentials as in section 10.

## 7. Google Play Data safety
Definitions are from [10787469](https://support.google.com/googleplay/android-developer/answer/10787469):
- "collect" means sending data off the device;
- "share" means transferring it to a third party;
- a service provider processes data on the developer's behalf.

Anthropic, RevenueCat, Contabo, Cloudflare, Sentry and the email provider all act as Darb's service providers, so
**nothing is declared as shared**. The page did not state in so many words that transfers to service providers are
exempt, so that point is UNVERIFIED; the wording read was the definition only.

| Play data type | Collected | Shared | Purposes | Required or optional | Darb data |
|---|---|---|---|---|---|
| Personal info → Name | Yes | No | App functionality, Account management | Required | From Google or Apple sign-in |
| Personal info → Email address | Yes | No | App functionality, Account management | Required | Sign-in email; the guardian's email for under-18s |
| Personal info → User IDs | Yes | No | App functionality, Account management, Fraud prevention, security and compliance | Required | Google or Apple account ID, Darb account ID (sent to RevenueCat) |
| Personal info → Other info | Yes | No | App functionality, Account management, Fraud prevention, security and compliance | Required | Birth year (age gate, guardian consent) |
| Financial info → Purchase history | Yes | No | App functionality, Account management | Optional | Subscription status from RevenueCat. Payment details stay with Google Play. |
| Photos and videos → Photos | Yes | No | App functionality | Optional | Uploads (subscribers), processed by Anthropic |
| Files and docs | Yes | No | App functionality | Optional | PDF uploads |
| App activity → App interactions | Yes | No | App functionality, Personalization | Required | Sessions, review history, settings, onboarding answers |
| App activity → Other user-generated content | Yes | No | App functionality | Optional | The student's cards, answers sent for AI grading, questions to the AI, mistake reports |
| App info and performance → Crash logs | Yes | No | App functionality, Analytics | Required | Sentry, without name, email or ID |
| App info and performance → Diagnostics | Yes | No | App functionality, Analytics | Required | Device model, OS and app version in crash reports |
| Device or other IDs | Yes | No | Account management, Fraud prevention, security and compliance | Required | Per-install sign-in token, Play Integrity verdict (declared to be safe) |
| Location, Messages, Audio, Calendar, Contacts, Health and fitness, Web browsing, Installed apps, In-app search history, Payment info | No | No | | | |

- **Encrypted in transit:** Yes (TLS everywhere).
- **Users can request deletion:** Yes. In the app (Settings → Account → Delete my account) and at
  https://darbedu.sa/delete-account.
- **Families policy commitment:** Yes.
- **Independent security review:** No.
- **IP address:** server logs keep it for 14 days for security only, and it is not used to work out location. Whether Play
  expects a disclosure for that: UNVERIFIED. Check the Data safety help before submitting.

## 8. Apple App Privacy ("nutrition label")
Definitions are from [app-privacy-details](https://developer.apple.com/app-store/app-privacy-details/):
- **Tracking: No.** Darb links nothing with third-party data for advertising and sells nothing to data brokers, so no ATT
  prompt is needed.
- **Payment info: not collected.** Payment is entered outside the app.
- "Linked" means tied to the account. Crash data is collected without any identifier, so it is **not linked**.

| Apple data type | Collected | Linked to user | Used for tracking | Purposes |
|---|---|---|---|---|
| Contact Info → Name | Yes | Yes | No | App Functionality |
| Contact Info → Email Address | Yes | Yes | No | App Functionality (sign-in email and the guardian's email) |
| User Content → Photos or Videos | Yes | Yes | No | App Functionality (uploads) |
| User Content → Other User Content | Yes | Yes | No | App Functionality (cards, answers sent for AI grading, PDFs, mistake reports) |
| Identifiers → User ID | Yes | Yes | No | App Functionality |
| Identifiers → Device ID | Yes | Yes | No | App Functionality (per-install sign-in token, App Attest; declared to be safe) |
| Purchases → Purchase History | Yes | Yes | No | App Functionality |
| Usage Data → Product Interaction | Yes | Yes | No | App Functionality, Product Personalization (adaptive study plan) |
| Diagnostics → Crash Data | Yes | No | No | App Functionality |
| Diagnostics → Other Diagnostic Data | Yes | No | No | App Functionality (device model, OS version) |
| Other Data → Other Data Types | Yes | Yes | No | App Functionality (birth year, guardian consent record) |

**Not collected:** Health and Fitness, Financial Info, Location, Sensitive Info, Contacts, Emails or Text Messages, Audio,
Gameplay Content, Customer Support (support is by email outside the app), Browsing History, Search History, Advertising
Data, Surroundings, Body.

[OWNER: compare this with the privacy manifests of RevenueCat, Sentry and Google Sign-In in the built archive. Don't call
RevenueCat's `collectDeviceIdentifiers`.]

## 9. Subscription products

### Apple
Group reference name **Darb Plus**; group display name AR **درب بلس**, EN **Darb Plus**.

| Product ID | Duration | Price | Display name AR / EN | Description AR / EN (≤45) |
|---|---|---|---|---|
| `darb_weekly` | 1 week | SAR 19.00 | درب بلس أسبوعي / Darb Plus Weekly | بنوك الأسئلة كاملة، مساعدة أكبر، ورفع الملفات (45) / Full question banks, more AI help, uploads (42) |
| `darb_monthly` | 1 month | SAR 29.00 | درب بلس شهري / Darb Plus Monthly | same |
| `darb_annual` | 1 year | SAR 199.00 | درب بلس سنوي / Darb Plus Annual | same |

- **Levels:** all three give the same service, so put them on one level, with annual highlighted in the paywall. How
  App Store Connect treats equal levels: UNVERIFIED.
- **Price points:** whether SAR 19.00 / 29.00 / 199.00 exist as exact Apple price points is UNVERIFIED (DARB-STORES.md).
  Pick them in App Store Connect.
- **Introductory offer:** a free trial of [TRIAL LENGTH] on `darb_annual` only. Apple allows 3 days to 1 year, and one
  intro offer per group per customer.
- **Family Sharing:** off. [OWNER: entitlements are bound to the Darb account]
- **Review screenshot:** a screenshot of the in-app paywall at any accepted iPhone size (e.g. 1206x2622). It must show
  the three plans with price and period, the auto-renew text, the Terms and Privacy links, and "Restore purchases".
- **Review notes (each product):** "Unlocks the full question banks, higher AI limits and PDF/photo uploads.
  Entitlement is verified on our server through RevenueCat. Use a sandbox Apple ID; the reviewer account is described in
  the app's review notes."
- The first subscription group and subscription must be submitted with a new app version
  ([offer-auto-renewable-subscriptions](https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions)).

### Google Play
Three subscriptions, each with one auto-renewing base plan:

| Product ID | Base plan ID | Period | Price | Name AR / EN (≤55) |
|---|---|---|---|---|
| `darb_weekly` | `p1w` | weekly | SAR 19.00 | درب بلس أسبوعي / Darb Plus Weekly |
| `darb_monthly` | `p1m` | monthly | SAR 29.00 | درب بلس شهري / Darb Plus Monthly |
| `darb_annual` | `p1y` | yearly | SAR 199.00 | درب بلس سنوي / Darb Plus Annual |

**Benefits (≤40 each):**

| Arabic | chars | English | chars |
|---|---|---|---|
| بنوك الأسئلة كاملة | 18 | Full question banks | 19 |
| مساعدة أكبر من الذكاء الاصطناعي | 31 | More AI help every day and month | 32 |
| حوّل ملفاتك وصورك إلى بطاقات | 28 | Turn your PDFs and photos into cards | 36 |

- **Free trial offer:** on `darb_annual` / `p1y` only, for [TRIAL LENGTH], for new customers. Google allows 3 days to 3
  years.
- In RevenueCat, attach all six store products to one entitlement and one offering. The product IDs can never be
  reused, so create them only once the names are final.

## 10. App Review notes
Apple allows 4,000 bytes; this template is 2,295 bytes. For Play, paste the same text into App content → App access,
"All or some functionality is restricted".

```
Darb (درب) is a study app for students in Saudi Arabia aged 12+. It opens in Arabic. To switch to English: Settings (الإعدادات) → Language.

SIGN-IN
Darb offers only Sign in with Apple and Sign in with Google (no passwords). You can use your own Apple ID with Sign in with Apple, or this adult demo Google account:
  Email: [DEMO_GOOGLE_EMAIL]
  Password: [DEMO_GOOGLE_PASSWORD]
A new account is asked for a birth year. Choose any year that makes you 18 or older (e.g. 1990) and you go straight in. The demo Google account already has an adult birth year.

MINORS (GUARDIAN STEP)
If the birth year makes the user under 18, the app asks for a parent's or guardian's email and sends them a consent link. Until the guardian confirms, only the on-device free sample works: no sync, no AI, no purchases. Under 12 is refused. To see this flow, sign in with a new Apple ID, choose birth year 2012, and enter an email address you can open.

SUBSCRIPTIONS (sandbox)
Group "Darb Plus": darb_weekly (SAR 19/week), darb_monthly (SAR 29/month), darb_annual (SAR 199/year), auto-renewing. Tap "اشترك" (Upgrade) in Settings → Subscription, choose a plan and pay with your sandbox account. Settings → Subscription also has "Manage or cancel" and "Restore purchases". Our server checks entitlements through RevenueCat. The demo account has no active subscription.

ACCOUNT DELETION
Settings → Account → Delete my account (الإعدادات ← الحساب ← حذف حسابي). It deletes the account and its data at once and revokes Sign in with Apple. Subscribers are told that the App Store keeps billing until they cancel. Web page: https://darbedu.sa/delete-account

AI
Explanations, grading of practice answers and cards from uploads use Anthropic's Claude. Before the first use, a dialog names Anthropic and says what is sent (the question and the answer, or the uploaded pages; never the name or email). Every AI answer is labelled AI and has "Report this answer". Students cannot chat freely with the AI. AI grading is practice only.

CONTENT
Original practice questions written with the help of AI and checked. Darb is not affiliated with the Education and Training Evaluation Commission (Qiyas) or the Ministry of Education.

Contact: [NAME], [PHONE], support@darbedu.sa
```

[OWNER: create the demo Google account with an adult birth year and 2-step verification off, sign in once on a fresh
device to clear any "verify it's you" prompt, and keep it from expiring. Put the same credentials in the App Store
Connect "Sign-in required" fields and in Play App access.]

## 11. Screenshots

### Sizes (read on 2026-10-16)
**Apple** ([screenshot-specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)):
1 to 10 screenshots per size, `.jpeg`, `.jpg` or `.png`, no alpha or transparency. App Store Connect scales the largest
set down to smaller displays.

| Display | Portrait pixels | Status |
|---|---|---|
| iPhone 6.9" ("Dynamic Island, large display") | **1320x2868**, 1290x2796, 1260x2736 | Upload. It's the largest, and it satisfies the 6.5" rule. |
| iPhone 6.3" ("Dynamic Island, medium display") | **1206x2622**, 1179x2556 | **Required** ("Required device sizes" section). Resize the 6.9" set; the aspect ratio is the same. |
| iPhone 6.5" ("Face ID, large display") | 1284x2778, 1242x2688 | Required only if no 6.9" set is provided, so the set above covers it |
| iPad 13" | **2064x2752**, 2048x2732 | **Required if the app runs on iPad.** The Xcode project has `TARGETED_DEVICE_FAMILY = "1,2"`, so it does today. [OWNER: shoot iPad screens, or set it to iPhone only] |

The page's own text is inconsistent (the 6.5" section talks as if 6.9" is the main size, while the "Required device
sizes" section names the medium display), so upload both 6.9" and 6.3". The inch labels come from the icons, not from
the page text.

**Google Play** ([9866151](https://support.google.com/googleplay/android-developer/answer/9866151)):

| Asset | Spec |
|---|---|
| Phone screenshots | JPEG or 24-bit PNG (no alpha). Each side between 320 and 3,840 px, and the long side at most twice the short side. 2 to 8 per device type. For screenshot-based recommendation formats: **at least 4 at 1080 px or more, 9:16**. Use **1080x1920**. |
| Feature graphic | **1024x500**, JPEG or 24-bit PNG (no alpha), required |
| App icon | 512x512, 32-bit PNG, ≤1,024 KB |
| Tablet screenshots | optional |

Rules for every shot:
- real app UI with sample data;
- the Arabic set shows the Arabic UI, and the English set the English UI;
- light theme, with dark for shot 6;
- a neutral demo name, no real student data;
- no Qiyas, ETEC or Ministry logos, no "official", no scores or results promised;
- AI shots must show the "AI" label;
- paid features are captioned "Darb Plus";
- the feature graphic carries the logo and tagline only, with no prices, rankings or "free".

### Shot list (6 screens, the same order on both stores)
| # | Screen | Caption AR | Caption EN |
|---|---|---|---|
| 1 | Home: today's plan and the countdown to the exam date | خطة يومية حتى موعد اختبارك | A daily plan up to your exam date |
| 2 | A Qudurat quantitative question with the "How sure are you?" buttons | أسئلة تدريبية أصلية للقدرات والتحصيلي | Original practice for Qudurat and Tahsili |
| 3 | An AI explanation with the "AI" label and "Report this answer" | شرح فوري بمساعدة الذكاء الاصطناعي | Instant AI-assisted explanations |
| 4 | Feedback on a written practice answer | ملاحظات على إجاباتك المكتوبة | Feedback on your written answers |
| 5 | Uploads: a PDF turned into cards (Darb Plus) | حوّل ملفاتك وصورك إلى بطاقات | Turn your PDFs and photos into cards |
| 6 | Session summary while offline (dark theme) | ذاكر دون إنترنت وبلا إعلانات | Study offline, with no ads |

Feature graphic (1024x500): the Darb logo with "درب: مذاكرة يومية ذكية" on the Arabic listing and "Darb: smart daily
practice" on the English one.
