# CertDeck for College: Make the Student App Child-Easy

Redesign the **student side** of CertDeck (see COLLEGE.md, SPEC.md, README.md, DECISIONS.md, docs/PROTOCOL.md) so it
is as easy as if a child had to use it alone: open the app, know what to do, study, and feel good about it, with no
help and no reading of instructions. **The users are still college students** (clarified 2026-10-14): the bar is
child-level ease, the tone stays adult. Design for someone who reads Arabic well and English a little, is tired or
in a hurry, taps whatever is biggest, and never opens Settings on purpose. Where this file says "the child", read
"the student, judged by that bar".

## Context
- The student app today (1.3.6) has two tabs, College and Settings. It works, but it was built for a capable
  adult. The device tests showed where a child would get stuck:
  - **Words a child doesn't know:** "Readiness", "Predicted mark 0–35%", "Compressed / Sprint mode", "Master now /
    Skim / Skip", "scope", "sections chosen", "hints", "knowledge points", "Batch", "sync", "token", and the cost
    estimates ("$1.32").
  - **Too many choices:** six session lengths (15–120 min), three confidence buttons before every answer, the
    Wrong / Partly / Right grading bar, a practice exam form with three number fields, and sheets in four kinds.
  - **Long paths:** a course → an assessment → scroll to Study → pick minutes → a triage page → Start.
  - **Setup an adult must do:** pasting a 43-character token, choosing what a quiz covers, uploading material.
  - **Error text** that's technical or English inside the Arabic screen.
- **Keep my side exactly as it is.** The owner (me) keeps every screen, word and feature unchanged. All changes
  apply only when the account role is `student`. The study engine, server, AI pipeline and sync stay as they are;
  this goal is about what the student sees and touches.
- Setup (uploading material, setting the exam date and scope, preparing) is done by the students themselves, as
  in COLLEGE.md; I create their accounts. The setup screens can stay as they are, but they must be clearly
  separate from the everyday study screens.

## Before you start: ask me everything in ONE batch
Then don't stop again unless something is destructive, affects my other VPS projects, or is blocked:
- Who does the setup in practice (me, a parent, or the child with help), and whether the setup screens should be
  hidden behind a parent PIN.
- Whether the child should see marks and percentages at all, or only stars/progress.
- Rewards: stars, streaks, stickers, sounds? Any the family would object to?
- The real child (or children) who will test it, their age, and whether I can watch a test session.
- Which Arabic dialect and level for UI wording (simple MSA vs. Saudi colloquial).

## Ground rules
- One screen, one job, one big button. If a screen needs explaining, redesign it.
- **Arabic first**, right-to-left, simple words a 10-year-old knows. English only for terms the course itself uses.
- Pictures and icons with every action, never icons alone.
- No numbers that need interpretation: no percentages, ranges, costs, intervals or counts above 20. Use stars,
  progress bars, "3 left" and emoji-free plain sentences ("You know this one!").
