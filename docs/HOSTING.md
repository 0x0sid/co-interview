# Backend hosting

## Where the code lives

| | |
| --- | --- |
| **Source of truth** | `backend/` in this repository |
| **Deployment mirror** | `~/Desktop/prompter-backend` → `github.com/0x0sid/backend` (private) |
| **Deployed** | Fly app **`backend--d7y3w`**, region `ams`, https://backend--d7y3w.fly.dev |

Fix things in `backend/` first: the iOS tests and `backend/test/` run against it together. Then sync
the mirror and deploy from there:

```bash
cd ~/Desktop/co-interview-public
rsync -a \
  --exclude='.env' --exclude='.env.*' --exclude='node_modules' --exclude='*.log' \
  --exclude='README.md' --exclude='DEPLOYMENT.md' --exclude='.gitignore' \
  --exclude='fly.toml' --exclude='Dockerfile' --exclude='.dockerignore' --exclude='data' \
  backend/ ~/Desktop/prompter-backend/
cp docs/AI_PIPELINE.md ~/Desktop/prompter-backend/docs/
cd ~/Desktop/prompter-backend && npm test && git add -A && git commit && git push
flyctl deploy -a backend--d7y3w          # run by the owner
```

- `README.md`, `DEPLOYMENT.md`, `.gitignore`, `fly.toml`, `Dockerfile` and `.dockerignore` belong to
  the mirror; hence the excludes, and no `--delete`.
- **The Dockerfile copies an explicit file list.** A new top-level module must be added there, or the
  image starts without it and the server crashes on import.
- Pushing from this Mac: HTTPS with the GitHub CLI credential helper
  (`git -c credential.helper='!/opt/homebrew/bin/gh auth git-credential' push https://github.com/…`);
  SSH keys are not set up for the `sid` account.

## Fly configuration

`fly.toml` (in the mirror) sets `HOST=0.0.0.0`, `PORT=8787` with `internal_port = 8787`,
`COPILOT_TEXT_PROVIDER=openrouter`, `COPILOT_PROFILE=balanced`, `COPILOT_DECISION_MODE=shadow`,
`force_https`, and `min_machines_running = 1`. Content diagnostics are off.

**Access database:** SQLite on the volume `neverblank_data`, mounted at `/data`
(`ACCESS_DB_PATH=/data/access.sqlite`). SQLite needs **exactly one machine** — check
`flyctl machine list -a backend--d7y3w` after any scaling change.

**Secrets** (`flyctl secrets set -a backend--d7y3w …`, never committed; local copies in the
git-ignored `backend/.env`):

| Secret | Purpose |
| --- | --- |
| `OPENROUTER_API_KEY` | The model provider (answers, detection, Jev decisions) |
| `REVENUECAT_VERIFY_KEY` | **In use (2026-10-04):** the public `appl_` key, which RevenueCat's v1 subscriber read also accepts; `/health` reports `entitlement_key: public key (interim)` |
| `REVENUECAT_SECRET_KEY` | Preferred when set (it wins over the public key); not set on Fly yet |
| `COINTERVIEW_TOKENS` | Operator tokens for development and evaluation. The app never uses one |

## Health check

`GET /health` must show:

- `provider: configured`, gateway `openrouter`, profile `balanced`;
- `access.entitlement_verification: configured`, `durable_path: true` (`entitlement_key` says which RevenueCat key);
- `decisions.mode: shadow`, `decisions.key_configured: true`.

No key is ever reported. Without a credential, paid routes answer `401`.

## Open security item

**Production still accepts the public example operator token** (checked 2026-10-04) (`replace-with-a-random-token` from
`config.example.env`), which gives anyone who tries it free use of the provider key. Fix:

```bash
flyctl secrets set -a backend--d7y3w COINTERVIEW_TOKENS="$(openssl rand -hex 24)"
```

The app does not use operator tokens, so this does not affect users. Update `backend/.env` and any
evaluation scripts with the new value. Rotation is the owner's decision and has not been done.

## Local backend

```bash
cd backend
COINTERVIEW_TOKENS=dev-token COINTERVIEW_FAKE=1 node server.mjs      # canned answers, no key
```

Details, including a backend reachable from the phone, are in `backend/README.md` and
[`AI_PIPELINE.md`](AI_PIPELINE.md) §10. Debug builds read the host from `COPILOT_DEV_BACKEND_HOST`
(`Local-Debug.xcconfig`, currently the Fly host); Release always uses the production host.
