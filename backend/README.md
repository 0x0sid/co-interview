# Co-Interview copilot backend (development)

The boundary that keeps provider credentials **out of the iOS app**. Two gateways — direct OpenAI
(Responses API) and OpenRouter (Chat Completions) — behind one streaming contract. Nothing here is
deployed, and no credential is stored in this repository.

**Runtime.** No third-party dependencies, which narrows the supply chain but does not mean there is
nothing to audit: this code, the runtime, the credentials it holds and the network it listens on all
still need review. It runs on Node 18+, but Node 18 and 20 are past end-of-life (2025-04-30 and
2026-04-30), so `package.json` declares `>=22` — use Node 22 (Jod) or 24 (Krypton). **The suites here
were last run on Node v18.16.0**, the version installed on the development machine; re-run them on a
supported LTS before relying on the results.

| File | Purpose |
|---|---|
| `server.mjs` | Routes, auth, limits, timeouts, cancellation, fallback, SSE, development fake |
| `config.mjs` | Profiles, configuration precedence, validation, reasoning and routing translation |
| `capabilities.mjs` | Verified model/route registry (slugs, structured outputs, reasoning, limits) |
| `providers/openai.mjs`, `providers/openrouter.mjs` | The two upstream adapters |
| `tools/verify-routes.mjs` | Re-checks the registry against OpenRouter's live catalogue (no credential) |
| `test/*.mjs` | Configuration, OpenAI contract, OpenRouter contract (all against local stubs) |
| `eval/run-eval.mjs`, `eval/scenarios.json` | Benchmark harness and synthetic English/French scenarios |

## Run it

```bash
cd backend

# 1. Development, no credentials: canned answers, clearly labelled everywhere they appear.
COINTERVIEW_TOKENS=dev-token COINTERVIEW_FAKE=1 node server.mjs

# 2. Direct OpenAI. Your key stays in your shell — never in the repository or the app.
COINTERVIEW_TOKENS=dev-token OPENAI_API_KEY=sk-... node server.mjs

# 3. OpenRouter, balanced profile (Gemini 2.5 Flash-Lite via Google AI Studio).
COINTERVIEW_TOKENS=dev-token OPENROUTER_API_KEY=sk-or-... \
  COPILOT_TEXT_PROVIDER=openrouter COPILOT_PROFILE=balanced node server.mjs

# Checks (no credential needed):
npm test                  # configuration + both provider contracts, against local stubs
npm run verify-routes     # registry vs OpenRouter's live catalogue
```

From a **physical iPhone**, `127.0.0.1` means the phone. Bind to the LAN and use the Mac's address:

```bash
ipconfig getifaddr en0    # e.g. 192.168.1.42
COINTERVIEW_TOKENS=$(openssl rand -hex 24) OPENROUTER_API_KEY=sk-or-... \
  COPILOT_TEXT_PROVIDER=openrouter HOST=0.0.0.0 node server.mjs
```

iOS will ask for local-network permission, and plain HTTP to a LAN address needs an App Transport
Security exception that is **deliberately not configured** — see
`docs/CO_INTERVIEW_AI_PIPELINE.md` §10 for the options. The Simulator needs none.

Then in the app: **Debug → Debug: Copilot**, set the backend URL (`http://127.0.0.1:8787` in the
Simulator) and the same token.

## Live mode from the v2.5 interview screen (2026-09-19)

The interview screen now runs against this backend. What it sends is unchanged except for one field:
`extraContext`, the note the user typed in the Context panel, framed in the prompt as **reference
material, not instructions**. Attached images are **not** sent — the route is text-only, and the app
says so in the Context panel rather than implying the model read them.

### The one file to edit

