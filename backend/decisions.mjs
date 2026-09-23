// Typed conversation decisions from Jev, alongside the existing detector (docs/CO_INTERVIEW_AI_PIPELINE.md §15).
//
// **What this is for.** The existing detector is a generative model asked to return a small JSON
// verdict. Jev (TypeSafe System One) is a decision model: it returns a probability distribution over
// options we define, and nothing else. This module asks it three narrow questions about the same
// snapshot the detector saw, and records how the two compare.
//
// **What it is not for.** Jev never writes text: no question titles, no answers, no corrected
// transcript. And its focused input is **never** used to shorten an answer request — answers are
// built from the app's full snapshot on a separate path this module does not touch.
//
// Three modes, set by the operator (never by the app):
//
// - `off`    — the existing detector only. The default whenever the transport has no key.
// - `shadow` — the existing detector decides; Jev is asked the same thing **after** the response has
//              been sent, and the comparison is recorded. Nothing the user sees depends on it.
// - `active` — Jev decides only the decision types named in COPILOT_DECISION_ACTIVE, within a short
//              deadline, and the existing detector's verdict is used whenever Jev is late, failing,
//              unsure, or not trusted for that decision. Nothing is active by default.

import * as typesafe from "./providers/typesafe.mjs";

/** Bumped whenever a question, criterion, mapping or window below changes, so records say which. */
export const DECISION_CONFIG_VERSION = "decisions-2026-09-24.2";

/** How many conversation lines Jev sees. Matches the detector's own window, so both judge the same thing. */
export const JEV_CONVERSATION_LINES = 12;
const MAX_KNOWN_QUESTIONS = 5;

// ---------------------------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------------------------

export const DECISION_TYPES = ["role", "parent", "answer_need"];

/**
 * Which credential a transport uses. OpenRouter reuses the backend's existing OpenRouter key, so no
 * TypeSafe account is needed; TypeSafe direct uses its own. Read here and nowhere else.
 */
export function decisionApiKey(config, env = process.env) {
  return ((config.transport === "typesafe" ? env.TYPESAFE_API_KEY : env.OPENROUTER_API_KEY) ?? "").trim();
}

/**
 * Reads the decision configuration from the environment. Never returns the key itself — only
 * whether one is present — so the object is safe to log or report.
 */
export function decisionConfigFromEnv(env = process.env) {
  const transport = (env.COPILOT_DECISION_TRANSPORT ?? "").trim().toLowerCase() === "typesafe" ? "typesafe" : "openrouter";
  const keyPresent = Boolean(decisionApiKey({ transport }, env));
  const keyName = transport === "typesafe" ? "TypeSafe" : "OpenRouter";
  const requested = (env.COPILOT_DECISION_MODE ?? "").trim().toLowerCase();
  let mode;
  let modeReason;
  if (!["", "off", "shadow", "active"].includes(requested)) {
    mode = "off";
    modeReason = `unknown COPILOT_DECISION_MODE "${requested}"`;
  } else if (!keyPresent) {
    mode = "off";
    modeReason = requested && requested !== "off" ? `${requested} requested but no ${keyName} key is configured` : `no ${keyName} key is configured`;
  } else {
    // With a key and no explicit mode, this increment runs in shadow.
    mode = requested || "shadow";
    modeReason = requested ? "configured" : "default when a key is present";
  }
  const active = (env.COPILOT_DECISION_ACTIVE ?? "")
    .split(",").map((item) => item.trim()).filter((item) => DECISION_TYPES.includes(item));
  const number = (value, fallback) => (Number.isFinite(Number(value)) && Number(value) > 0 ? Number(value) : fallback);
  return {
    mode,
    modeReason,
    keyPresent,
    // Pinned, not `jev-latest`: the docs recommend pinning a version once thresholds are tuned
    // against it, and an alias can move underneath a comparison.
    transport,
    model: (env.COPILOT_DECISION_MODEL ?? "").trim() || typesafe.TRANSPORTS[transport].defaultModel,
    base: decisionBase(transport, env),
    // 8 s: Jev through OpenRouter answered mostly in 0.3–0.6 s but often in 1–6 s on 2026-09-24 (provider-side);
    // a shadow call is off the request path, so a deadline that cut the slow half would only measure it.
    shadowTimeoutMs: number(env.COPILOT_DECISION_TIMEOUT_MS, 8000),
    activeTimeoutMs: number(env.COPILOT_DECISION_ACTIVE_TIMEOUT_MS, 1200),
    maxAttempts: number(env.COPILOT_DECISION_MAX_ATTEMPTS, 2),
    maxConcurrency: number(env.COPILOT_DECISION_MAX_CONCURRENCY, 2),
    maxQueuedSessions: number(env.COPILOT_DECISION_MAX_QUEUED, 16),
    activeDecisions: mode === "active" ? active : [],
    // Minimum confidence for an active decision to override the detector. Not a calibrated
    // accuracy: the docs define confidence as how peaked the distribution is. Set from evaluation.
    activeMinConfidence: Math.min(1, number(env.COPILOT_DECISION_ACTIVE_MIN_CONFIDENCE, 0.6)),
    configVersion: DECISION_CONFIG_VERSION,
  };
}

