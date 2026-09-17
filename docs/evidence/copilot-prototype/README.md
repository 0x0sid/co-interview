# Copilot prototype — evidence

**All synthetic.** Every screenshot here shows a scripted interview, a fictional sample project and
the clearly-marked development fake provider. No real interview, no personal speech, no real model
output — the same rule that governs fixtures in this repository (`CO_INTERVIEW_SNAPSHOT_NOTICE.md`).

Captured by `prompterUITests/CopilotEntryUITests` on 2026-09-17, iPhone 17 Pro Simulator (iOS 26.5),
driving the app by taps with **no launch arguments**.

| File | Shows |
|---|---|
| `01-home-screen.png` | Normal launch: *Scripts* home with the **Interview Copilot** entry |
| `02-copilot-start.png` | Demo / Live choice, language picker, build identifier |
| `03-demo-first-card.png` | DEMO badge, Listening, first detected question, streamed answer, fake-provider banner |
| `04-demo-newer-question-waiting.png` | "Newer question ready" — a new card did not steal focus |
| `05-demo-second-card.png` | Second card after Next |
| `06-after-ending-session.png` | Back on the start screen after End: capture released |
| `07-french-start.png` | French selected |
| `08-french-first-card.png` | French demo producing a card |
| `09-live-unconfigured.png` | Live disabled, with the reason stated — never silently substituted with canned answers |
| `10-scripts-intact.png` | Ordinary script reading still reachable |
| `11-home-dark.png` | The same home screen in dark appearance (captured separately with `simctl ui appearance dark`) |

Not evidence of: real provider latency, real answer quality, or device microphone behaviour. None of
those has been measured — see `docs/CO_INTERVIEW_AI_PIPELINE.md` §9 and §11.
