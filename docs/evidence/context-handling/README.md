# Conversation context — what actually reaches the provider

Generation was answering transcript fragments instead of the discussion they belonged to. This
directory records what was sent before the fix, what is sent after it, and how the fixed path answers
the reported cases against the **real provider**.

All content is synthetic. No real interview, document or credential.

## The reproduction

```
"Could you explain the difference between Java and Java 8?"
"And Java 9."
"And Java 7."
[Generate]
```

## Where the information was lost

Four independent losses, each confirmed by inspecting the actual data rather than by reading code.

**1 · The question was reconstructed on the device, from fragments.** `questionFromDiscussion`
collected the lines that *looked* interrogative and joined them. "And Java 9." and "And Java 7." have
no question mark and no interrogative opener, so they were not collected. Traced on the real
snapshot:

| Situation | `question` the device produced |
| --- | --- |
| all three lines new | `Could you explain the difference between Java and Java 8?` — the other two versions never left the phone |
| opening question already answered | `And Java 9. And Java 7.` — **the subject was gone entirely** |

The second row is the reported symptom. Once the opening question had been answered it was in the
*background* half, and the heuristic consulted background for at most one preceding line.

**2 · The device sent only the last 12 lines.** `InterviewScreenModel.snapshotLineLimit = 12`, with
`backgroundLineLimit = 6` inside it. Traced with 16 lines spoken: 12 sent, and the fact the question
was about — "My most recent project was the Mill Street rollout." — was silently absent.

**3 · The backend cut the conversation again, to 12 lines.** `MAX_CONVERSATION_LINES` with
`.slice(-12)` in `buildAnswerMessages`. Captured from the outgoing upstream body with 16 lines
posted: the first four, including "Mill Street", were dropped on the server too.

**4 · The tab title was the device's guess.** `LiveInterviewFeed` announced its own reconstructed
string as the entry label, so the tab was named after whichever fragment the heuristic kept.

A fifth, smaller one: the non-Generate path used `recentContext(maximumUtterances: 6)`.

## What the provider received

Captured from the upstream request body, not inferred. Before, with the opening question answered:

```
CONVERSATION (recent, oldest first — the QUESTION may be a fragment of, or a correction to, what is here):
- Could you explain the difference between Java and Java 8?
- And Java 9.
- And Java 7.

QUESTION:
And Java 9. And Java 7.
```

The conversation was intact here — this session is only three lines — but `QUESTION` is what the
rules tell the model to answer, and it named no subject. In a session longer than twelve lines the
conversation was cut as well.

After:

```
CONVERSATION so far (everything said this session, oldest first — this is history, already dealt
with unless TO ANSWER NOW repeats it):
- Could you explain the difference between Java and Java 8?
- And Java 9.
- And Java 7.

YOUR EARLIER SUGGESTIONS (written by you, shown on screen, possibly read aloud — NOT things the
speaker said about themselves, and not evidence about them):
[suggestion 1] Java 8 introduced lambdas and the Stream API.

TO ANSWER NOW (said since your last suggestion — this is the request; read it against CONVERSATION):
- And Java 9.
- And Java 7.
```

With 41 lines posted, all 41 now appear upstream; the contract test asserts that line by line.

## Real-provider results

Default profile, unchanged: `balanced` / `google/gemini-2.5-flash-lite`. Outputs are recorded
verbatim in `after.md` (first run) and `titles-run.md` (second run, which also records the tab
title). `cases-context.json` is the input. **Neither file has been edited to remove a failure.**

These are five separate questions and a case can pass some and fail others. Scoring them as one
number is how a factually wrong answer gets called a pass because the right words appear in it.

