# Darb: similar apps in the Saudi market (checked 2026-10-15)

Pulled from the Saudi Google Play and App Store pages and the newest Saudi App Store reviews. "P" = Google Play,
"A" = App Store. Prices are SAR, from the store purchase lists.

| App | Target | Key features | Price (SAR) | Rating |
|---|---|---|---|---|
| Noon Academy ([P](https://play.google.com/store/apps/details?id=com.noonEdu.k12App), [A](https://apps.apple.com/sa/app/id1214874641)) | school, قدرات/تحصيلي | live classes, recorded courses; bought Almakhfi (Jul 2026) | courses 118-1,200 | P 10M+ 4.3 / A 4.54 |
| Abwaab ([P](https://play.google.com/store/apps/details?id=me.abwaab.abwaabv2_app), [A](https://apps.apple.com/sa/app/id1623367993), [Qiyas](https://apps.apple.com/sa/app/id6800621119)) | grades 6-12, قدرات/تحصيلي | videos, live, question bank, WhatsApp mentor with weekly reports, league; free diagnostic test | 95-700 per course | P 10M+ 4.2 / A 4.17 |
| Bites ([P](https://play.google.com/store/apps/details?id=com.shaguf.shaguf_bites), [A](https://apps.apple.com/sa/app/id6475324072)) | school, university | upload → flashcards/quizzes/summaries, SRS, AI tutor | weekly 24.99, monthly 39.99, 3 months 99, annual 229.99 | A 4.65 (21.8K); #5 top-grossing Education SA |
| مجتهد ([P](https://play.google.com/store/apps/details?id=com.mazen.flutterquiz), [A](https://apps.apple.com/sa/app/id6605936809)) | قدرات, تحصيلي, STEP | تجميعات, mocks, time analytics, mistakes notebook, challenges, offline, weighted-score calculator; ads on free | weekly 34.99, monthly 49.99, 3 months 99.99, annual 159 | A 4.68; #25 grossing |
| تفوق ([P](https://play.google.com/store/apps/details?id=sa.tafawaqsa.app), [A](https://apps.apple.com/sa/app/id6720723334)) | قدرات, تحصيلي, STEP | personal plan, mocks, AI assistant, **SRS**, AI explainer videos | premium unverified; free: ads, 15 hints, 1 mock | A 4.63 |
| دال ([P](https://play.google.com/store/apps/details?id=com.dalqudrat.app), [A](https://apps.apple.com/sa/app/id6760922378)) | قدرات | daily plan from the exam date, AI assistant, explanation per question, mock simulator, live rooms, weekly league, mistake review, streaks | weekly 39-49.99, monthly 59-79.99, 3 months 99-149.99, annual 249.99 | A 4.48; #59 grossing |
| عتاد ([A](https://apps.apple.com/sa/app/id6758402765)) | قدرات + تحصيلي | plan that re-plans after a missed day; hint + second try before the answer | monthly 29.99, 3 months 69.99, 6 months 79.99, annual 129.99 | A 4.64 |
| قياس القدرات ([P](https://play.google.com/store/apps/details?id=com.alho00ot.qyas), [A](https://apps.apple.com/sa/app/id953441582)) | قدرات | question bank, daily test, challenges, ads | coins 4.99-19.99 | A 4.28 |
| ضوء الخريج ([P](https://play.google.com/store/apps/details?id=sarah.com.graduateguide)) | admissions | weighted-percentage calculator, majors guide | 29.99-99.99 | P 100K+ 4.6 |
| مدرستي, MOE ([P](https://play.google.com/store/apps/details?id=com.t4edu.madrasatiApp)) | school | free official platform, 100K+ question bank | free | P 5M+ 3.7 |

## Prices
- Subscription apps: weekly 24.99-49.99, monthly 29.99-79.99, 3 months 69.99-149.99, annual 129.99-249.99.
- Darb's weekly 19 is the cheapest on the market, and monthly 29 ties the cheapest.
- Annual 199 is mid-to-high. It equals **6.9x** the monthly price; competitors' annual plans equal 3.1-5.8x their monthly.
- Most students prepare for قدرات in 1-3 months, and **every** subscription competitor sells a **3-month plan**. Raised with you as a question.

## What students complain about (Darb's opening)
1. Ads that interrupt sessions (مجتهد). Darb has none.
2. Features moved behind the paywall after purchase, and free tiers too small to be useful.
3. Billing distrust: charges without consent, no way to cancel, refunds refused (تفوق, Bites).
4. Crashes, login failures, false "no internet" errors (قرناس, دال, Noon).
5. **Wrong answer keys with no way to report them** (مجتهد, ١٠ في ١٠, دال, تفوق).
6. Big platforms: price, aggressive sales calls, courses that expire mid-preparation.

SRS and "AI explanations" are no longer unique. Darb's real edges:
- AI grading of written answers;
- AI re-teach of the cards a student keeps missing;
- one subscription for قدرات + تحصيلي + every MOE subject;
- price;
- offline reliability;
- a measured error rate per pack.

## Decisions: what Darb adds (and when)
| # | Feature | Why | Cost | Phase |
|---|---|---|---|---|
| 1 | **Exam-date plan on the home screen**: "on track: you finish by X", re-plans after a missed day, one rest day a week that doesn't break the streak | دال, تفوق and عتاد sell it; makes the autopilot visible | small | 5 |
| 2 | **Free placement test** (15-20 questions) at the end of onboarding for قدرات/تحصيلي → a predicted score range; plus the **weighted-percentage (النسبة الموزونة) calculator** | free hook (Abwaab Qiyas, مجتهد, ضوء الخريج) | small + medium | 5 (test uses the phase 3 packs) |
| 3 | **"Report a mistake" on every question** (already in the spec) **plus a "fixed, thanks" notice** back to the reporter | the most common complaint; feeds the error-rate report | small | 3/5 |
| 4 | **Trust-first billing**: renewal reminder 3 days before an annual renewal, in-app "manage / cancel", no ads ever, nothing free is ever moved behind the paywall | billing complaints | small | 1/5 |
| 5 | **My mistakes** (redo wrong only) and **timed drills / mock timing** (seconds per question vs the real exam pace) | قدرات is a speed test (مجتهد, دال, Abwaab) | small | 5 |
| 6 | **Hint, then a second try** before the answer is shown (hints precomputed in packs, so no AI cost) | better learning (عتاد); cheaper than AI explanations | small | 3/5 |
| 7 | **Weekly summary email to the guardian** (opt-in on the consent page; minutes studied, sessions, predicted range) | parents pay; Abwaab's mentor reports | small (email exists for consent) | 5 |

**Not copied:**
- **Live classes, tutors, WhatsApp mentors, live rooms:** high fixed cost, worst reviews, and moderation risk with minors.
- **Ads and coins.**
- **AI video generation.**
- **"تجميعات" / "real exam questions":** these are recollected copyrighted Qiyas items. The spec forbids copying them, and قياس القدرات users already question its legitimacy. Darb states it is not affiliated with Qiyas / ETEC.
- **Friend challenges and a weekly league** go on the post-v1 list. They need names on leaderboards, which means extra PDPL work for minors.

A STEP pack (English, ETEC) is common in competitors. It is on the question list for the certification segment.
