# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repo contains Bash scripts for deploying a local multi-agent AI company on a fresh Debian 12/13 VM. The stack is: Matrix Synapse (homeserver), Hermes Agent (AI agents, CEO profile `donbot`), Mnemosyne memory (per-agent SQLite fact stores + CEO Obsidian vault with matins/vespers rituals), Element Desktop (Matrix client), Paperclip (optional company control plane, `--with-paperclip`), and an A2A server (optional, CEO-only, `--with-a2a`, port 9900).

## Core Scripts

### launch.sh
One-shot full install. Runs as desktop user (not root), calls `sudo` internally. Idempotent phases can be skipped with `--skip-synapse`, `--skip-hermes`, `--skip-memory`, `--skip-element`; Paperclip is opt-in with `--with-paperclip`. Phase 3.5 installs the memory system (mnemosyne-hermes into the shared Hermes venv, per-profile provider wiring, `~/vault` scaffold, matins/vespers cron rituals for the CEO). Phase 4.6 (opt-in, `--with-a2a`) enables the A2A protocol server on the CEO's default profile: `gateway.platforms.a2a` in `~/.hermes/config.yaml` + `A2A_BEARER_TOKEN`/`A2A_HOST=0.0.0.0` in `~/.hermes/.env` + `hermes tools enable a2a --platform cli` + token example at `~/a2a_bearer_token.env`. The CEO name is set at install time with `--ceo <name>` (default `donbot`); hire.sh and status.sh derive the name from `MATRIX_USER_ID` in `~/.hermes/.env`, so they never need the flag.

### setup_vm.sh
Root-run VM bootstrap (local lab only). `--user <name>` and `--password <pass>` override the default `debian`/`debian` local account (user name, sudoers file, Samba share, smbpasswd all follow); an explicit `--password` on a re-run resets the existing user's password.

### hire.sh
Adds a new AI agent bot. Handles Matrix registration, Hermes profile creation, per-agent Mnemosyne fact store, systemd service install, and Paperclip org chart entry in one pass. Derives the CEO name from `~/.hermes/.env` (launch.sh `--ceo`) for `MATRIX_ALLOWED_USERS`. Strips CEO-only A2A config from cloned profiles (commented `A2A_*` env keys + `gateway.platforms.a2: enabled: false`) — A2A is CEO-only; clones must not bind port 9900.

### fire.sh
Reverses hire.sh for a named bot: stops/removes its gateway service, Hermes profile (including its Mnemosyne fact store), Matrix deactivation, and Paperclip entry.

### cleanup.sh
Tears down the entire stack. `--keep-vault` preserves the company vault; ritual crontab entries are stripped either way.

### status.sh
The company heartbeat: one screen showing Synapse health, every agent gateway state with its memory counts (working/episodic/facts), whether matins/vespers ran, today's vault page, Paperclip if installed, and the A2A agent card if enabled. Exit 0 = healthy, 1 = something down — cron-friendly.

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
- `~/.paperclip/cli/` — Paperclip managed CLI install (optional)
- `~/a2a_bearer_token.env` — A2A bearer token + curl example (chmod 600; deliberately NOT in matrix_credentials.env)
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
| A2A (optional, CEO) | `http://0.0.0.0:9900` — agent card at `/.well-known/agent-card.json`, JSON-RPC tasks at `POST /`, bearer-token protected, LAN-reachable |

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
- GitHub itself intermittently throttles `NousResearch/hermes-agent` (429 on codeload, `info/refs` hangs with no response; other repos unaffected) — launch.sh's clone retries 5× with backoff and a 10-min `timeout` per attempt instead of hanging forever
- hermes-agent's npm package requires **node >=22.22.0** — Debian 13 stock node 20.x fails with EBADENGINE. launch.sh installs Node 22 from NodeSource (arm64 + amd64) and gates on the minimum version
- An interrupted clone (OOM kill / timeout on low-RAM boxes like a Pi 3B+ with ~900MB) leaves `~/.hermes/hermes-agent` as a husk: `.git` with no commits, empty worktree. launch.sh's "already cloned" check validates `pyproject.toml` + a resolvable `HEAD`, and wipes + re-clones if either is missing — otherwise `uv pip install -e` fails with the baffling "does not appear to be a Python project"
- launch.sh caps node's heap (`NODE_OPTIONS=--max-old-space-size=512`) at every npm/npx call site — without it npm's heap growth OOM-kills the whole system on Pi-class hardware (respects a pre-set `NODE_OPTIONS`)
- `@admin` must be registered with `-a` (admin flag) for the Synapse admin API to work
- Paperclip is installed via the managed npm CLI (`npx --yes paperclipai@latest install --yes` + `paperclipai onboard --yes --install-service`), NOT via `paperclip.ing/install.sh` — as of 2026-08-18 that script forwards `--no-prompt` to the CLI, which no longer accepts it, and it force-enables the flag on any non-TTY (scripted) run
- `set -euo pipefail` + password sourcing: always guard with `set +eu` / `set -eu`
- Hermes **refuses a remote A2A bind without a bearer token** — `A2A_BEARER_TOKEN` must be set before `A2A_HOST=0.0.0.0` (launch.sh Phase 4.6 always sets both; token is never rotated on re-run)
- `hermes profile create --clone` copies the default profile's `.env` + `config.yaml`, so hire.sh Step 4/4b strips `A2A_*` env keys and disables the `gateway.platforms.a2a` block in clones — otherwise every hired bot would try to bind port 9900 and collide with the CEO
- The CEO name set by `launch.sh --ceo` is only applied at install time; afterwards hire.sh/status.sh derive it from `MATRIX_USER_ID` in `~/.hermes/.env`, falling back to the `HERMES_CEO_NAME` marker (written by Phase 4 even without Synapse), then `donbot`
- Synapse-less installs work: `launch.sh --skip-synapse --with-a2a --ceo <name>` on a box with no Synapse skips all Matrix wiring (Phase 4 gates registration/room-joins/.env Matrix block on a reachability check against `:8008`) — Hermes + memory + A2A still install. hire.sh does NOT support this mode (it requires a running Synapse); peers reach the CEO over A2A instead
- There is no `hermes mnemosyne setup` subcommand — the installer is the `mnemosyne-hermes` binary in the Hermes venv (`~/.hermes/hermes-agent/venv/bin/mnemosyne-hermes install --hermes-home <dir>`)
- SQLite counts in status.sh open the DBs read-only (`sqlite3 -readonly`) — safe against live WAL writes by running gateways

## Additional Documentation

- `hermes-matrix-setup-guide.md` — Deep-dive reference for every gotcha and config detail
- `ai_docs/plan.md` — Multi-machine federation design (WireGuard mesh, Paperclip as cross-host bus, future Matrix federation)
- `ai_docs/connect-existing-hermes-to-matrix.md` — Wiring two existing Hermes VMs into one shared Synapse
- `matrix-client-setup.md` — Quick Element client setup
- `memory/VAULT_RULES.md` — The vault conventions installed to `~/.hermes/VAULT_RULES.md`
