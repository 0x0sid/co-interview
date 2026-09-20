# Hosting the backend, and moving the app's endpoint to it

The backend is published standalone at **`VRAM-AI/prompter-backend`** for deployment. The
authoritative source stays `backend/` in this repository; see "Which copy is authoritative" below.

**Nothing here has been deployed.** No Railway service exists yet, no hosted URL is baked into the
app, and the working ngrok setup is untouched and still in use.

## Which copy is authoritative

| | |
| --- | --- |
| **Source of truth** | `backend/` in this repository (`0x0sid/co-interview`) |
| **Published mirror** | `VRAM-AI/prompter-backend`, repository root |

Fixes are made **here** first, because the backend's contract tests run alongside the iOS tests that
depend on it — `prompterTests/Diagnostics/DiagnosticsIntegrationTests` drives the real server, and
`backend/test/contract-test.mjs` asserts the prompt structure the app relies on. A change made only
in the mirror would pass there and break the app here.

To synchronize after a backend change:

```bash
cd ~/Desktop/co-interview-public
rsync -a --delete \
  --exclude='.env' --exclude='.env.*' --exclude='node_modules' --exclude='*.log' \
  backend/ ~/Desktop/prompter-backend/
cp docs/CO_INTERVIEW_AI_PIPELINE.md ~/Desktop/prompter-backend/docs/
cd ~/Desktop/prompter-backend && npm test && git add -A && git commit && git push
```

`README.md` and `DEPLOYMENT.md` in the mirror are its own files — `--delete` would remove them, so
either keep the two excludes above or restore them after syncing. This is a copy, not a subtree
split; if that becomes painful, promote the mirror to source of truth and record it here.

## Railway setup

Exact steps. Nothing below requires sharing a credential in chat.

1. **Connect the repository.** Railway → *New Project* → *Deploy from GitHub repo* →
   **`VRAM-AI/prompter-backend`**, branch `main`. The repository is private; authorize Railway for
   the `VRAM-AI` organization if it is not already.
2. **Build and start.**
   - Build command: **leave empty**. There are no dependencies and nothing to compile.
   - Start command: **`npm start`** (which is `node server.mjs`). Railway also picks this up from
     `package.json` on its own.
   - Node version: **22 or 24**. `package.json` declares `"engines": { "node": ">=22" }`; set
     `NODE_VERSION=22` in the service variables if Railway selects an older default.
3. **Environment variables** — Railway → the service → *Variables*. Names are exactly what the code
   already reads; do not rename them.

   | Variable | Value |
   | --- | --- |
   | `COINTERVIEW_TOKENS` | **A fresh random token you generate.** Not the placeholder — see the warning below |
   | `OPENROUTER_API_KEY` | Your OpenRouter key (or `OPENAI_API_KEY` with `COPILOT_TEXT_PROVIDER=openai`) |
   | `HOST` | `0.0.0.0` |
   | `COPILOT_BACKEND_VERSION` | Optional, e.g. the deployed commit — it shows up in diagnostics |

   `PORT` is injected by Railway and read automatically. **Do not set** `COPILOT_DIAGNOSTICS`,
   `COINTERVIEW_FAKE` or `COINTERVIEW_ALLOW_REQUEST_OVERRIDES` on a hosted service.

   Generate a token locally with `openssl rand -hex 24` and paste it into Railway's *Variables*.
4. **Get the hostname.** Railway → the service → *Settings* → *Networking* → *Generate Domain*. That
   produces `something.up.railway.app`, served over HTTPS. **That hostname does not exist until you
   do this**, which is why none is written into the app.
5. **Verify before switching the app.** The exact curl sequence — health, 401 without a token,
   authenticated classification, streamed generation, and cancellation — is in
   [`DEPLOYMENT.md`](https://github.com/VRAM-AI/prompter-backend/blob/main/DEPLOYMENT.md) in the
   backend repository. Streaming is the one to watch: text must arrive in pieces, not as one block
   at the end. A proxy that buffers would break the product without failing any request.

> **The current client token is the documented placeholder.** `backend/.env` still has
> `COINTERVIEW_TOKENS=replace-with-a-random-token`, the literal example value that is public in
> `config.example.env`. On a loopback backend behind an ad-hoc tunnel that is survivable; on a public
> hosted URL it is an open proxy to your provider credits for anyone who guesses the hostname.
> **Generate a real token as part of this move**, and update both the service and the app.

## Moving the app's endpoint

### One configuration source

`ProviderConfiguration.resolve` picks the base URL from exactly three places, highest first, and the
debug screen now prints **which one won** under "Backend configured":

| Source | Where it comes from | Use |
| --- | --- | --- |
| `saved setting` | typed in **Debug → Debug: Copilot** | trying an endpoint without rebuilding |
| `build configuration` | `CopilotBackendURL` in `Info.plist` | how a real build ships pointed at a service |
| `development default` | git-ignored `prompter/Config/Local-Debug.xcconfig` | the local/ngrok loop |

### A dead tunnel can no longer win silently

A saved setting outranks the build — that is what makes it useful. But a saved **ngrok** URL from a
previous session is not a choice anyone is still making: the tunnel is gone. `resolve` now ignores a
saved URL when it is an ephemeral tunnel host *and* the build points at a different host
(`isSupersededDevelopmentURL`). A saved URL for a real service, or for the same tunnel the build
uses, is still honoured exactly as before.

This is the failure it prevents, which already happened once here: the backend was healthy, the build
carried the current tunnel, and the app still talked to a dead hostname saved days earlier.

Nothing else in the app's settings or data is touched — no defaults are cleared, no reinstall is
needed, and unrelated preferences are preserved.

### The switch, when the hosted service has passed verification

1. Put the hostname in the app's own configuration, **not** a saved setting, so it survives a reinstall
   and has one source. For a Debug build, edit the git-ignored
   `prompter/Config/Local-Debug.xcconfig`:

   ```
   COPILOT_DEV_BACKEND_HOST = your-service.up.railway.app
   COPILOT_DEV_BACKEND_TOKEN = <the token you set in Railway>
   ```

   The host is stored **without a scheme** — xcconfig treats `//` as a comment and would silently
   truncate `https://…`. The app prepends `https://`. For a Release build, set `CopilotBackendURL` in
   `Info.plist` instead.
2. Rebuild and install over the top. Do not uninstall: app data and settings are preserved.
3. In **Debug → Debug: Copilot**, confirm the status line reads the Railway host and
   `from: development default` (or `build configuration`). If it still shows a tunnel, a saved
   setting is in effect — clear the URL field in that screen.
4. Run one live Generate and confirm the answer streams.

### Rolling back

The ngrok setup is unchanged and stays usable throughout. To go back:

1. Restore the previous `COPILOT_DEV_BACKEND_HOST` (the ngrok hostname) and token in
   `Local-Debug.xcconfig`, rebuild, install over the top; **or**
2. Without rebuilding, type the ngrok URL and token into **Debug → Debug: Copilot**. A saved setting
   for the current tunnel is honoured — the superseded-tunnel rule only ignores a saved host that
   differs from the one the build carries.

Keep ngrok running until the hosted service has passed the verification in step 5 above.

### What the phone holds

Only the **client token** for the backend, plus the base URL. The provider key
(`OPENROUTER_API_KEY` / `OPENAI_API_KEY`) is never in the app: it lives in `backend/.env` locally and
in Railway's variables once hosted. `InfoPlistConfigurationTests.neitherPlistCarriesAProviderCredential`
asserts the absence by shape, so a future key added carelessly fails the build's tests.
