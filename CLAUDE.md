# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repo contains Bash scripts for deploying a local multi-agent AI company on a fresh Debian 12/13 VM. The stack is: Matrix Synapse (homeserver), Hermes Agent (AI agents, CEO profile `donbot`), Mnemosyne memory (per-agent SQLite fact stores + CEO Obsidian vault with matins/vespers rituals), Element Desktop (Matrix client), and Paperclip (optional company control plane, `--with-paperclip`).

## Core Scripts

### launch.sh
One-shot full install. Runs as desktop user (not root), calls `sudo` internally. Idempotent phases can be skipped with `--skip-synapse`, `--skip-hermes`, `--skip-memory`, `--skip-element`; Paperclip is opt-in with `--with-paperclip`. Phase 3.5 installs the memory system (mnemosyne-hermes into the shared Hermes venv, per-profile provider wiring, `~/vault` scaffold, matins/vespers cron rituals for the CEO).

### hire.sh
Adds a new AI agent bot. Handles Matrix registration, Hermes profile creation, per-agent Mnemosyne fact store, systemd service install, and Paperclip org chart entry in one pass.

### fire.sh
Reverses hire.sh for a named bot: stops/removes its gateway service, Hermes profile (including its Mnemosyne fact store), Matrix deactivation, and Paperclip entry.

### cleanup.sh
Tears down the entire stack. `--keep-vault` preserves the company vault; ritual crontab entries are stripped either way.

### status.sh
The company heartbeat: one screen showing Synapse health, every agent gateway state with its memory counts (working/episodic/facts), whether matins/vespers ran, today's vault page, and Paperclip if installed. Exit 0 = healthy, 1 = something down — cron-friendly.

## Key Conventions

**Shell hygiene:** All scripts use `set -euo pipefail` (status.sh deliberately omits `-e` — failing checks are its output). When sourcing credential files, wrap with `set +eu` / `set -eu` because passwords can contain `$` characters that Bash would otherwise expand.

**Credential handling:** All passwords and room IDs accumulate in `~/Downloads/matrix_credentials.env`. Password keys follow `MATRIX_<BOTNAME_UPPERCASED>=`. The registration shared secret is stored as `SYNAPSE_REG_SHARED_SECRET`. `gen_password()` uses Python's `secrets` module to produce 28-char passwords with special characters.

**Bot naming:** Names come from the Futurama robot pool in `names/futurama_robots.txt` (310 unique snake_case names). If `hire.sh` is called without a name, one is drawn at random from the pool; explicit names always win. Valid pattern: `^[a-z][a-z0-9_-]*$`. Names are lowercase (`BOT_NAME="${1,,}"`).

**Memory architecture (three tiers):**
1. Hot memory — Hermes built-in MEMORY.md/USER.md (what's in the agent's context)
2. Mnemosyne fact store — per-agent SQLite at `~/.hermes/profiles/<name>/mnemosyne/data/mnemosyne.db` (default profile/Donbot: `~/.hermes/mnemosyne/data/mnemosyne.db`). Wired via `memory.provider: mnemosyne` + `mnemosyne.data_dir` in each profile's config.yaml. The CLI is `mnemosyne-hermes` (lives in the Hermes venv; idempotent installer).
3. The vault — Obsidian Markdown at `~/vault`, CEO only. Daily pages, issues log, projects. Kept alive by `matins.sh` (06:50 weekdays) and `vespers.sh` (22:00 daily) cron rituals that prompt the CEO to open/close each day's page.

**MATRIX_ALLOWED_USERS propagation:** Every time a new bot is provisioned, its Matrix ID must be appended to `MATRIX_ALLOWED_USERS` in all existing profile `.env` files (default + every profile under `profiles/`). hire.sh does this with a Python heredoc glob scan.

**Embedded Python:** Python `<< PYEOF` heredocs are used for Matrix API calls and `.env`/config.yaml manipulation (regex-based key upsert pattern). The Matrix API is called directly via `urllib.request` — no third-party libraries.

**Systemd services:** Default (Donbot/CEO) gateway: `hermes-gateway` (user service). Per-bot pattern: `hermes-gateway-<botname>` (user service). All services use `Restart=on-failure`, `RestartSec=30`, `KillMode=mixed`. `loginctl enable-linger` ensures user services survive reboot without login.

**Logging helpers** (launch/hire/fire/cleanup):
- `log()` green [✓] — success
- `info()` blue [→] — step in progress
- `warn()` yellow [!] — non-fatal issue
- `error()` red [✗] — fatal, exits 1

## Runtime Locations (outside this repo)

- `~/.hermes/` — Hermes home: default profile `.env`, `config.yaml`, `SOUL.md`, `hermes-agent/` (cloned source + Python venv with mnemosyne-hermes), `rituals/` (matins.sh, vespers.sh), `profiles/<botname>/`
- `~/.hermes/profiles/<name>/mnemosyne/data/mnemosyne.db` — per-agent fact stores
- `~/vault/` — the company vault (Obsidian): Daily/, Projects/, System/, Inbox/, People/, Work/, Personal/
- `~/rituals.log` — matins/vespers output (cron)
- `~/paperclip/` — Paperclip source clone (optional)
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
| Paperclip (optional) | `http://127.0.0.1:3100` |

## Operational Commands

```bash
# One-screen company heartbeat
bash status.sh

# Check services
systemctl is-active matrix-synapse
systemctl --user is-active hermes-gateway
systemctl --user is-active hermes-gateway-<botname>

# Logs
journalctl --user -u hermes-gateway -f
journalctl --user -u hermes-gateway-<botname> -f

# Hermes CLI
hermes chat                          # Talk to Donbot (CEO, default profile)
hermes chat -q "..."                # Non-interactive
hermes profile list                  # List all profiles
hermes model                         # Configure model
hermes memory status                 # Active memory provider (current profile)

# Restart a gateway
systemctl --user restart hermes-gateway-<botname>
```

## Known Gotchas (already handled in scripts)

- `hermes.nousresearch.com` returns 429 — scripts clone Hermes directly from GitHub
- `@admin` must be registered with `-a` (admin flag) for the Synapse admin API to work
- Paperclip requires `@paperclipai/plugin-sdk` to be built (`pnpm --filter @paperclipai/plugin-sdk build`) before first launch
- `set -euo pipefail` + password sourcing: always guard with `set +eu` / `set -eu`
- There is no `hermes mnemosyne setup` subcommand — the installer is the `mnemosyne-hermes` binary in the Hermes venv (`~/.hermes/hermes-agent/venv/bin/mnemosyne-hermes install --hermes-home <dir>`)
- SQLite counts in status.sh open the DBs read-only (`sqlite3 -readonly`) — safe against live WAL writes by running gateways

## Additional Documentation

- `hermes-matrix-setup-guide.md` — Deep-dive reference for every gotcha and config detail
- `ai_docs/plan.md` — Multi-machine federation design (WireGuard mesh, Paperclip as cross-host bus, future Matrix federation)
- `ai_docs/connect-existing-hermes-to-matrix.md` — Wiring two existing Hermes VMs into one shared Synapse
- `matrix-client-setup.md` — Quick Element client setup
- `memory/VAULT_RULES.md` — The vault conventions installed to `~/.hermes/VAULT_RULES.md`
