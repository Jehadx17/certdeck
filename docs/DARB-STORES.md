# Darb: store rules (checked 2026-10-15)

Every fact below was read on the official page linked next to it on 2026-10-15 ("no date" = the page shows none).
"Unverified" = not confirmable on an official page; it is listed in the release checklist for a manual check.

## Accounts
| | Google Play Console | Apple Developer Program |
|---|---|---|
| Fee | US$25 once ([6112435](https://support.google.com/googleplay/android-developer/answer/6112435)) | US$99 / year ([enroll](https://developer.apple.com/programs/enroll/)) |
| Organization needs | D-U-N-S (free), ID, official organization document, verified website, public developer phone ([13634885](https://support.google.com/googleplay/android-developer/answer/13634885), [10841920](https://support.google.com/googleplay/android-developer/answer/10841920)) | D-U-N-S ([enroll](https://developer.apple.com/programs/enroll/)) |
| Time | Not published (unverified). D-U-N-S "can take up to 30 days" ([blog, 2023-07-12](https://android-developers.googleblog.com/2023/07/boosting-trust-and-transparency-in-google-play.html)) | D-U-N-S up to 5 business days + 2 for Apple to receive it ([D-U-N-S](https://developer.apple.com/help/account/membership/D-U-N-S/)); enrollment itself unverified |
| Testing before production | **Personal accounts created after 2023-11-13: 12 testers opted in for 14 continuous days.** The page names personal accounts only, so an **organization account avoids it** ([14151465](https://support.google.com/googleplay/android-developer/answer/14151465)) | none |
| Commission on subscriptions | 15% for auto-renewing subscriptions (Saudi Arabia = "all other markets") ([112622](https://support.google.com/googleplay/android-developer/answer/112622)) | 15% with the Small Business Program (new developers or < US$1M; must enroll) ([SBP](https://developer.apple.com/app-store/small-business-program/)) |
| Fee waiver | n/a | Nonprofits, accredited schools, government only; not with paid apps ([fee waiver](https://developer.apple.com/support/fee-waiver/)) |

Recommendation: enroll both stores as an **organization** (the company registration is already on your list): it skips
Google's 12-tester/14-day closed test and puts the company, not you, on the store page.

## Build requirements
- Google Play: new apps and updates must target **Android 16 (API 36)** since 2026-08-31 (extension possible to 2026-11-01)
  ([target-sdk, updated 2026-10-01](https://developer.android.com/google/play/requirements/target-sdk)).
- Apple: uploads must be built with **Xcode 26 or later and the iOS 26 SDK** since 2026-04-28; apps must target iOS 13 or
  later since 2026-09-09 ([upcoming requirements](https://developer.apple.com/news/upcoming-requirements/)).
- Xcode 26.0-26.3 runs on macOS Sequoia 15.6 or later; 26.4.1+ needs Tahoe 26.2 ([xcode support](https://developer.apple.com/support/xcode/)).
  The Hackintosh (MacBookAir9,1, tops out at Sequoia) can build Darb with **Xcode 26.3 on Sequoia 15.6+**. A future
  "Xcode 27 required" rule would need Tahoe, which that machine cannot run: plan a CI macOS runner for that day.

## Sign-in and account deletion
- Apple 4.8: with Google sign-in, an equivalent login (name + email only, private email allowed) must be offered:
  Sign in with Apple ([guidelines, 2026-06-08](https://developer.apple.com/app-store/review/guidelines/)).
- Apple 5.1.1(v): account deletion inside the app (not just deactivation, not an email flow); tell subscribers billing
  continues through Apple; revoke Sign in with Apple tokens ([account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/)).
- Google Play: in-app deletion **and** a web link to request deletion without the app; the link goes in the Data
  safety form ([13327111](https://support.google.com/googleplay/android-developer/answer/13327111)).

## Minors (Darb is for ages 12+)
- Google Play target age groups: 5-, 6-8, 9-12, 13-15, 16-17, 18+ ([9867159](https://support.google.com/googleplay/android-developer/answer/9867159)).
  Including 12-year-olds means choosing **9-12**, so the **Families policy** applies: no ads (Darb has none), only
  child-safe SDKs or SDKs behind an age screen, disclose children's data ([9893335](https://support.google.com/googleplay/android-developer/answer/9893335)).
  Darb's SDKs: RevenueCat, Google/Apple sign-in, Sentry (no tracking, PII off). Check each against the Families
  self-certification list before submitting (release checklist).
- Apple age ratings are 4+, 9+, 13+, 16+, 18+ (no 12+). With 12-year-olds as users, rate **9+** ([age ratings](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/)).
  Kids Category is optional: choose "Not Applicable" ([set age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/), [kids apps](https://developer.apple.com/app-store/kids-apps/)).
  5.1.4(b) still applies (privacy policy, children's privacy law); 2.3.8: no "For Kids" in metadata ("for students" is fine).
- Age-assurance APIs (Apple Declared Age Range, Google Play Age Signals) apply in Brazil, Australia, Singapore, Utah,
  Louisiana, Texas; **nothing for Saudi Arabia** ([Apple, 2026-02-24](https://developer.apple.com/news/?id=f5zj08ey), [Google, 2026-07-20](https://developer.android.com/google/play/age-signals/overview)).

## Prices (SAR 19 / 29 / 199)
- Google Play accepts uncharmed prices, so SAR 19.00 / 29.00 / 199.00 are allowed ([16526148](https://support.google.com/googleplay/android-developer/answer/16526148)).
  SAR min/max: unverified (the table needs JavaScript).
- Apple has 900 price points incl. rounded endings (X.00) ([newsroom, 2022-12-06](https://www.apple.com/newsroom/2022/12/apple-announces-biggest-upgrade-to-app-store-pricing-adding-700-new-price-points/)).
  Whether SAR 19.00 / 29.00 / 199.00 are exact points: **unverified, check in App Store Connect** (release checklist).
- Intro offers: Apple free trial 3 days-1 year, one intro offer per subscription group; subscriptions must last 7+ days
  (3.1.2(a)) ([intro offers](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-introductory-offers-for-auto-renewable-subscriptions/)).
  Google free trial 3 days-3 years ([12154973](https://support.google.com/googleplay/android-developer/answer/12154973)).
  Darb uses none (owner decision 2026-10-16): the free plan is the trial.

## Disclosures
- Google Data safety form: required on every track, even closed testing ([10787469](https://support.google.com/googleplay/android-developer/answer/10787469)).
- Apple App Privacy details: required for new apps and updates ([app privacy](https://developer.apple.com/app-store/app-privacy-details/)).
- IARC content rating on Play: required ([9898843](https://support.google.com/googleplay/android-developer/answer/9898843)); Saudi Arabia gets the IARC generic rating (inferred, [9859655](https://support.google.com/googleplay/android-developer/answer/9859655)).

## AI-generated content: recommendation
- Google: apps that generate content with AI need in-app reporting/flagging without leaving the app
  ([13985936](https://support.google.com/googleplay/android-developer/answer/13985936), scope in [14094294](https://support.google.com/googleplay/android-developer/answer/14094294)).
- Apple 5.1.2(i) (2025-11-13): clearly disclose sharing personal data with third-party AI and get explicit permission
  first ([news](https://developer.apple.com/news/?id=ey6d8onl)).
- **Recommended answer:** yes, disclose. In the app: a one-time consent screen before the first AI feature naming
  Anthropic and what is sent (the card, the student's answer or question, uploaded pages), plus "Report" on every AI
  answer (Darb already has "report a mistake" on every question). In the stores: declare it in Data safety / App
  Privacy, the privacy policy and the description ("explanations and practice are AI-assisted and reviewed").

## Review times
- Apple: 50% of submissions within 24 h, 90% within 48 h ([app review](https://developer.apple.com/distribute/app-review/)).
- Google: up to 7 days or longer for some new accounts ([9859751](https://support.google.com/googleplay/android-developer/answer/9859751)).