- No dead ends: every error says what to do next, in the child's language, with one button that does it.
- Nothing a child can break: no delete, no logout, no token field, no settings that lose data, on child screens.
- Accessibility: tap targets at least 56 dp, text at least 18 sp (scales with the phone's font size), contrast
  AA, works one-handed, no time pressure unless the child picks a timed game.
- Same offline-first behaviour: everything the child does works without internet and syncs later, silently.

## The child's app
- **Home = one big "Study" button** for the most urgent exam, with a friendly line ("Science quiz on Thursday!")
  and a simple progress bar (or stars). Below it, other upcoming exams as large cards. Nothing else.
- **A session is one tap.** The app picks the length (about 10 minutes, or what the plan says) and the cards; no
  minute chips, no triage page. "Do more" at the end continues if the child wants.
- **Answering:**
  - Multiple choice and true/false: large buttons. Tap an answer → immediate right/wrong with a short why.
  - Keep the confidence step (Guessing / Unsure / Sure; kept at my request 2026-10-14), as big buttons that also
    check the answer, so it costs no extra tap.
  - Written answers: one text box, then show the model answer and ask "Did you get it?" with two big buttons
    (Yes / Not yet); "partly" only when the card has a rubric, shown as simple ticks.
  - Cloze and typed answers: big keyboard-friendly box, forgiving matching (already lenient).
  - Problems: show the steps one at a time ("Next step"), then the answer.
- **Feedback that motivates:** a short celebration for right answers and for finishing, gentle wording for
  wrong ones ("Let's see it again in a moment"), a visible "3 cards left" counter, and an end screen with stars
  and one sentence about what improved. No scores that feel like failing.
- **Before the exam:** "Night before" and "Exam morning" become one big button each on the home card when it's
  their time, as short games of ~10 cards, plus the summary sheet in large readable text.
- **Practice test:** one button, "Try a practice test", with fixed sensible settings (no form). Results as
  stars per topic, and "Practise the ones you missed" as the only next step.
- **Reminders:** one daily reminder at a time the adult picks, worded for a child.
- **Help:** a tiny first-run walkthrough (3 screens max, skippable) and a "?" on each screen that shows a picture
  of what to do.

## Setup (the student's "My courses")
- **Sign-in without typing a token:** a QR code or a short one-time code I generate with `manage.py users`
  (e.g. 6 digits, expires in 24 h) that the phone exchanges for the real token. The long token path stays for me.
- Adding material, confirming exams, choosing what a quiz covers, hints, preparing (with the cost estimate),
  budget and language live in a separate "My courses" area, one tap from the home. Keep these screens as they are.
- Preparing an exam happens there; the home only shows exams that have cards ready.

## Out of scope (don't build)
- Accounts the child creates, chat with an AI tutor, voice (removed earlier at my request), social features,
  ads, purchases, avatars or shops.
- Changes to the owner's screens, the server's study logic or the AI generation.

## Delivery and workflow
- Work on a new branch from `main`. Commit in small steps; push and release through the usual scripts
  (`deploy/deploy.sh` only if the server changes, `deploy/release-apk.sh` for the app, forced update).
- Before building, write a short screen-by-screen plan (wireframes in ASCII are enough) into this file under
  "Design", then build without waiting for approval.
- Strings go through `t()` with Arabic translations; add tests for any new logic (session picking, inferred
  confidence, one-time codes).
- Test on the HONOR with the `qa-student` account (keep its data) and at least one fresh child account created
  with the new short code; switch the phone back to my owner token at the end.

## Definition of done
- A new student account can be set up on a phone with a QR/short code in under a minute, without typing a token.
- On the HONOR, starting from a cold app open, the child reaches the first question of a study session in **one
  tap**, and every child screen passes the ground rules above (checked screen by screen with screenshots).
- No child screen shows a percentage, cost, range, technical term, English error, or a way to delete data.
- A full session works offline and syncs later with no visible error.
- Night-before, exam-morning and practice-test flows each start with one tap from the home card.
- If a real student is available: they complete a session alone, without being told what to tap, and I record what
  confused them; fix those points and recheck.
- My owner screens are unchanged; my certs, cards and review history are intact; `qa-student` keeps its data.
- All code is committed and pushed, README.md and DECISIONS.md updated, and you end with a short summary: what
  changed, before/after screenshots of the main screens, how to create a student account, and anything left.

## Answers assumed (the batch went unanswered; change any of them)
- Setup is done by the students themselves (clarified): no PIN; the setup screens are under "My courses".
- **Answered 2026-10-14:** students set up their own courses; numbers instead of stars (your preference): each exam shows
  "40% learned · 12 of 30 cards" with a progress bar, a session ends with "7 of 10 right", a practice test with a score
  per topic; short vibration kept; no test user; Modern Standard Arabic.
- Rewards: a short vibration on right answers. No streaks (nothing to lose for a missed day), no sounds.
- No test user available yet: checked screen by screen on the HONOR with screenshots.
- Simple Modern Standard Arabic.

## Design
```
New phone                 Home (student role)                  Study (easy mode)
+-------------------+     +--------------------------------+   +----------------------------+
|   [school icon]   |     | My study     [Help] [My courses]|   | 5 left               [Help]|
|     Welcome!      |     | +----------------------------+ |   | Question text (bigger)     |
| Type the code ... |     | | Science 101                | |   |  [ option A ]              |
| [  ABCD 2345   ]  |     | | Quiz 2   The exam is ...   | |   |  [ option B ]              |
| [     Start     ] |     | | 40% learned · 12 of 30 [==] | |   |                            |
|                   |     | | [ Night before / Morning ] | |   +----------------------------+
| I have a token    |     | | [     > Study now       ]  | |   | [Guessing][Unsure][Sure]   |
+-------------------+     | | [ Try a practice test   ]  | |   |  then: Great job! [Next]   |
                          | +----------------------------+ |   |  or: Did you get it?       |
                          | (other exams, smaller)         |   |      [Not yet]   [Yes]     |
                          +--------------------------------+   +----------------------------+
End: trophy, "7 of 10 right", one sentence, [Do more] [Done]; a practice test adds a score per topic and
[Practise the ones you missed]. My courses -> the previous student screens: courses, material, exams,
preparing, and Settings.
```
- **Sign-in:** email + password. `POST /api/signup` makes a student (default cap) and `POST /api/login` signs in; both
  return a new token (the phone's own; the old one stops working). Logins are throttled to 10 wrong passwords per email
  per 10 minutes. Existing accounts: `manage.py users login <name> <email>` asks for a password. No reset or email
  verification yet: reset by running that command again. Settings → "Sign in" switches a signed-in phone.
- **One tap to study:** Study runs about 10 minutes: spaced cards when there's time, else the sprint loop (most
  valuable cards not known yet, each until right twice). No triage page, no minute choice.
- **Answering:** the confidence buttons (Guessing / Unsure / Sure) are the Check button: one tap rates and shows
  the answer ("Show me the answer" when nothing was typed); sure-but-wrong still shows the misconception warning;
  self-graded cards ask "Did you get it?" (Yes / Not yet); rubric ticks without percentages; no AI grading button;
  a problem's solution one step at a time. Normal app sizes (1.4.1, at your request): 50 dp buttons, the
  phone's own text size.
- **Night before** (the day before): the night or summary sheet in large text and a quick review. **Exam morning**
  (the day itself): the morning check. **Practice test:** 10 questions from the cards (offline, no AI cost).
- **Reminders** for a student are short and plain; the update screen is translated.
- Owner screens are unchanged.
