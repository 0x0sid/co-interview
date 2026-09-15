# Co-Interview copilot — open questions

**Status: unresolved owner decisions, 2026-09-16.**

This document owns **only decisions that belong to the owner and are not yet made**. Each has a
recommendation (not approved) and what it blocks. When a question is answered, record the answer as a
dated entry in [`CO_INTERVIEW_DECISIONS.md`](CO_INTERVIEW_DECISIONS.md) and delete it from here.

Engineering choices that follow from these answers (model names, thresholds, file layout) are not
listed; they belong in the architecture and implementation plan.

| # | Question | Blocks |
|---|---|---|
| Q1 | Where does the interviewer's voice come from? | Increment 1 protocol; the whole MVP audio route |
| Q2 | On-device or cloud speech recognition? | Increment 7 |
| Q3 | Which AI provider, and who hosts the app backend? | Increment 6 |
| Q4 | Participant notice and cloud-processing disclosure | Enabling live cloud processing (Increments 7–8) |
| Q5 | What does a saved session contain, and how long is it kept? | Increment 4 models; Increment 8 deletion |
| Q6 | First-release document formats and limits | Increment 5 |
| Q7 | First-release language scope | Increment 1 test language; Increments 6–7 prompts and evaluation |
| Q8 | Where do projects sit in the app's navigation? | Increment 4 UI |

---

## Q1 — Where does the interviewer's voice come from?

"On phone" confirms the iPhone, not the audio route. Which of these is the intended setup?

- **A.** A call in another app on the same iPhone (FaceTime, WhatsApp, Zoom, Teams, Meet…)
- **B.** A regular phone call on the same iPhone
- **C.** In person, with the iPhone's microphone hearing the room
- **D.** A call on another device (laptop, tablet) playing aloud near the iPhone

**Why it matters.** iOS documents no route for a third-party app to capture another app's call audio,
and Apple's developer support states there is no API to record Phone-app calls (arch §4.1). A and B
cannot be promised. C and D use the capture pipeline the app already has.

**Recommendation.** Target **C and D** for the first release, with the setup requirement for D that the
call plays on a speaker, not headphones. If A or B is essential, choose one of the alternatives in arch
§4.4 rather than building on an undocumented route.

**Blocks.** The Increment 1 device protocol and whether the proposed MVP is viable as written.

---

## Q2 — On-device or cloud speech recognition?

**Options.** (C) Apple's on-device `SpeechTranscriber` — audio never leaves the phone; (C′) OpenAI
`gpt-live-transcribe` — audio streamed to the provider; (R) OpenAI Realtime audio understanding.

**Recommendation.** **On-device first (C)**, switching to C′ only if Increment 1 shows far-field
recognition of the interviewer is inadequate. R is not recommended (arch §8.2): continuous audio
upload, less control over question boundaries, and the model hears the user reading its own
suggestions.

**Blocks.** Increment 7. Increment 1 supplies the evidence; this decision can wait for it.

---

## Q3 — Which AI provider, and who hosts the app backend?

The planning request named OpenAI; nothing is configured. Permanent keys cannot ship in the app, so a
backend is required.

**Decide.** (a) Approve OpenAI as the provider for answer generation. (b) Where the backend runs and who
operates it. (c) How the app authenticates to it (for example Sign in with Apple, App Attest, or a
private test token during development only). (d) Whether to apply to OpenAI for Zero Data Retention or
Modified Abuse Monitoring (by default, abuse-monitoring logs are kept up to 30 days).

**Recommendation.** OpenAI via a minimal app-owned relay (arch §8.4) that stores no content; local
developer-run backend for Increment 6; defer hosting and production auth until Increment 8; apply for
reduced retention before external users.

**Blocks.** Increment 6. Account and key setup is done by the owner outside chat.

---

## Q4 — Participant notice and cloud-processing disclosure

The app listens to another person and, under the proposed design, sends text derived from their words
and the user's documents to a third-party AI provider.

**Decide.**

1. Whether the app shows guidance before each session that other participants may need to be informed
   (recording and listening rules vary by jurisdiction; this is a legal question as much as a product one).
2. The disclosure and explicit permission for sending text to a third-party AI (App Review 5.1.2(i)),
   and when it is asked — once, per project, or per session.
3. The in-session indication that the microphone is active (App Review 2.5.14).
4. The new microphone and speech-recognition permission wording (the inherited strings claim nothing is
   sent anywhere, which would become false).

**Recommendation.** Explicit opt-in per project before its first cloud request, naming the provider and
what is sent (question, recent conversation text, project instructions, extracted document text — never
audio); a short pre-session reminder about informing participants, without the app claiming legal
compliance; a persistent Listening indicator; no recording. Take legal advice before external release.

**Blocks.** Enabling live cloud processing for anyone but the owner (Increment 7) and Increment 8.

---

## Q5 — What does a saved session contain, and how long is it kept?

Projects containing sessions with questions and answer versions are confirmed; exact persistence and
retention are not.

**Decide.** (a) Whether sessions are saved by default. (b) Whether saved sessions keep detected question
text (the interviewer's words), answer versions and source references. (c) Whether any transcript is
kept. (d) Automatic deletion after a period, or manual only. (e) Whether project documents and sessions
are included in device backups.

**Recommendation.** Save sessions by default with question text, answer versions and source references;
**never** keep audio or the running transcript; manual deletion per session and per project, with an
optional auto-delete setting later; exclude original documents from iCloud backup initially, since
they are user-supplied copies of files that already exist elsewhere.

**Blocks.** Increment 4 data models and Increment 8 deletion behaviour.

---

## Q6 — First-release document formats and limits

**Recommendation.**

- **Supported:** `.txt`, `.md`, PDF with a text layer; `.docx` if a dependency-free extractor passes its
  fixtures (otherwise shown as not yet supported).
- **Not in the first release:** scanned PDFs and images (OCR), spreadsheets, presentations, Pages/Keynote,
  RTF, HTML and everything else — each shown as unsupported, not silently accepted.
- **Limits:** 10 documents per project, 20 MB per file, 300 PDF pages, ~40,000 estimated tokens of
  extracted text per project, 4,000-character instructions (rationale in arch §6.5).
- **Alternatively** approve adding a third-party DOCX/ZIP dependency, which would be the first new
  dependency since the fork.

**Blocks.** Increment 5.

---

## Q7 — First-release language scope

Interviews across subjects do not require every language at once. The inherited French and Traditional
Chinese support is unvalidated.

**Decide.** Which interview languages the first release supports, and whether answers are always in the
question's language.

**Recommendation.** **English only** for the first release, including recognition, detection, answers and
evaluation; answers in the language of the question once more languages are added; each added language
gets its own recognition and grounding evaluation.

**Blocks.** The Increment 1 test language, and prompt and evaluation design in Increments 6–7.

---

## Q8 — Where do projects sit in the app's navigation?

Today `RootView` opens `ScriptListScreen`. Script reading must be preserved.

**Options.** Projects become the home screen with a Scripts section; a two-tab layout (Interviews,
Scripts); or Scripts stays home with a Projects entry.

**Recommendation.** Two tabs — **Interviews** (projects) and **Scripts** — so neither experience is buried
and script reading stays one tap away, unchanged.

**Blocks.** Increment 4 UI. Increments 1–3 do not need it.