/**
 * The decision endpoint's base. For OpenRouter it follows OPENROUTER_BASE (…/api/v1 → …/api), so a
 * local stub standing in for OpenRouter's chat API also stands in for its Decisions API.
 */
function decisionBase(transport, env) {
  const explicit = (env.COPILOT_DECISION_BASE ?? "").trim();
  if (explicit) return explicit.replace(/\/$/, "");
  if (transport === "typesafe") return (env.TYPESAFE_BASE ?? "").trim() || typesafe.TYPESAFE_BASE;
  const chat = (env.OPENROUTER_BASE ?? "").trim();
  return chat ? chat.replace(/\/v1\/?$/, "") : typesafe.OPENROUTER_DECISIONS_BASE;
}

/** The non-secret view, for /health and /v1/copilot/config. */
export function publicDecisionConfig(config) {
  return {
    mode: config.mode,
    reason: config.modeReason,
    provider: "typesafe",
    transport: config.transport,
    model: config.model,
    key_configured: config.keyPresent,
    active_decisions: config.activeDecisions,
    config_version: config.configVersion,
  };
}

// ---------------------------------------------------------------------------------------------
// Snapshot
// ---------------------------------------------------------------------------------------------

const clip = (value, max) => (typeof value === "string" ? value.slice(0, max) : "");
const normalize = (text) => String(text ?? "").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();

/**
 * The detector's request body, as a decision snapshot. Every field is optional except the speech,
 * so an older app — which sends none of the identity fields — still gets a shadow comparison.
 */
export function snapshotFromClassifyBody(body) {
  const conversation = Array.isArray(body.recentConversation)
    ? body.recentConversation.filter((line) => typeof line === "string").map((line) => clip(line, 400))
    : [];
  const newSpeech = clip(body.newSpeech, 2000).trim();

  // The app's recent conversation already ends with the newest speech. Jev is shown it once, as the
  // thing being judged, so the trailing lines that make it up are separated from what came before.
  const before = [...conversation];
  const target = normalize(newSpeech);
  let tail = "";
  while (before.length) {
    const candidate = normalize(`${before[before.length - 1]} ${tail}`);
    if (!target.endsWith(candidate)) break;
    tail = candidate;
    before.pop();
  }

  const known = Array.isArray(body.knownQuestions) ? body.knownQuestions : [];
  const utterances = Array.isArray(body.utterances) ? body.utterances : [];
  return {
    sessionID: clip(body.sessionID, 64) || null,
    snapshotID: clip(body.snapshotID, 64) || null,
    diagnosticsSessionID: clip(body.diagnosticsSessionID, 64) || null,
    captureContent: body.captureContent === true,
    generationEpoch: Number.isInteger(body.generationEpoch) ? body.generationEpoch : null,
    language: clip(body.language, 16) || "en",
    knownQuestions: known
      .filter((q) => q && typeof q.id === "string")
      .slice(-MAX_KNOWN_QUESTIONS)
      .map((q) => ({ id: clip(q.id, 64), text: clip(q.text, 300), answered: q.answered === true })),
    conversationBefore: before,
    conversationLinesReceived: conversation.length,
    newSpeech,
    activeAnswer: clip(body.activeAnswerText, 600) || null,
    utterances: utterances
      .filter((u) => u && typeof u.id === "string")
      .slice(0, 20)
      .map((u) => ({ id: clip(u.id, 64), revision: Number.isInteger(u.revision) ? u.revision : 0, isFinal: u.isFinal === true })),
  };
}

