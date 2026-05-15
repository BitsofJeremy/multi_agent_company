# Multi-Agent Company

> Spin up a fully autonomous AI company on a Debian VM in one command. Real agents. Real coordination. Zero drama.

**Stack:** Matrix Synapse · Ollama · Hermes Agent · MemPalace · Element Desktop

Your agents run as independent systemd services, each with its own Futurama robot persona, LLM model, skill set, and memory palace. **Donbot** (your CEO — a smooth-talking Robot Mafia don) is the only agent who talks to you via Matrix. All peer-agent task delegation flows through Matrix coordination rooms. Add or remove agents anytime.

```bash
git clone https://github.com/BitsofJeremy/multi_agent_company.git
cd multi_agent_company
bash launch.sh
```

---

## What You Get

| Component | Details |
|-----------|---------|
| **Matrix Synapse** | Private homeserver at `http://0.0.0.0:8008` — LAN-reachable; use `http://<VM-IP>:8008` from other devices |
| **Hermes Agent** | Donbot (CEO) as your default profile, connected to Matrix — inference provider set via `hermes model` |
| **MemPalace** | Local-first AI memory — every agent gets its own palace under `~/.mempalace/data/` |
| **Element Desktop** | Your window into the Matrix — chat with Donbot directly |
| **Hermes Intelligence Corp** | Pre-configured company with Donbot as founding CEO |

---

## Quick Start

### 1. Clone & launch

```bash
git clone https://github.com/BitsofJeremy/multi_agent_company.git
cd multi_agent_company
bash launch.sh
```

Run as your **desktop user** (not root). The script calls `sudo` internally only where needed.

**After install:**

```bash
# 1. Configure your inference provider:
hermes model   # follow the prompts to choose your provider and model

# 2. Talk to Donbot (CEO)
hermes chat

# 3. Open Element → sign in to http://localhost:8008 as @admin:localhost / changeme
element-desktop
```

Matrix Synapse and Ollama bind to `0.0.0.0` so they're reachable from your LAN.
Element can connect to `http://<VM-IP>:8008` from any machine on your network.

> **VPS / public hosting?** Add Nginx in front to terminate TLS — see the TODO comments
> inside `launch.sh` near the Synapse listener config for the exact nginx snippet.

Credentials are saved to: `~/Downloads/matrix_credentials.env`

---

### 2. Already have some pieces? Skip phases.

```bash
bash launch.sh --skip-synapse     # Synapse already installed
bash launch.sh --skip-hermes      # Hermes already installed
bash launch.sh --skip-mempalace   # MemPalace already installed
bash launch.sh --skip-element     # Element already installed
```

---

### 3. Hire a new agent

```bash
bash hire.sh [botname] [OPTIONS]
```

`botname` is **optional**. If omitted, a random Futurama robot name is chosen automatically
(e.g. `flexo`, `calculon`, `tinny_tim`). Explicit names always win.

**Options:**

| Flag | Description |
|------|-------------|
| `--title "CTO"` | Job title for the agent |
| `--model "minimax-m2.7:cloud"` | LLM model for the profile |
| `--soul "You are..."` | Custom SOUL.md personality |
| `--skill <name>` | Install a skill (repeatable) |
| `--no-memory` | Opt out of MemPalace memory palace |
| `--no-gateway` | Skip systemd gateway service |

**Available skills (`--skill`):**

| Name | What it adds |
|------|-------------|
| `gd-agentic` | Godot 4 mastery skill set (94 skills) |
| `story` | End-to-end story writing (characters, worlds, plots, chapters) |
| `pixel` | Pixel art creation + animation via Aseprite MCP |
| `blender-mcp` | Blender 3D integration skills |
| `find-skills` | Skill discovery and marketplace navigation |
| `hire-fire` | **Donbot built-in** — hire/fire agents via `hire.sh` / `fire.sh` (auto Futurama name) |

**Examples:**

```bash
# Hire a random Futurama-named Technical Writer with story-writing skills
bash hire.sh --title "Technical Writer" --skill story --skill find-skills

# Hire a named CTO with a custom personality and bigger budget
bash hire.sh engineerbot \
  --title "Chief Technology Officer" \
  --budget 8000 \
  --skill gd-agentic \
  --soul "You are EngineerBot — precise, systematic, relentlessly focused on quality."

# Hire a pixel art agent (auto-named by hire.sh, e.g. 'calculon')
bash hire.sh --title "Creative Director" --skill pixel --skill blender-mcp

# Register a research agent with no memory
bash hire.sh --title "Research Analyst" \
  --no-memory \
  --no-gateway
```

> **Donbot can hire agents autonomously** via his built-in `HIRE_FIRE` skill.
> When Donbot runs `hire.sh` he never passes a name — he lets the script
> auto-assign a Futurama robot name.

