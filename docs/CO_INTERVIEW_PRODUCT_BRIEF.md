# Co-Interview — product brief

## Confirmed

Only these four things are decided. Everything else in this document is a question.

1. The project is called **Co-Interview**.
2. It is an **independent app derived from Prompter**, with its own repository, identity and data.
3. **Prompter development is paused.**
4. **No interview-specific functionality has been approved.** The inherited UI is scaffolding.

Explicitly **not** decided, and not to be assumed from Prompter: pricing, any subscription, whether
there is a free tier, which AI or cloud services (if any) are used, and whether anything is recorded.

## Open questions that materially change the architecture

These are ordered by how much they constrain the build. Each notes what swings on the answer.

### 1. Who is the user — interviewer, candidate, or both?
Determines whose screen it is, whose voice matters, and whether one device or two are involved. An
interviewer tool and a candidate tool share almost no UI.

### 2. In-person, remote calls, or both?
In-person means one microphone capturing two speakers in a room, needing speaker separation to be
useful at all. Remote means the other party's audio arrives through another app, which on iOS is a
hard constraint: **an app cannot capture another app's call audio**. If remote is required, the
viable shapes are narrower than they look, and this should be settled early.

### 3. What does it actually produce — transcription, suggested questions, answer assistance, or something else?
Transcription alone is a recording-and-notes product. Suggested questions implies understanding the
conversation as it happens. Answer assistance implies helping one participant respond, which carries
very different expectations about disclosure.

### 4. Live during the interview, after it, or both?
Live assistance requires low-latency processing and a glanceable interface under social pressure.
Post-interview analysis can be slower, richer and more considered. The two imply different technical
risk.

### 5. What happens to audio — retention, participant notice, consent, deletion?
This is a legal and ethical question, not only a technical one. Recording another person varies by
jurisdiction, and "the other person is informed" is a product feature with UI, not a footnote. Needed
before any capture beyond transient on-device transcription.

### 6. On-device processing, or approved cloud services?
Prompter is entirely on-device and advertises that. If Co-Interview sends audio or transcripts off
device, that is a different privacy posture, a different App Store privacy label, and a different
cost model. Do not assume either.

### 7. Target languages and initial platform?
Prompter inherited English-default with French and Traditional Chinese partially wired and
**unvalidated**. Co-Interview should state its own language scope rather than inheriting that state.
Platform is currently iOS only.

## How to use this document

Answer the questions above before feature work. An engineer can reasonably decide implementation
details; questions 1–6 are product and policy decisions that should not be invented by whoever picks
up the code next.