// ---------------------------------------------------------------------------------------------
// The questions
// ---------------------------------------------------------------------------------------------

// The examples in these criteria are deliberately **not** taken from the evaluation cases, so the
// held-out split measures generalisation rather than recall of the prompt.

export const ROLE_OPTIONS = {
  new_request:
    "Asks for something the interviewee should answer now: a question, or a request such as \"tell me about…\", \"explain…\", \"walk me through…\", \"show me an example…\", \"compare…\", with or without a question mark. A question asked again later, as a fresh request, is also a new request.",
  continuation:
    "Adds to a question or request that is already being asked, without replacing it: an extra item (\"And also Go.\"), a qualifier or context (\"For a REST API.\"), or the rest of a sentence that was cut off.",
  correction:
    "Changes, narrows or replaces a question already asked: \"actually, only the first one\", \"no, I meant the other framework\", \"just the second part\".",
  answer_or_explanation:
    "Gives information rather than asking for it: the interviewee answering or reading an answer aloud, or the interviewer explaining, describing or commenting.",
  filler:
    "Asks nothing and says nothing substantive: acknowledgement, greeting, thanks, hesitation or backchannel (\"okay\", \"right, got it\", \"mm-hmm\").",
  unclear:
    "Too fragmentary or garbled to tell which of the other roles it plays.",
};

export const ANSWER_NEED_OPTIONS = {
  general:
    "General knowledge is enough: a concept, technology, method, comparison or code example that can be answered without knowing anything about the interviewee.",
  personal:
    "It asks about the interviewee: their own experience, projects, employers, results, choices or history.",
  mixed:
    "It needs both general knowledge and facts about the interviewee's own experience.",
  clarification:
    "It cannot be answered as heard: the request is garbled, or a misheard term has several plausible readings that would lead to different answers.",
  nothing_asked:
    "Nothing is being asked of the interviewee.",
};

/** The state Jev evaluates: small and named, as the documentation recommends. */
export function buildJevState(snapshot) {
  const keyed = snapshot.knownQuestions.map((q, index) => ({ key: `q${index + 1}`, question: q.text, already_answered: q.answered }));
  return {
    setting: "Live job interview. Text is an automatic speech-recognition transcript: punctuation may be missing and words may be misheard.",
    language: snapshot.language,
    earlier_questions: keyed,
    conversation_before: snapshot.conversationBefore.slice(-JEV_CONVERSATION_LINES),
    answer_being_read_aloud: snapshot.activeAnswer,
    newest_speech: snapshot.newSpeech,
  };
}

/**
 * Three independent questions in one call — allowed because none of them reads another's answer.
 * The parent question is asked only when there is something to point at; with no earlier questions
 * its answer is "none" by construction, decided in code rather than by the model.
 */
