# Co-Interview copilot — product brief

**Status: planning track, 2026-09-16. No copilot feature is implemented.**

This document owns the **product intent**: what the owner confirmed, the user journeys, the proposed
first release (MVP), what is excluded, and a pointer to every open decision. It does not own
technical design ([`CO_INTERVIEW_COPILOT_ARCHITECTURE.md`](CO_INTERVIEW_COPILOT_ARCHITECTURE.md)),
sequencing ([`CO_INTERVIEW_COPILOT_IMPLEMENTATION_PLAN.md`](CO_INTERVIEW_COPILOT_IMPLEMENTATION_PLAN.md))
or the decision questions themselves
([`CO_INTERVIEW_COPILOT_OPEN_QUESTIONS.md`](CO_INTERVIEW_COPILOT_OPEN_QUESTIONS.md)).

Every statement below is marked as one of:

- **Confirmed** — stated by the owner.
- **Proposed** — a recommendation written for review. Not approved.
- **Excluded** — deliberately out of scope for the proposed first release.

---

## 1. Confirmed direction

Co-Interview is becoming an **interview copilot used on an iPhone**. The owner confirmed:

| # | Requirement |
|---|---|
| C1 | Preserve normal script-reading functionality |
| C2 | Preserve voice-following scrolling and spoken-word styling |
| C3 | Listen to available interview speech and maintain conversation context |
| C4 | Detect questions and requests that call for an answer |
| C5 | Generate suggested answers |
| C6 | Present those answers in the existing teleprompter reading experience |
| C7 | Continue listening while the user reads |
| C8 | Support successive questions and follow-up answers |
| C9 | Swipe left/right between question-and-answer cards |
| C10 | Organize preparation around **projects** containing user-supplied documents |
| C11 | Process and understand those documents so suggestions can use relevant project context |
| C12 | Support interviews across subjects — not only job interviews or software roles |
| C13 | The interview happens "on phone" — this confirms the **device**, not the audio route (see §5) |

**Not inherited from Prompter:** pricing, subscriptions, the daily allowance, the paywall and Prompter's
release milestones. They carry no authority here. Commercial limits are out of this plan until the
owner settles them.

**Broad scope is not universal support.** C12 means the design must not assume a CV, a job or a
software role. It does not mean every language, file format, audio source or platform ships in the
first release.

---

## 2. Who it is for and what it does

**Proposed framing.** The user is the person being interviewed (candidate, expert, guest, applicant,
student, spokesperson). Before the interview they create a project, add reference documents and write
instructions. During the interview the iPhone listens, recognises when something calls for an answer,
and shows a suggested answer in the familiar large reading text, which follows the user's voice as
they speak. Each question becomes a card; the user swipes between cards.

Suggestions are **silent text**. Nothing is spoken aloud by the app.

The copilot is a **suggestion tool**. It must not present invented personal experience or project
facts as true, and it must show when an answer is not grounded in the user's own documents.

---

## 3. User journeys

### J1 — Prepare a project *(C10, C11)*

