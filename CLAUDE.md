# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repo contains Bash scripts for deploying a local multi-agent AI company on a fresh Debian 12/13 VM. The stack is: Matrix Synapse (homeserver), Hermes Agent (AI agents), Element Desktop (Matrix client), and Paperclip (company control plane).

## Core Scripts

### launch.sh
One-shot full install. Runs as desktop user (not root), calls `sudo` internally. Idempotent phases can be skipped with `--skip-synapse`, `--skip-hermes`, `--skip-element`, `--skip-paperclip`.

### hire.sh
Adds a new AI agent bot. Handles Matrix registration, Hermes profile creation, systemd service install, and Paperclip org chart entry in one pass.

## Key Conventions

**Shell hygiene:** Both scripts use `set -euo pipefail`. When sourcing credential files, wrap with `set +eu` / `set -eu` because passwords can contain `$` characters that Bash would otherwise expand.

**Credential handling:** All passwords and room IDs accumulate in `~/Downloads/matrix_credentials.env`. Password keys follow `MATRIX_<BOTNAME_UPPERCASED>=`. The registration shared secret is stored as `SYNAPSE_REG_SHARED_SECRET`. `gen_password()` uses Python's `secrets` module to produce 28-char passwords with special characters.

**Bot naming:** Bot names are forced to lowercase: `BOT_NAME="${1,,}"`. Valid pattern: `^[a-z][a-z0-9_-]*$`. Convention: names end in `bot` (e.g. `arcbot`, `writerbot`, `engineerbot`). Each bot's Hermes CLI command is just its name: `writerbot chat -q "..."`.

**MATRIX_ALLOWED_USERS propagation:** Every time a new bot is provisioned, its Matrix ID must be appended to `MATRIX_ALLOWED_USERS` in all existing profile `.env` files (default + every profile under `profiles/`). hire.sh step 6 does this with a Python heredoc glob scan.

**Embedded Python:** Python `<< PYEOF` heredocs are used for Matrix API calls and `.env` file manipulation (regex-based key upsert pattern). The Matrix API is called directly via `urllib.request` — no third-party libraries.

**Systemd services:** Default ArcBot gateway: `hermes-gateway` (user service). Per-bot pattern: `hermes-gateway-<botname>` (user service). All services use `Restart=on-failure`, `RestartSec=30`, `KillMode=mixed`. `loginctl enable-linger` ensures user services survive reboot without login.

**Logging helpers** (defined in both scripts):
- `log()` green [✓] — success
- `info()` blue [→] — step in progress
- `warn()` yellow [!] — non-fatal issue
- `error()` red [✗] — fatal, exits 1

## Runtime Locations (outside this repo)

- `~/.hermes/` — Hermes home: default profile `.env`, `config.yaml`, `SOUL.md`, `hermes-agent/` (cloned source + Python venv), `profiles/<botname>/`
- `~/paperclip/` — Paperclip source clone
- `~/Downloads/matrix_credentials.env` — All generated passwords and room IDs (source of truth for secrets)
- `/etc/matrix-synapse/` — Synapse config
- `~/.config/systemd/user/hermes-gateway-<botname>.service` — Per-bot gateway services

## Coordination Rooms

All bots join these 5 rooms automatically during provisioning:

| Alias | Purpose |
|-------|---------|
| `#general:localhost` | Main agent coordination |
| `#tasks:localhost` | Task assignment |
| `#results:localhost` | Agent output |
| `#status:localhost` | Health / heartbeat |
| `#memory:localhost` | Shared knowledge |

Room IDs (not aliases) are stored in `matrix_credentials.env` as `MATRIX_ROOM_*` keys. Bot joins use the Synapse admin API (`/_synapse/admin/v1/join/{room_id}`), not the standard client join — this is intentional to bypass invite requirements.

## Key Ports & Endpoints

| Service | URL |
|---------|-----|
| Matrix Synapse | `http://127.0.0.1:8008` |

## Operational Commands

```bash
# Check services
systemctl is-active matrix-synapse
systemctl --user is-active hermes-gateway
systemctl --user is-active hermes-gateway-<botname>

# Logs
journalctl --user -u hermes-gateway -f
journalctl --user -u hermes-gateway-<botname> -f

# Hermes CLI
hermes chat                          # Talk to ArcBot (default profile)
hermes chat -q "..."                # Non-interactive
<botname> chat -q "..."              # Talk to a specific bot
hermes profile list                  # List all profiles
hermes auth                          # Connect LLM provider
hermes model                         # Configure model

# Restart a gateway
systemctl --user restart hermes-gateway-<botname>
```

## Known Gotchas (already handled in scripts)

- `hermes.nousresearch.com` returns 429 — scripts clone Hermes directly from GitHub
- `@admin` must be registered with `-a` (admin flag) for the Synapse admin API to work
- Paperclip requires `@paperclipai/plugin-sdk` to be built (`pnpm --filter @paperclipai/plugin-sdk build`) before first launch
- `set -euo pipefail` + password sourcing: always guard with `set +eu` / `set -eu`

## Additional Documentation

- `hermes-matrix-setup-guide.md` — Deep-dive reference for every gotcha and config detail
- `ai_docs/plan.md` — Multi-machine federation design (WireGuard mesh, Paperclip as cross-host bus, future Matrix federation)
- `matrix-client-setup.md` — Quick Element client setup