Put the provider key in **`backend/.env`** — created by you, git-ignored, read automatically at
startup (the server has a small built-in loader, since Node's own `--env-file` needs 20.6+):

```bash
cd backend
cp config.example.env .env      # then edit .env and set OPENROUTER_API_KEY=
```

Only two lines are needed for OpenRouter:

```
OPENROUTER_API_KEY=sk-or-...
COPILOT_TEXT_PROVIDER=openrouter
```

An exported shell variable always wins over the file, so `OPENROUTER_API_KEY=... node server.mjs`
still behaves as documented. The startup banner reports the file path and how many values it loaded —
**never a value**.

```bash
cd backend
# One token for the app, one credential for the provider. Different secrets, different parties.
COINTERVIEW_TOKENS=$(openssl rand -hex 24) \
  OPENROUTER_API_KEY=sk-or-... \
  COPILOT_TEXT_PROVIDER=openrouter COPILOT_PROFILE=balanced \
  HOST=0.0.0.0 node server.mjs
```

Then in the app: **Debug → Debug: Copilot**, set the backend URL to the Mac's LAN address
(`ipconfig getifaddr en0`, e.g. `http://192.168.1.42:8787`) and paste the same `COINTERVIEW_TOKENS`
value as the access token. **Never** the provider key: the app never holds one.

**The HTTP exception is Debug-only.** `NSAllowsLocalNetworking` lives in
`prompter/Resources/Info-Debug.plist`, which only the Debug configuration uses; the Release
configuration uses `Info.plist`, which does not carry it. `NSAllowsArbitraryLoads` is never set in
either, so public connections always require HTTPS. `InfoPlistConfigurationTests` fails the build if
a Release plist ever gains the exception, or if the two plists drift apart in any other key.

`Interview Copilot → Start live` then reports what is actually ready. Listening and generation are
independent — with no provider credential the session still transcribes and detects questions, and
says "answers unavailable" instead of refusing to start.

## HTTPS for device testing (ngrok)

The phone needs HTTPS or a LAN exception. ngrok gives the first, which is why it does **not** depend
on the Debug-only LAN plist — that stays as an optional fallback.

```bash
# 1. Backend on loopback (HOST=127.0.0.1 in .env is correct for this).
cd backend && node server.mjs

# 2. Tunnel, with traffic inspection OFF so request bodies — transcripts and image
#    attachments — are not retained by the agent.
ngrok http 8787 --inspect=false

# Shut down, in either order:
#   Ctrl-C in each window, or:
pkill -f "ngrok http"; pkill -f "node server.mjs"
```

`ngrok http 8787` prints the HTTPS forwarding URL. Enter **that** URL in the app under
**Debug → Debug: Copilot**, with the same client token from `COINTERVIEW_TOKENS`. The URL changes
every time the agent restarts on the free plan, so re-enter it after a restart.

**Authentication still applies through the tunnel.** The URL is public; `COINTERVIEW_TOKENS` is what
keeps it from being an open proxy. Verified: unauthenticated and wrong-token requests to
`/v1/copilot/answer` and `/v1/copilot/classify` return 401 through the public URL.

ngrok changes **reachability, not speed** — it adds a network hop, so it can only make a request
slower than the same request on the LAN. It has nothing to do with capturing call audio, which no
iOS API permits from a third-party app.

### Tests never read your `.env`

`backend/.env` is loaded only when `COINTERVIEW_NO_ENV_FILE` is unset. Every test harness sets it to
`1`, because a developer's real key leaking into a suite broke the OpenAI contract test — and could
have let a test make a real, billed provider call.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `COINTERVIEW_TOKENS` | *(none)* | Comma-separated bearer tokens. **Without it the server refuses every request** — it is never an open proxy |
| `OPENAI_API_KEY` | *(none)* | Provider credential. Without it (and without `COINTERVIEW_FAKE`) the endpoints answer `503 provider_unconfigured`, which the app shows as an honest unavailable state |
| `OPENROUTER_API_KEY` | *(none)* | Provider credential for the OpenRouter gateway |
| `COINTERVIEW_FAKE` | *(unset)* | `1` enables the development fake provider. Its output is marked `is_fake` and prefixed `[FAKE]`/`[FAUX]` |
| `COINTERVIEW_ALLOW_REQUEST_OVERRIDES` | *(unset)* | `1` lets a request carry configuration overrides — for the local benchmark harness only |
| `COPILOT_TEXT_PROVIDER` | `openai` | `openai` or `openrouter` |
| `extraContext` *(request field)* | `""` | The session note from the Context panel. Clipped to 1000 characters and framed as reference material |
| `COPILOT_PROFILE` | `balanced` | `speed`, `balanced`, `smart`, `custom` (OpenRouter only) |
| `COPILOT_*` | see `config.mjs` | Every configuration key is overridable this way; all are validated |
| `PORT` / `HOST` | `8787` / `127.0.0.1` | Bind address. Loopback by default |
| `MAX_BODY_BYTES` | `65536` | Request size limit |
| `REQUEST_TIMEOUT_MS` | `20000` | Upstream timeout; the client disconnecting also aborts upstream |

## Endpoints

| Route | Purpose |
|---|---|
| `GET /health` | Reports provider and auth configuration. The only unauthenticated route |
| `POST /v1/copilot/classify` | Question detection. Structured output (`text.format` = `json_schema`, `strict: true`) with `kind` ∈ `none` / `incomplete` / `new_question` / `continuation` |
| `POST /v1/copilot/answer` | Streamed answer as SSE: `{type:"delta",text}`, then `{type:"sources",ids}`, then `{type:"done"}`; `{type:"error",message}` on failure |

The answer endpoint accepts an allowlisted `model` override so the evaluation harness can compare
candidates on identical prompts; clients cannot point it at arbitrary models.

## What it deliberately does not do

- **No content logging.** Request lines carry method, path, status and duration only.
- **No storage.** No database, no files, no transcript or document retention.
- `store: false` on every provider request, so no response is retained as provider application state
  (abuse-monitoring retention still applies — see `docs/CO_INTERVIEW_AI_PIPELINE.md` §8).
- No user accounts, rate limiting beyond the provider's own, TLS termination, or deployment
  configuration. Those belong to a real deployment decision, which has not been made.
