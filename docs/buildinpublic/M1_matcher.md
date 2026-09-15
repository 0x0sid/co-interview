# M1: the matching engine, before a single line of speech code

The whole pitch for Prompter is "the script follows your voice." Before writing any
UI or touching Apple's speech APIs, we built and proved the thing that actually makes
that true: a pure, deterministic matcher that takes normalized spoken words in and
gives back a cursor position and confidence — no microphone, no ASR, no UI, just
Foundation and a lot of fixtures.

## What we tested it against

Four scripts (175–290 words each — a product announcement, a cooking-show intro, a
personal essay, and a tech explainer), each replayed through six noisy scenarios: a
clean read, ~10% ASR-style misrecognitions (homophones, dropped words, "going to" →
"gonna"), a skipped paragraph, a 20+ word off-script ad-lib, a repeated sentence, and
a long silence. 24 fixtures, 1,122 checkpoints, 5,474 simulated spoken words — all
programmatically generated from the real script text so every checkpoint has an exact
ground-truth cursor position to check against, not an eyeballed guess.

## The numbers

- **Mean cursor error: 1.58 tokens** (gate was ≤ 2)
- **False-jump rate: 0.55 per 500 spoken words** (gate was ≤ 1)

Both passed on the first tuning pass using the thresholds straight from the spec —
advance at 0.72 confidence, recovery search after 2.5 seconds of sustained low
confidence, never jump backward more than 3 tokens or forward more than 6 without
recovery-grade (0.80+) confidence, freeze the cursor after 1.5 seconds of silence.

## What broke

One fixture stuck out: the cooking-show script's ad-lib scenario, which alone
produced all 6 false jumps in the whole suite (21.9 tokens of error vs. 0.1–0.2 on
every other ad-lib run). We didn't guess why — we diffed the word sets directly. Our
synthetic ad-lib filler ("so yeah i think what i really want to say here is that this
whole thing about...") happens to share seven ordinary words — *about, is, that, the,
to, today, you* — with that particular script, which is also the shortest one in the
suite. On a short script, that's enough common-word coincidence for the matcher to
occasionally convince itself it's still on-script during a genuine ad-lib.

We left it alone rather than retuning against it — the suite-wide average has real
margin (1.58 vs. a 2.0 gate), and hand-tuning thresholds to erase one synthetic
fixture's failure mode risks overfitting to that exact ad-lib sentence instead of
fixing anything real. It's now a flagged thing to watch for when we do live-device ad-lib
testing in M4: ordinary conversational filler on a short script is the most exposed
case for a spurious match.

## What we learned

Building the fixture suite forced a design decision we hadn't fully resolved: the
spec calls for sentence segmentation via `NLTokenizer`, but the matching engine has a
hard "Foundation only" rule (no SwiftUI, no Speech, no NaturalLanguage — pure,
testable, synchronous code). Turns out Foundation's own
`String.enumerateSubstrings(in:options:)` with `.byParagraphs` / `.bySentences` /
`.byWords` does real ICU-backed segmentation without needing NaturalLanguage at all —
so we kept the hard constraint and didn't lose anything.

Next: the speech pipeline (M2) — `SpeechAnalyzer` capture and a transcript stream
feeding this same matcher, still tested only through replayed transcripts until it's
time for Eric to run it on an actual phone.