**What `hire.sh` does under the hood:**
1. Picks a Futurama robot name (if no name given)
2. Registers `@<botname>:localhost` in Matrix
3. Joins bot to all 5 coordination rooms (`#general`, `#tasks`, `#results`, `#status`, `#memory`)
4. Creates Hermes profile (`hermes profile create <name> --clone`)
5. Writes Matrix credentials into the profile `.env` (MATRIX_ALLOWED_USERS locked to admin + Donbot)
6. Writes `SOUL.md` personality file
7. Sets the model in `config.yaml` (if `--model` given)
8. Clones and installs selected skills into `~/.hermes/profiles/<name>/skills/`
9. Initialises MemPalace palace at `~/.mempalace/data/<name>/` (unless `--no-memory`)
10. Installs + starts `hermes-gateway-<name>.service` (systemd user service)

---

## Matrix Accounts

| User | Matrix ID | Role |
|------|-----------|------|
| You | `@admin:localhost` | Human operator (admin) |
| Donbot | `@donbot:localhost` | Default Hermes profile (CEO) — only agent who talks to you via Matrix |
| Any hired agent | `@<botname>:localhost` | Added via `hire.sh`; talks only via Paperclip |

**Default password:** `@admin:localhost` / `changeme`
All bot passwords are auto-generated and stored in `~/Downloads/matrix_credentials.env`.

> **Routing model:** Donbot is the only agent in your `MATRIX_ALLOWED_USERS`. Hired bots join
> the coordination rooms but their gateways will not respond to your Matrix messages — only Donbot
> does. Donbot delegates tasks to peer agents through Matrix coordination rooms.
> Existing `@arcbot` installs from before this update continue to work — just note that fresh
> installs use `@donbot`. To migrate, run `launch.sh` on a clean VM or manually rename the profile.

---

## Coordination Rooms

Five rooms are created automatically. Every agent joins all of them.

| Alias | Purpose |
|-------|---------|
| `#general:localhost` | Main coordination — where the company thinks out loud |
| `#tasks:localhost` | Task assignment and delegation |
| `#results:localhost` | Agent output and deliverables |
| `#status:localhost` | Health checks and heartbeats |
| `#memory:localhost` | Shared knowledge and context |

---

## Day-to-Day Commands

```bash
# Check all services
systemctl is-active matrix-synapse
systemctl --user is-active hermes-gateway

# Watch Donbot's live feed
journalctl --user -u hermes-gateway -f

# Watch a specific agent
journalctl --user -u hermes-gateway-flexo -f

# Bounce a gateway after config changes
systemctl --user restart hermes-gateway
systemctl --user restart hermes-gateway-flexo

# See all Hermes profiles
hermes profile list

# Chat with Donbot (CEO — the only agent you talk to directly)
hermes chat

# MemPalace — mine context and search memories
mempalace mine ~/projects/myapp
mempalace search "why did we change the architecture"
mempalace wake-up
```

---

## Files

| File | Purpose |
|------|---------|
| `launch.sh` | One-shot install — run once on a fresh VM |
| `hire.sh` | Add a new agent to the company |
| `ai_docs/plan.md` | Multi-machine federation design notes for future implementers |
| `hermes-matrix-setup-guide.md` | Deep-dive reference — every gotcha, every config detail |
| `matrix-client-setup.md` | Quick Element client setup |

---

## Known Issues & Fixes

Everything below is already handled by the scripts — documented here so you know why.

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| `hermes.nousresearch.com` returns 429 | CDN rate limit | Scripts clone Hermes directly from GitHub |
| `_synapse/admin/v1/join` returns 403 | Admin registered without `-a` flag | Scripts use `-a` from day one |
| Passwords with `$` break `set -euo pipefail` | Bash expands `$` in sourced files | Scripts wrap credential sourcing with `set +eu` / `set -eu` |
| Bot gateway responds to other bots in Matrix | `MATRIX_ALLOWED_USERS` was too broad | hire.sh now locks each bot's allowed list to `@admin + @donbot` only |

---

## Directory Structure (after install)

```
~/.hermes/
├── .env                    # Donbot config — Matrix, Ollama, MemPalace credentials
├── config.yaml             # Model (minimax-m2.7:cloud), terminal backend, etc.
├── SOUL.md                 # Donbot's personality (Futurama Robot Mafia don)
├── hermes-agent/           # Cloned Hermes source + Python venv
└── profiles/
    └── <botname>/          # Each hired agent gets its own isolated profile
        ├── .env            # Matrix creds (MATRIX_ALLOWED_USERS=admin,donbot only)
        ├── SOUL.md
        ├── config.yaml
        └── skills/         # Installed SKILL.md files
            └── *.md

~/.mempalace/
└── data/
    ├── donbot/             # CEO memory palace
    └── <botname>/          # Per-agent memory palace

/etc/matrix-synapse/        # Synapse config (homeserver.yaml, signing.key)
/var/lib/matrix-synapse/    # Synapse SQLite DB, media store
/opt/synapse/venv/          # Synapse Python venv
```

---

## Reboot Behaviour

Everything restarts automatically. Systemd linger is enabled so user services come up without a login session.

- `matrix-synapse` — system service (starts first)
- `hermes-gateway` (Donbot) — user service, starts on boot
- `hermes-gateway-<botname>` — one per hired agent

---

## Contributing

Issues and PRs welcome at [github.com/BitsofJeremy/multi_agent_company](https://github.com/BitsofJeremy/multi_agent_company).