1. Create a project: name, optional description.
2. Write instructions — the context and the kind of help wanted ("Panel interview for a hospital
   board seat; answer in first person; keep answers under a minute").
3. Add documents (for example a CV, a job description, a product specification, a company briefing,
   research notes, a meeting agenda, a technical reference).
4. Watch each document move through processing to **Ready**, **Partially processed**,
   **Unsupported** or **Failed**. A filename in the list never implies its contents were understood.
5. Replace or remove documents; removal also removes everything derived from them.

### J2 — Run a live interview *(C3–C9)*

1. Open the project and start a session. The app states what it listens to, what leaves the device,
   and which documents are Ready (documents still processing are shown as not yet used).
2. The app listens. When a question or request is detected, a card is appended: a compact question
   header, then the suggested answer streaming in as a preview.
3. When the answer version is complete, the user reads it aloud; the text follows their voice and
   spoken words fade, exactly as in script reading.
4. The app keeps listening. A follow-up question appends another card **without taking focus away**
   from the card being read. An indicator shows that a newer card exists.
5. The user swipes (or uses Previous/Next) between cards. Returning to a card restores where they were.
6. If detection misses something, the user asks for an answer manually (§4.4).
7. The user may regenerate an answer; the previous version is kept.
8. The user ends the session. Nothing later reopens it.

### J3 — Review after the session *(proposed, depends on Q5)*

Open a past session in the project to see its questions, answer versions and the sources each answer
used — only if session persistence is approved (see
[Q5](CO_INTERVIEW_COPILOT_OPEN_QUESTIONS.md#q5--what-does-a-saved-session-contain-and-how-long-is-it-kept)).

### J4 — Read a script *(C1, C2 — unchanged)*

The existing script library, editor and reader keep working as they do today. The copilot is added
alongside, not in place of, script reading.

---

## 4. Proposed MVP (first release)

**Everything in this section is proposed, not approved.** The technical basis for each choice is in the
architecture document.

### 4.1 Audio

- **Proposed:** acoustic capture only — the iPhone microphone hearing the conversation in the room,
  either in person or from another device's speaker. This is the only scenario with a documented,
  already-implemented capture route (architecture §4).
- Capturing a call running **on the same iPhone** is **not** in the proposed MVP: iOS documents no route
  for a third-party app to capture another app's call audio or a Phone-app call. See §5.
- Foreground only. The screen stays awake during a session.

### 4.2 Documents

- **Proposed first-release formats:** plain text (`.txt`), Markdown (`.md`), PDF **with a text layer**,
  and Word (`.docx`) — DOCX conditional on a dependency-free text extractor passing its fixtures.
- **Not in the first release:** scanned PDFs and images (need OCR), spreadsheets, presentations, and all
  other formats. Each is an explicit scope decision, recorded in Q6.
- **Proposed limits** (for review): 10 documents per project, 20 MB per file, 300 PDF pages per file,
  and a project context budget of roughly 40,000 tokens of extracted text. Rationale in architecture §6.5.

### 4.3 Answers

- Grounded in: the current question, recent conversation, project instructions, and processed project
  documents.
- Compact source references, inspectable on demand, never cluttering the reading text.
- An answer with no supporting project source is labelled as such.
- Missing personal facts appear as a visible placeholder to fill in, never as invented detail.

### 4.4 Reading and navigation — proposed defaults

These are **proposed defaults**, distinct from the confirmed requirements in §1.

| Rule | Status |
|---|---|
| Each detected question owns its own answer versions and reading position | Proposed |
| New questions append cards and never steal focus; a "newer question" indicator appears | Proposed |
| A streaming answer is shown as a muted preview; voice-following starts only on a complete, stable version | Proposed |
| Text under the reading cursor never changes; regeneration creates a new version | Proposed |
| Regeneration belongs to the selected card and keeps the previous version | Proposed |
| Returning to an earlier card restores its reading position | Proposed |
| A late response can only update the version that requested it | Proposed |
| Ending a session is final; later events are discarded | Proposed |
| Accessible Previous / Next controls, and a "Latest" control when not on the newest card | Proposed |
| Status: Listening · Hearing speech · Question detected · Generating · Ready · Error | Proposed |
| Manual request: "Answer that" (uses the most recent unanswered speech), "Type a question", edit a detected question and regenerate | Proposed |

### 4.5 Data

- **Proposed:** audio is never recorded or stored; transcripts are held in memory only for the live
  session; project documents stay on the device and only selected text is sent for answer generation;
  saved sessions contain questions, answer versions and source references (subject to Q5).
- Cloud processing is **not enabled** until participant notice, disclosure and deletion behaviour are
  decided (Q4, Q5).

---

## 5. The "on phone" ambiguity

The owner said the interview happens "on phone". That settles the device. It does not settle where the
interviewer's voice comes from, and the answer changes feasibility completely:

| Scenario | Feasible for a live copilot? |
|---|---|
| A. A call in another app on the same iPhone (FaceTime, WhatsApp, Zoom, Teams…) | **No documented route.** Unsupported or uncertain — needs a device prototype, not a promise |
| B. A regular phone call on the same iPhone | **No.** iOS provides no API for third-party apps to capture Phone-app calls |
| C. In person, captured by the iPhone microphone | **Yes, documented and already implemented** — quality needs device verification |
| D. A call on another device (laptop, tablet) playing aloud near the iPhone | **Yes, same route as C** — only if the call audio is on a speaker, not headphones |

The full feasibility table, with sources and limitations, is in architecture §4. **No scenario has been
approved as the product setup.** The question is
[Q1](CO_INTERVIEW_COPILOT_OPEN_QUESTIONS.md#q1--where-does-the-interviewers-voice-come-from).

If the intended setup is A or B, feasible alternatives that do not silently change the product are:
take the call on a second device on speaker (D); type or paste the question manually (works in every
scenario); or prepare answers before or after the call. None of these is assumed.

---

## 6. Exclusions (proposed first release)

- Capturing another app's call audio or Phone-app calls on the same iPhone.
- Synthesized speech, earpiece prompting, or any audio output.
- Recording, storing or exporting interview audio.
- Durable raw transcripts, analytics, transcript logging, usage metering.
- Speaker identification or diarization.
- OCR (scanned PDFs, photos), spreadsheets, presentations, other formats.
- iPad-, Mac- or watch-specific experiences; background or locked-screen listening.
- Pricing, subscriptions, allowances, paywall changes.
- Languages beyond the scope set by Q7.
- Removing inherited Prompter code or the dormant RevenueCat dependency (separate decisions).

---

## 7. Open decisions

Owned by [`CO_INTERVIEW_COPILOT_OPEN_QUESTIONS.md`](CO_INTERVIEW_COPILOT_OPEN_QUESTIONS.md), which
gives each a recommendation and what it blocks:

- **Q1** Where the interviewer's voice comes from
- **Q2** On-device or cloud speech recognition
- **Q3** AI provider and app backend
- **Q4** Participant notice and cloud-processing disclosure
- **Q5** What a saved session contains and how long it is kept
- **Q6** First-release document formats and limits
- **Q7** First-release language scope
- **Q8** Where projects sit in the app's navigation

---

## 8. Relationship to earlier documents

[`CO_INTERVIEW_PRODUCT_BRIEF.md`](CO_INTERVIEW_PRODUCT_BRIEF.md) recorded the fork-day questions. The
confirmed direction settles two of them — the product gives **live answer assistance** — and strongly
implies a third (the user is the person answering, framed as a proposal in §2). The rest remain open
under the new numbers above. The fork-day document is kept unchanged as history.