export function buildJevQuestions(snapshot) {
  const questions = {
    role: {
      type: "choice",
      instructions: "What role does `newest_speech` play in the conversation? Judge the newest speech only, using `conversation_before` and `earlier_questions` as context.",
      criteria: ROLE_OPTIONS,
    },
    answer_need: {
      type: "choice",
      instructions: "To answer what is being asked in `newest_speech` — together with the earlier question it adds to, if it adds to one — what does the interviewee need?",
      criteria: ANSWER_NEED_OPTIONS,
    },
    transcription_ambiguity: {
      type: "noul",
      instructions: "Does `newest_speech` contain a probable speech-recognition mistake for a technical term where more than one correction is plausible and the corrections would lead to different answers?",
      criteria: {
        true: "Several plausible readings of a misheard term remain, and they would change the answer.",
        false: "No misheard term, or the intended term is clear from the surrounding conversation.",
      },
    },
  };
  const parentKeys = {};
  if (snapshot.knownQuestions.length) {
    const criteria = {};
    snapshot.knownQuestions.forEach((q, index) => {
      const key = `q${index + 1}`;
      parentKeys[key] = q.id;
      criteria[key] = `Adds to, corrects, narrows or follows up on earlier question ${key}: "${q.text}"`;
    });
    criteria.none = "Refers to none of the earlier questions: a new or unrelated topic, the same question asked afresh, or speech that asks nothing.";
    criteria.unclear = "Could belong to more than one earlier question, or it is impossible to tell.";
    questions.parent = {
      type: "choice",
      instructions: "Which question in `earlier_questions`, if any, does `newest_speech` add to, correct, narrow or follow up on?",
      criteria,
    };
  }
  return { questions, parentKeys };
}

/**
 * Checks every answer against the question that asked for it: present, of the requested type, a
 * choice among the options offered, probabilities that are numbers in [0, 1] over exactly those
 * options, a noul in [0, 1]. Returns the problems found; an answer with a problem is not used.
 */
export function validateAnswers(questions, answers) {
  const problems = [];
  const unit = (value) => typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;
  for (const [id, question] of Object.entries(questions)) {
    const answer = answers?.[id];
    if (!answer || typeof answer !== "object") { problems.push(`${id}: missing`); continue; }
    if (answer.type !== question.type) { problems.push(`${id}: type ${answer.type} for a ${question.type} question`); continue; }
    if (question.type === "noul" && !unit(answer.noul)) problems.push(`${id}: noul outside [0, 1]`);
    if (question.type === "choice") {
      const options = Object.keys(question.criteria);
      if (!options.includes(answer.choice)) problems.push(`${id}: choice "${answer.choice}" is not an offered option`);
      const probabilities = answer.probabilities;
      if (probabilities !== undefined && probabilities !== null) {
        const keys = Object.keys(probabilities);
        if (keys.some((k) => !options.includes(k)) || !Object.values(probabilities).every(unit)) {
          problems.push(`${id}: probabilities do not match the offered options`);
        }
      }
      if (answer.confidence !== undefined && answer.confidence !== null && !unit(answer.confidence)) problems.push(`${id}: confidence outside [0, 1]`);
    }
  }
  return problems;
}

/** Reads Jev's answers into a decision, keeping every probability it reported. */
export function interpretJev(answers, parentKeys, problems = []) {
  const invalid = new Set(problems.map((p) => p.split(":")[0]));
  const choice = (id) => {
    if (invalid.has(id)) return null;
    const answer = answers?.[id];
    if (!answer || answer.type !== "choice" || typeof answer.choice !== "string") return null;
    return {
      choice: answer.choice,
      confidence: typeof answer.confidence === "number" ? answer.confidence : null,
      probabilities: answer.probabilities && typeof answer.probabilities === "object" ? answer.probabilities : null,
    };
  };
  const role = choice("role");
  const need = choice("answer_need");
  const parent = choice("parent");
  const ambiguity = !invalid.has("transcription_ambiguity") && answers?.transcription_ambiguity?.type === "noul" ? answers.transcription_ambiguity.noul : null;
  let parentID = "none";
  if (parent) {
    parentID = parent.choice === "none" || parent.choice === "unclear" ? parent.choice : (parentKeys[parent.choice] ?? "unclear");
  }
  return {
    role: role && ROLE_OPTIONS[role.choice] ? role.choice : null,
    roleConfidence: role?.confidence ?? null,
    roleProbabilities: role?.probabilities ?? null,
    parent: parentID,
    parentAsked: Boolean(parent),
    parentConfidence: parent?.confidence ?? null,
    answerNeed: need && ANSWER_NEED_OPTIONS[need.choice] ? need.choice : null,
    answerNeedConfidence: need?.confidence ?? null,
    transcriptionAmbiguity: typeof ambiguity === "number" ? ambiguity : null,
  };
}

