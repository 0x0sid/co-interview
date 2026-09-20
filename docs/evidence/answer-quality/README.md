# Answer quality — real-provider evaluation

What the answers actually say, before and after the knowledge-policy fix. Every run here is a **real
provider call** through the local backend. Nothing in this directory is mocked; a mocked answer would
prove the transport works and say nothing about answer quality.

All content is synthetic. No real interview, no real document, no credential.

## Running it

```bash
cd backend && node server.mjs          # needs OPENROUTER_API_KEY and COINTERVIEW_TOKENS in .env
node docs/evidence/answer-quality/answer-eval.mjs \
     docs/evidence/answer-quality/cases-after.json /tmp/out.md
```

The harness posts the exact body shape the iOS app sends to `/v1/copilot/answer`, streams the reply,
and records the text, the claimed sources, the time to first visible text and the total time. It
reads the client token from the git-ignored `backend/.env` (or `COINTERVIEW_TOKENS`) and never prints
it. `EVAL_BASE` points it at another port.

## The files

| File | What it is |
| --- | --- |
| `cases-before.json` / `before.md` | The five device failures, reproduced against the real provider on the code as it stood at `ee06061` — including the synthetic project fixture that live sessions were sending. |
| `cases-after.json` / `after.md` | The same cases plus French equivalents and four added checks, on the fixed code, on the **default `balanced` profile** (`google/gemini-2.5-flash-lite`). |
| `after-smart.md` | The identical prompt and cases on the `smart` profile (`deepseek/deepseek-v4.1-flash`). Diagnostic only — the shipped default is unchanged. |
| `cases-f.json`, `f-runs.md`, `f-runs-smart.md` | Case F run six times on each profile, because it is the one case that still fails and a single run would not establish that. |
| `f-runs-rerun-2026-09-20.md` | A second six-run block on the default profile, taken later on the same code and the same prompt. It came out **5 failures out of 6**, not 6 — see below. |

## What the before run showed

Six of ten cases refused outright, all with the same shape:

> "I cannot provide information about Ash maps or how to create them in Java **based on the provided
> documents**. The passages do not contain any details regarding this topic."

Two causes, both confirmed in code rather than inferred:

1. **`ANSWER_RULES` in `backend/server.mjs`** told the model to answer facts from the PASSAGES, to say
   plainly when something was "not covered by the documents", and — for a missing detail — to "write a
   placeholder in angle brackets, for example `<add a specific example>`, and keep going". That is
   cases A, C, D, E, F, H, and the placeholder in B.
2. **`CopilotStartScreen.makeLiveFeed()`** passed `SyntheticProjectFixture` into live sessions, so
   every live request carried a fictional person's instructions ("I am interviewing for programme
   lead of the Northbridge bus corridor. Answer in the first person…") and five invented passages.
   That is the fabricated first-person introduction in B.

## What the after run shows

| Case | Before | After (balanced) |
| --- | --- | --- |
| A — "Ash map" → HashMap | refused as not covered | explains HashMap, reads the mis-transcription correctly |
| B — fragment "In Java" | standalone answer, invented intro | answers the HashMap question the fragment continues |
| C — lambda | refused as not covered | explains lambdas |
| D — "simple maine" | refused, read as a question about the speaker | minimal valid `main`, in a code block |
| E — "Of France" | "I cannot answer questions about France" | answers the France/Indonesia comparison it corrects |
| F — "ash map and ash map" | refused | **still fails** — see below |
| G — personal, with passages | correct, cites `cv#2` | unchanged, still cites `cv#2` |
| H — personal, no evidence | refusal | general substance, then asks which project to use |
| I — two questions at once | (new) | answers both in one reply |
| J — time-sensitive | (new) | says plainly it cannot check live rates |
| K — mixed general + personal | (new) | answers the general half, asks for the specific programme |
| FR1–FR4 | FR1/FR2 partly worked | all four correct, in French |

No answer in the after run contains a placeholder, an invented employer or project, or a citation to
a passage that was not supplied.

## The one case that still fails

**Case F — "What's the difference between an ash map and ash map?"** Both sides of the comparison
transcribed to the same words, so which two types were meant is genuinely unknowable. The required
behaviour is to ask which two, and nothing else.

On the default `balanced` profile it failed **6 runs out of 6** in the first block (`f-runs.md`). It
usually *notices* the problem and even asks the question — and then answers an invented comparison
anyway, `HashMap` versus `TreeMap` or `Hashtable`, which the speaker would read aloud as an answer to
a question nobody asked.

**It is not deterministic, and the "6/6" should not be read as one.** A second six-run block on the
same code and the same prompt (`f-runs-rerun-2026-09-20.md`) came out **5 out of 6**:

| Run | Behaviour | Verdict |
| --- | --- | --- |
| F1, F2 | invents `HashMap` vs `TreeMap` and answers it | fail |
| F5 | invents `HashMap` vs `Hashtable` and answers it | fail |
| F3, F6 | asks the right question, then adds a general paragraph about map implementations anyway | fail — the required behaviour is to ask *and stop* |
| F4 | "…could you please clarify which two Java collections you would like me to compare?" and nothing else | **pass** |

So across twelve recorded runs on the default profile the case passes once. The honest claim is that
it fails most of the time and cannot be relied on, not that it never passes. The `smart` profile's
6-out-of-6 (`f-runs-smart.md`) is a single block too and carries the same caveat.

On the `smart` profile, with the **same prompt and the same cases**, it passes **6 runs out of 6**
(`f-runs-smart.md`):

> "Which two map types did you mean? The transcript has both sides as 'ash map', so I can't tell
> which comparison you're asking for."

So this is an instruction-following limit of the configured small model on one hard instruction, not
a contradictory or broken prompt: the identical prompt gets every other ambiguity and fabrication
case right on both models, and gets this one right on the larger model. **The default profile has
deliberately not been changed** — swapping models to make a failing case pass would hide the finding
rather than fix it. The choice belongs to the owner, and `after-smart.md` is here so it can be made
on evidence.

## What these numbers do not prove

`ANSWER_RULES` teaches the speech-to-text rules with examples, and two of them are **the wording of
the cases measured here**: "ash map" → `HashMap` is named in the prompt, and so is the shape of case
F ("the difference between an ash map and an ash map"). Cases A and F are therefore not blind — the
model is told the answer to A before it sees it, and told exactly what F is before it fails it.

That was a deliberate prompt-writing choice: those are the real mis-transcriptions the device
produced, and the prompt is meant to handle them. But it does limit what the run shows. Case A
passing says the instruction is followed, not that an unseen mis-transcription would be. Case F is
the more interesting one for being contaminated in the other direction: it fails most of the time
*even though the prompt names it*, which is why it reads as a model limit rather than a wording
problem.

Cases C, D, E, H, I, J, K and FR1–FR4 are not named in the prompt and are the ones that carry weight
for generalisation.

## Timing

First visible text, default profile, across the after run: **334–825 ms**, median around 490 ms.
Streaming is not held back until the answer is complete; the `SOURCES:` line is withheld from the
reader but costs no visible delay.