| Case | 1 · Context coverage | 2 · Answers the current request | 3 · Factual accuracy | 4 · Title | 5 · First text |
| --- | --- | --- | --- | --- | --- |
| J1 | pass — all three fragments present | pass — one comparison, not three answers | **FAIL — attributes `var` to Java 9** | pass — "Compare Java 7, 8, and 9" | 768 ms |
| J2 | pass — subject recovered from background | pass — one comparison | **FAIL — attributes `var` to Java 9** | pass — "Compare Java 7, 8, and 9" | 526 ms |
| J3 | pass | pass — narrowed to 7 and 8, Java 9 absent | pass | pass — "Compare Java 7 and 8" | 500 ms |
| L1 | pass — subject taken from the prior suggestion | pass — an example, with code | pass — valid `Runnable` lambda | pass — "Example of a Java lambda" | 560 ms |
| F1 | pass — fact 31 lines back | pass | pass | pass — "Previous project mention" | 632 ms |
| FR1 | pass | pass — one comparison, in French | pass | pass — "Différences entre Java 7, 8 et 9" | 568 ms |
| FR2 | pass | pass — an example, with code | pass — valid `@FunctionalInterface` lambda | pass — "Exemple de lambda Java" | 431 ms |
| FR3 | pass | pass | pass | pass — "Projet mentionné" | 514 ms |

**Context coverage: 8/8. Current-request handling: 8/8. Titles: 8/8. Factual accuracy: 6/8.**

Timings are `First visible text` as recorded in `after.md`; the second run is within the same range
(466–858 ms). Both are milliseconds. J3's recorded figures are **500 ms to first visible text and
902 ms to complete** — an earlier draft of this table quoted 528 ms for J3, which was the value from
a run taken before the prompt was finalized, and it has been corrected to the recorded number.

### The factual failure, in full

J1 and J2 both credit Java 9 with local-variable type inference. Verbatim from `after.md`, J2:

> "Java 9, released in 2017, focused on modularity with the Java Platform Module System (JPMS), also
> known as Project Jigsaw. It also included features like the `var` keyword for local variable type
> inference and enhancements to the Stream API."

`var` is **Java 10**, not Java 9. Verified against primary sources:

- [JEP 286: Local-Variable Type Inference](https://openjdk.org/jeps/286) — `Release: 10`.
- [Oracle, *What's New in Java SE 9*](https://docs.oracle.com/javase/9/whatsnew/toc.htm) — Java 9's
  language changes are the small JEP 213 "Milling Project Coin" items; `var` is not among them.

It is **systematic, not a one-off**: present in J1 and J2 in both recorded runs. FR1 answers the same
comparison in French and never makes the claim.

Everything else in those two answers checks out — Java 7 (2011) try-with-resources and the diamond
operator, Java 8 (2014) lambdas, the Stream API, default methods and the date/time API, Java 9 (2017)
JPMS and the Stream API additions.

**This has not been fixed, and it is deliberately not fixable here.** Writing "`var` is Java 10" into
the production prompt would hardcode a correction for one fact in one language for one test case,
and would do nothing for the next wrong date. It is a property of the configured model, it belongs in
the answer-quality ledger rather than in this context fix, and the default model is unchanged for
this increment.

## Software correctness and answer quality are separate ledgers

- **Software correctness** — does the whole discussion reach the provider, in labelled parts, with
  the right title shown? Deterministic, settled by the contract tests and the captured upstream
  bodies, and it does not depend on which model is configured. Columns 1, 2 and 4 above.
- **Answer quality** — given a correct payload, is the answer true and useful? A property of the
  configured model. Column 3.

This increment fixes the first and measures the second. The factual failure above is real and is
recorded, not smoothed over; it is not evidence that the context fix failed, and the context fix is
not evidence that the answers are accurate.

Each case ran **twice**. Two runs show the fixed path working and establish that the `var` error
repeats; they are not a rate. The earlier `docs/evidence/answer-quality/` finding also still stands —
a comparison whose two sides transcribe identically fails most of the time on this profile. The
default model was not changed for this increment.

## Limits

`INPUT_CONTEXT_TOKENS` (default 120 000) is a **configured** budget, not a capability read from the
provider — the gateway does not report context windows. The estimate is characters ÷ 4, not a real
tokenizer count, and the refusal says so. A conversation over budget is refused with HTTP 413 and
`error: "context_limit"`, carrying the estimate, the budget and the reserve; nothing is shortened,
and the transcript on the device is untouched. There is no compaction: this increment makes the limit
explicit rather than silently dropping the beginning.