// ---------------------------------------------------------------------------------------------
// Comparing with the existing detector
// ---------------------------------------------------------------------------------------------

/**
 * The detector's verdict in the same vocabulary. It has four kinds, so some distinctions it cannot
 * make: "continuation" covers both adding to and correcting a question, and "none" covers both
 * filler and statements. Comparisons use the collapsed classes below for that reason.
 */
export function baselineDecision(result, snapshot) {
  const known = new Set(snapshot.knownQuestions.map((q) => q.id));
  const kind = result?.kind;
  const related = typeof result?.related_question_id === "string" ? result.related_question_id : "";
  const role = { new_question: "new_request", continuation: "continuation", none: "no_request", incomplete: "unclear" }[kind] ?? "unclear";
  let parent = "none";
  if (kind === "continuation") parent = known.has(related) ? related : "unclear";
  return { kind: kind ?? null, role, parent, confidence: typeof result?.confidence === "number" ? result.confidence : null };
}

/** Collapses both vocabularies to what they can both express. */
export function collapsedRole(role) {
  switch (role) {
    case "new_request": return "new";
    case "continuation":
    case "correction": return "attach";
    case "answer_or_explanation":
    case "filler":
    case "no_request": return "no_request";
    default: return "unclear";
  }
}

export function compareDecisions(baseline, jev) {
  const disagreements = [];
  const roleAgrees = collapsedRole(baseline.role) === collapsedRole(jev.role);
  if (!roleAgrees) disagreements.push("role");
  // Parent only means something when at least one side attaches the speech to a question.
  const attaches = collapsedRole(baseline.role) === "attach" || collapsedRole(jev.role) === "attach";
  const parentAgrees = attaches ? baseline.parent === jev.parent : null;
  if (parentAgrees === false) disagreements.push("parent");
  return { roleAgrees, parentAgrees, disagreements };
}

// ---------------------------------------------------------------------------------------------
// Diagnostics records
// ---------------------------------------------------------------------------------------------

/**
 * Bounded, in-memory, expiring. Records hold identities, labels, probabilities, timings and usage —
 * **no conversation text** unless the app opted that request into content capture *and* the
 * operator enabled content diagnostics, the same two conditions as the answer path.
 */
export class DecisionRecorder {
  constructor({ maxPerSession = 60, maxSessions = 50, ttlMs = 30 * 60 * 1000, now = () => Date.now() } = {}) {
    this.maxPerSession = maxPerSession;
    this.maxSessions = maxSessions;
    this.ttlMs = ttlMs;
    this.now = now;
    this.sessions = new Map();
  }

  add(record) {
    const key = record.diagnostics_session_id || record.session_id || "unknown";
    this.prune();
    const entry = this.sessions.get(key) ?? { records: [], touched: 0 };
    entry.records.push(record);
    if (entry.records.length > this.maxPerSession) entry.records.splice(0, entry.records.length - this.maxPerSession);
    entry.touched = this.now();
    this.sessions.delete(key);
    this.sessions.set(key, entry);
    while (this.sessions.size > this.maxSessions) this.sessions.delete(this.sessions.keys().next().value);
  }

  /** Replaces a record in place — a queued snapshot that later completes, goes stale, or is dropped. */
  update(sessionKey, snapshotRef, change) {
    const entry = this.sessions.get(sessionKey);
    const record = entry?.records.find((r) => r.record_id === snapshotRef);
    if (record) change(record);
  }

  list(sessionKey) {
    this.prune();
    return this.sessions.get(sessionKey)?.records ?? [];
  }

  prune() {
    const cutoff = this.now() - this.ttlMs;
    for (const [key, entry] of this.sessions) if (entry.touched < cutoff) this.sessions.delete(key);
  }
}

// ---------------------------------------------------------------------------------------------
// The shadow queue
// ---------------------------------------------------------------------------------------------

