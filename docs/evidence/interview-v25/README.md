# v2.5 interview screen — evidence

**All synthetic.** Every screenshot shows a scripted interview with an invented candidate answering
invented questions about an invented service. The Context panel's thumbnails are placeholder images
the app draws itself behind a debug-only launch argument — **no photo library, no real document, no
real interview**. The microphone is never opened in these captures.

Captured by `prompterUITests/InterviewScreenCaptureTests` on 2026-09-17, iPhone 17 Pro Simulator
(iOS 26.5), driving the app by taps from the home screen with no launch arguments except
`-UITestsQuietMotion` (and `-InterviewSyntheticContextImages 5` for the Context shot).

| File | Shows |
|---|---|
| `01-collapsed-*.png` | Collapsed transcript — exactly two lines — a detected question, and **no answer**: nothing is generated until Generate is pressed |
| `02-answer-*.png` | The answer after pressing Generate: serif body at the board's 1.3 line height, with the code card in its original position **between** the paragraphs |
| `03-simulated-reading-*.png` | Simulated reading part-way through: spoken words faded to the muted tone, unread text still full contrast |
| `04-ready-chip-*.png` | "Q2 ready →" — an answer finished on a page the reader is not on; the page did not change |
| `05-expanded-context-*.png` | Expanded transcript with the Context panel: note plus five thumbnails, `5/5 images` |

Both appearances were captured: `-light` with `simctl ui … appearance light`, `-dark` with
`appearance dark`.

## What these show that matters

- **The listening mark is a waveform**, and during the demo it is drawn in the muted tone with the
  badge reading "Demo · scripted playback, microphone off". The red waveform is reserved for a
  microphone that is genuinely open, which this build never opens. No REC label, no timer.
- **The sparkle means Generate** and nothing else.
- **`n/N` is inside the question bar.** There is no separate "Question 2/3" row.
- The floating toolbar reserves its own height at the bottom of the page, so the last lines of an
  answer and the Follow-ups link can be scrolled clear of it.

## Not evidence of

Real provider latency, real answer quality, live microphone behaviour, or anything about a live
interview. None of that has been measured — Live is deliberately unavailable in this build. See
`docs/CO_INTERVIEW_AI_PIPELINE.md`.