/**
 * Runs Jev comparisons off the request path.
 *
 * - **Bounded concurrency.** At most `maxConcurrency` Jev calls at once, across all sessions.
 * - **Latest wins.** Each session has at most one waiting snapshot. A newer one replaces it, and the
 *   replaced one is recorded as `obsolete` — the conversation has moved on, and comparing a verdict
 *   about superseded speech would measure nothing.
 * - **Stale results are marked, not used.** A result whose utterances were revised, or whose session
 *   saw a generation, after the snapshot was taken is recorded as `stale`.
 * - **Nothing waits for it.** `submit` returns immediately; the caller has already answered.
 */
export class DecisionShadow {
  constructor({ config, apiKey, recorder, evaluate = typesafe.evaluate, log = () => {}, now = () => Date.now(), contentAllowed = false }) {
    this.config = config;
    this.apiKey = apiKey;
    this.recorder = recorder;
    this.evaluate = evaluate;
    this.log = log;
    this.now = now;
    this.contentAllowed = contentAllowed;
    this.running = 0;
    this.waiting = new Map(); // session → job
    this.latest = new Map(); // session → { revisions: Map(utteranceID → revision), epoch }
    this.counter = 0;
    this.idleResolvers = [];
  }

  /** Records what the session has seen, so later results about older speech can be recognised. */
  observe(snapshot) {
    const key = snapshot.sessionID ?? "unknown";
    const state = this.latest.get(key) ?? { revisions: new Map(), epoch: null };
    for (const u of snapshot.utterances) {
      state.revisions.set(u.id, Math.max(state.revisions.get(u.id) ?? -1, u.revision));
    }
    if (snapshot.generationEpoch !== null) state.epoch = Math.max(state.epoch ?? -1, snapshot.generationEpoch);
    this.latest.delete(key);
    this.latest.set(key, state);
    while (this.latest.size > 200) this.latest.delete(this.latest.keys().next().value);
  }

  staleness(snapshot) {
    const state = this.latest.get(snapshot.sessionID ?? "unknown");
    if (!state) return null;
    for (const u of snapshot.utterances) {
      if ((state.revisions.get(u.id) ?? u.revision) > u.revision) return "utterance revised after the snapshot";
    }
    if (snapshot.generationEpoch !== null && state.epoch !== null && state.epoch > snapshot.generationEpoch) {
      return "a generation was accepted after the snapshot";
    }
    return null;
  }

  submit(snapshot, baseline, baselineMeta = {}) {
    this.observe(snapshot);
    const record = this.newRecord(snapshot, baseline, baselineMeta);
    const sessionKey = snapshot.sessionID ?? "unknown";

    const replaced = this.waiting.get(sessionKey);
    if (replaced) {
      this.finish(replaced.record, { status: "obsolete", reason: "a newer snapshot for this session arrived before it ran" });
    } else if (!this.waiting.has(sessionKey) && this.waiting.size >= this.config.maxQueuedSessions) {
      this.finish(record, { status: "dropped", reason: "shadow queue full" });
      return { status: "dropped", recordID: record.record_id };
    }
    this.waiting.set(sessionKey, { snapshot, baseline, record });
    this.pump();
    return { status: "queued", recordID: record.record_id };
  }

  pump() {
    while (this.running < this.config.maxConcurrency && this.waiting.size) {
      const [sessionKey, job] = this.waiting.entries().next().value;
      this.waiting.delete(sessionKey);
      this.running += 1;
      this.run(job).finally(() => {
        this.running -= 1;
        this.pump();
        if (!this.running && !this.waiting.size) this.idleResolvers.splice(0).forEach((resolve) => resolve());
      });
    }
  }

  async run({ snapshot, baseline, record }) {
    const outcome = await decide({
      snapshot, config: this.config, apiKey: this.apiKey, evaluate: this.evaluate, timeoutMs: this.config.shadowTimeoutMs,
    });
    const stale = this.staleness(snapshot);
    this.finish(record, outcome.ok
      ? { status: stale ? "stale" : "ok", reason: stale, jev: outcome, baseline }
      : { status: "failed", reason: outcome.reason, jev: outcome, baseline });
  }

  /** Resolves when nothing is running or waiting. Tests and graceful shutdown only. */
  idle() {
    if (!this.running && !this.waiting.size) return Promise.resolve();
    return new Promise((resolve) => this.idleResolvers.push(resolve));
  }

  newRecord(snapshot, baseline, baselineMeta) {
    this.counter += 1;
    const record = {
      record_id: `${snapshot.snapshotID ?? "snap"}#${this.counter}`,
      recorded_at: new Date(this.now()).toISOString(),
      session_id: snapshot.sessionID,
      diagnostics_session_id: snapshot.diagnosticsSessionID,
      snapshot_id: snapshot.snapshotID,
      mode: this.config.mode,
      config_version: this.config.configVersion,
      utterances: snapshot.utterances.map((u) => ({ id: u.id, revision: u.revision, is_final: u.isFinal })),
      generation_epoch: snapshot.generationEpoch,
      baseline: { ...baselineDecisionView(baseline), model: baselineMeta.model ?? null, latency_ms: baselineMeta.latencyMs ?? null },
      jev: { status: "queued", provider: "typesafe", requested_model: this.config.model, transport: this.config.transport },
      comparison: null,
      stale: false,
      stale_reason: null,
      controlled_by: "baseline",
      context: contextBoundary(snapshot),
    };
    if (this.contentAllowed && snapshot.captureContent) {
      record.content = { new_speech: snapshot.newSpeech, baseline_question_text: baselineMeta.questionText ?? null };
    }
    this.recorder.add(record);
    return record;
  }

  finish(record, { status, reason = null, jev = null, baseline = null }) {
    record.jev = { ...record.jev, ...jevView(jev), status };
    if (status === "stale") {
      record.stale = true;
      record.stale_reason = reason;
    } else if (reason) {
      record.jev.reason = reason;
    }
    if (jev?.ok && baseline) record.comparison = comparisonView(compareDecisions(baseline, jev.decision));
    this.log(logLine(record));
  }
}

/** One Jev decision for one snapshot. Shared by shadow and active. */
export async function decide({ snapshot, config, apiKey, evaluate = typesafe.evaluate, timeoutMs, signal }) {
  const { questions, parentKeys } = buildJevQuestions(snapshot);
  const result = await evaluate({
    apiKey,
    transport: config.transport,
    base: config.base,
    model: config.model,
    state: buildJevState(snapshot),
    questions,
    timeoutMs,
    maxAttempts: config.maxAttempts,
    signal,
  });
  if (!result.ok) return result;
  const problems = validateAnswers(questions, result.answers);
  const decision = interpretJev(result.answers, parentKeys, problems);
  if (!decision.role) {
    return { ...result, ok: false, reason: "invalid_response", message: problems.join("; ") || "no usable role answer", problems };
  }
  return { ...result, decision, problems };
}

/**
 * Active mode: the detector's verdict, with the decision types the operator trusts replaced by
 * Jev's when Jev answered in time and confidently. Every other case is the detector's verdict,
 * unchanged, with the reason recorded.
 */
export function applyActiveDecision(baselineResult, snapshot, jevOutcome, config) {
  if (!jevOutcome?.ok) return { result: baselineResult, controlledBy: "baseline", fallbackReason: jevOutcome?.reason ?? "no_result" };
  const decision = jevOutcome.decision;
  const trusted = new Set(config.activeDecisions);
  const confident = (value) => typeof value === "number" && value >= config.activeMinConfidence;
  const result = { ...baselineResult };
  const used = [];

  if (trusted.has("role") && confident(decision.roleConfidence) && decision.role !== "unclear") {
    const kind = { new_request: "new_question", continuation: "continuation", correction: "continuation",
                   answer_or_explanation: "none", filler: "none" }[decision.role];
    if (kind && kind !== result.kind) {
      result.kind = kind;
      result.is_question = kind === "new_question" || kind === "continuation";
      // Jev writes no text. A question it found keeps the raw speech as its wording, which the answer
      // model interprets; the detector's own wording is kept when it had one.
      if (result.is_question && !result.question_text) result.question_text = snapshot.newSpeech;
      if (!result.is_question) result.question_text = "";
    }
    used.push("role");
  }
  if (trusted.has("parent") && result.kind === "continuation" && confident(decision.parentConfidence)
      && decision.parent !== "none" && decision.parent !== "unclear") {
    result.related_question_id = decision.parent;
    used.push("parent");
  }
  if (!used.length) return { result: baselineResult, controlledBy: "baseline", fallbackReason: "below confidence floor or not trusted" };
  return { result, controlledBy: `jev:${used.join("+")}`, fallbackReason: null };
}

function baselineDecisionView(baseline) {
  return { kind: baseline.kind, role: baseline.role, parent_id: baseline.parent, confidence: baseline.confidence };
}

function jevView(jev) {
  if (!jev) return {};
  const view = {
    answered_model: jev.model ?? null,
    generation_id: jev.generationID ?? null,
    serving_provider: jev.servingProvider ?? null,
    answer_problems: jev.problems?.length ? jev.problems : undefined,
    latency_ms: jev.latencyMs ?? null,
    attempts: jev.attempts ?? null,
    usage: jev.usage ?? null,
    cost_usd: jev.ok ? typesafe.costUSD(jev.model, jev.usage) : null,
  };
  if (!jev.ok) {
    view.failure = { reason: jev.reason, status: jev.status ?? null, message: jev.message ?? null };
    return view;
  }
  const d = jev.decision;
  return {
    ...view,
    role: d.role,
    role_confidence: d.roleConfidence,
    role_probabilities: d.roleProbabilities,
    parent_id: d.parent,
    parent_asked: d.parentAsked,
    parent_confidence: d.parentConfidence,
    answer_need: d.answerNeed,
    answer_need_confidence: d.answerNeedConfidence,
    transcription_ambiguity: d.transcriptionAmbiguity,
  };
}

function comparisonView(comparison) {
  return { role_agrees: comparison.roleAgrees, parent_agrees: comparison.parentAgrees, disagreements: comparison.disagreements };
}

/** What Jev was shown, against what the app sent. The answer path is independent of both. */
export function contextBoundary(snapshot) {
  const sent = Math.min(snapshot.conversationBefore.length, JEV_CONVERSATION_LINES);
  return {
    conversation_lines_received: snapshot.conversationLinesReceived,
    conversation_lines_before_newest: snapshot.conversationBefore.length,
    conversation_lines_sent_to_jev: sent,
    jev_window_truncated: snapshot.conversationBefore.length > sent,
    known_questions_sent: snapshot.knownQuestions.length,
    answer_request: "unaffected: answers are built from the app's full snapshot, never from this decision input",
  };
}

/** Metadata only. Identifiers are shortened; no conversation text is ever logged. */
export function logLine(record) {
  const j = record.jev ?? {};
  const short = (id) => (id ? String(id).slice(0, 8) : "-");
  const parts = [
    `[decision] ${record.mode}`,
    `session=${short(record.session_id)}`,
    `snapshot=${short(record.snapshot_id)}`,
    `status=${j.status}`,
    `baseline=${record.baseline?.kind ?? "-"}`,
  ];
  if (j.role) parts.push(`jev=${j.role}(${j.role_confidence?.toFixed?.(2) ?? "?"})`);
  if (record.comparison) parts.push(`role_agrees=${record.comparison.role_agrees}`);
  if (j.failure) parts.push(`failure=${j.failure.reason}`);
  if (j.reason) parts.push(`reason="${j.reason}"`);
  if (record.stale) parts.push(`stale="${record.stale_reason}"`);
  if (j.latency_ms !== undefined && j.latency_ms !== null) parts.push(`latency=${j.latency_ms}ms`);
  if (j.usage?.input_tokens) parts.push(`input_tokens=${j.usage.input_tokens}`);
  if (j.answered_model) parts.push(`model=${j.answered_model}`);
  return parts.join(" ");
}
