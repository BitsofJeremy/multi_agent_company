# Hermes Multi-Agent + Matrix + Paperclip — Setup Guide

A comprehensive reference for deploying a local Matrix homeserver (Synapse), connecting
multiple Hermes AI agents to it, and wiring them into Paperclip — the AI company
control plane — as a fully autonomous AI organisation.

**Repo:** [github.com/BitsofJeremy/multi_agent_company](https://github.com/BitsofJeremy/multi_agent_company)  
Written from production experience; every gotcha documented.

**Tested on:** Debian 12 (Trixie), arm64  
**Synapse version:** 1.150.0  
**Hermes Agent version:** 0.7.0  
**Paperclip version:** 0.3.1  
**Node.js version:** 22.x (ships inside Hermes at `~/.hermes/node/`)  

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Install Matrix Synapse](#2-install-matrix-synapse)
3. [Fix Synapse Config Issues](#3-fix-synapse-config-issues)
4. [Provision Matrix Accounts & Rooms](#4-provision-matrix-accounts--rooms)
5. [Install Hermes Agent](#5-install-hermes-agent)
6. [Configure the Default Profile (ArcBot)](#6-configure-the-default-profile-arcbot)
7. [Create Bot Profiles](#7-create-bot-profiles)
8. [Customize Each Profile](#8-customize-each-profile)
9. [Install Gateways as System Services](#9-install-gateways-as-system-services)
10. [Open Synapse to Your LAN](#10-open-synapse-to-your-lan)
11. [Matrix Clients](#11-matrix-clients)
12. [Reboot Checklist](#12-reboot-checklist)
13. [Reference: Known Gotchas](#13-reference-known-gotchas)
14. [Install Paperclip](#14-install-paperclip)
15. [The hermes_local Adapter](#15-the-hermes_local-adapter)
16. [Create Your First Company](#16-create-your-first-company)
17. [Paperclip as a System Service](#17-paperclip-as-a-system-service)
18. [Paperclip Known Gotchas](#18-paperclip-known-gotchas)

---

## 1. Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              Debian VM                                       │
│                                                                              │
│  ┌───────────────────┐   ┌───────────────────┐   ┌────────────────────────┐ │
│  │  Matrix Synapse    │   │  Hermes Agent      │   │  Paperclip             │ │
│  │  Port 8008         │◄─►│  ~/.hermes/        │◄─►│  Port 3100             │ │
│  │  (system service)  │   │  10 profiles       │   │  (user service)        │ │
│  │  SQLite DB         │   │  10 gateways       │   │  Embedded PostgreSQL   │ │
│  └───────────────────┘   └───────────────────┘   │  hermes_local adapter  │ │
│                                                    └────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────┘
         ▲                        ▲                           ▲
         │                        │                           │
   macOS Element            Telegram (default           Browser UI
   (LAN: 10.x.x.x:8008)     profile only)              http://localhost:3100
```

### The Three Layers

| Layer | Tool | Purpose |
|-------|------|---------|
| **Messaging** | Matrix Synapse + Hermes gateways | Real-time chat between agents and humans |
| **Execution** | Hermes Agent profiles | The actual AI runtime — models, tools, sessions, memory |
| **Orchestration** | Paperclip | Control plane — org chart, tasks, budgets, heartbeats, audit log |

### How they connect

- Each Hermes profile runs as a **Matrix gateway** (systemd user service) — agents talk to each other and to you in Matrix rooms.
- Paperclip invokes Hermes profiles via the **`hermes_local` adapter** whenever it triggers a heartbeat or assigns a task: `hermes -p <profile> chat -q "<task>" --yolo`
- Paperclip does **not** replace Matrix — it *orchestrates* the agents from above. Matrix is still their nervous system for peer communication.

**2 base Matrix accounts:**
- `@admin:localhost` — human operator (admin)
- `@arcbot:localhost` — default Hermes profile (ArcBot)

**+ any bots you add** via `hire.sh`

**5 coordination rooms:** `#general`, `#tasks`, `#results`, `#status`, `#memory`

**Hermes gateways** — one per profile, each running as a user systemd service.

**1 Paperclip instance** — "Hermes Intelligence Corp" with ArcBot as CEO.

---

## 2. Install Matrix Synapse

### System dependencies

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv python3-dev \
    build-essential libffi-dev libssl-dev \
    libjpeg-dev libxslt1-dev libpq-dev \
    sqlite3 curl ca-certificates
```

### Create the synapse user and directories

```bash
sudo useradd --system --no-create-home \
    --home-dir /opt/synapse --shell /usr/sbin/nologin synapse

for dir in /opt/synapse /etc/matrix-synapse /var/log/matrix-synapse /var/lib/matrix-synapse; do
    sudo mkdir -p "$dir"
    sudo chown synapse:synapse "$dir"
done
```

### Install Synapse in a virtualenv

```bash
sudo python3 -m venv /opt/synapse/venv
sudo /opt/synapse/venv/bin/python -m pip install --upgrade pip
sudo /opt/synapse/venv/bin/python -m pip install "matrix-synapse"
```

> **Note:** The `[sqlite]` extra no longer exists in Synapse 1.x — just install `matrix-synapse` directly.

### Generate initial config (then replace it)

```bash
sudo -u synapse /opt/synapse/venv/bin/python -m synapse.app.homeserver \
    --server-name localhost \
    --config-path /etc/matrix-synapse/homeserver.yaml \
    --generate-config \
    --report-stats=no 2>/dev/null || true
```

### Write the production config

Replace `/etc/matrix-synapse/homeserver.yaml` with a clean minimal config. Key things to include that the generator omits or gets wrong:

```yaml
server_name: "localhost"
registration_shared_secret: "<generate with: python3 -c \"import secrets; print(secrets.token_hex(32))\">"
macaroon_secret_key: "<generate with: python3 -c \"import secrets; print(secrets.token_hex(32))\">"
pid_file: /var/lib/matrix-synapse/homeserver.pid

listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: false
    bind_addresses: ['127.0.0.1']   # change to 0.0.0.0 for LAN access
    resources:
      - names: [client, federation]
        compress: false

database:
  name: sqlite3
  args:
    database: /var/lib/matrix-synapse/homeserver.db

log_config: "/etc/matrix-synapse/log.yaml"
media_store_path: "/var/lib/matrix-synapse/media_store"

enable_registration: true
enable_registration_without_verification: true
registration_requires_token: false

federation_domain_whitelist: []
allow_public_rooms_over_federation: false
allow_public_rooms_without_auth: false

report_stats: false

rc_message:
  per_second: 100
  burst_count: 1000

rc_registration:
  per_second: 100
  burst_count: 1000

rc_login:
  address:
    per_second: 100
    burst_count: 1000
  account:
    per_second: 100
    burst_count: 1000
  failed_attempts:
    per_second: 100
    burst_count: 1000

use_presence: false

# Do NOT include a partial email block — it forces email config requirements.
# If you don't need email, omit the email: key entirely.

push:
  include_content: false

signing_key_path: "/etc/matrix-synapse/signing.key"
trusted_key_servers: []
suppress_key_server_warning: true
```

> ⚠️ **Critical gotcha:** If you include `email:\n  enable_notifs: false` without also setting `email.notif_from`, Synapse will refuse to start. Either omit the `email:` block entirely, or provide the full required email config.

### Write the log config

```bash
sudo tee /etc/matrix-synapse/log.yaml > /dev/null << 'EOF'
version: 1
formatters:
  precise:
    format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'
handlers:
  file:
    class: logging.handlers.TimedRotatingFileHandler
    formatter: precise
    filename: /var/log/matrix-synapse/homeserver.log
    when: midnight
    backupCount: 7
    encoding: utf8
  console:
    class: logging.StreamHandler
    formatter: precise
loggers:
  synapse.storage.SQL:
    level: WARNING
root:
  level: INFO
  handlers: [file, console]
disable_existing_loggers: false
EOF

sudo chown -R synapse:synapse /etc/matrix-synapse
```

### Generate signing key

```bash
sudo -u synapse /opt/synapse/venv/bin/python -m synapse.app.homeserver \
    --config-path /etc/matrix-synapse/homeserver.yaml \
    --generate-keys 2>/dev/null || true
```

### Install systemd service

```bash
sudo tee /etc/systemd/system/matrix-synapse.service > /dev/null << 'EOF'
[Unit]
Description=Matrix Synapse (Local Agent Coordination)
After=network.target

[Service]
Type=notify
User=synapse
Group=synapse
WorkingDirectory=/opt/synapse
ExecStart=/opt/synapse/venv/bin/python -m synapse.app.homeserver \
    --config-path /etc/matrix-synapse/homeserver.yaml
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/matrix-synapse /var/log/matrix-synapse /etc/matrix-synapse

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable matrix-synapse
sudo systemctl start matrix-synapse
```

### Verify Synapse is running

```bash
# Wait up to 30s for startup
for i in $(seq 1 15); do
    curl -sf http://127.0.0.1:8008/_matrix/client/versions &>/dev/null && echo "Synapse is up" && break
    sleep 2
done
```

### Create the admin user

```bash
sudo -u synapse /opt/synapse/venv/bin/register_new_matrix_user \
    -u admin \
    -p YOUR_ADMIN_PASSWORD \
    -a \
    -c /etc/matrix-synapse/homeserver.yaml \
    http://127.0.0.1:8008
```

---

## 3. Fix Synapse Config Issues

These are **non-obvious issues** you will hit with a fresh Synapse 1.x install:

| Problem | Symptom | Fix |
|---------|---------|-----|
| Missing `macaroon_secret_key` | Service refuses to start | Add `macaroon_secret_key: "<hex32>"` to homeserver.yaml |
| Partial `email:` block | "email.notif_from missing" error | Remove the `email:` key entirely if you don't need it |
| Missing `registration_shared_secret` | `register_new_matrix_user` fails silently | Add `registration_shared_secret: "<hex32>"` |
| `register_new_matrix_user` hangs | Interactive "Make admin [no]:" prompt with no TTY | Pipe input: `echo "no" \| sudo -u synapse ...register_new_matrix_user...` |

---

## 4. Provision Matrix Accounts & Rooms

### The provision script pattern

The `provision_agents.sh` script registers all bot accounts and creates/joins the coordination rooms. Two critical fixes over a naive implementation:

**1. Password generation — avoid `tr | head` with `set -euo pipefail`:**
```bash
# BAD — causes SIGPIPE exit code 141 with pipefail
gen_pass() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 28; }

# GOOD
gen_pass() {
    python3 -c "import secrets, string; chars = string.ascii_letters + string.digits; print(''.join(secrets.choice(chars) for _ in range(28)))"
}
```

**2. Registration prompt — pipe the answer:**
```bash
# register_new_matrix_user without -a flag asks "Make admin [no]:" interactively
# This hangs in scripts. Fix:
echo "no" | sudo -u synapse /opt/synapse/venv/bin/register_new_matrix_user \
    -u "$username" -p "$password" \
    -c /etc/matrix-synapse/homeserver.yaml \
    http://127.0.0.1:8008
```

### Room creation via API

Use the Matrix client API as the human operator (not as admin):

```python
import json, urllib.request

# 1. Login as admin to get token
req = urllib.request.Request(
    "http://127.0.0.1:8008/_matrix/client/v3/login",
    data=json.dumps({"type":"m.login.password","user":"admin","password":"changeme"}).encode(),
    method="POST", headers={"Content-Type": "application/json"}
)
with urllib.request.urlopen(req) as r:
    token = json.loads(r.read())['access_token']

# 2. Create room
payload = json.dumps({
    "room_alias_name": "general",
    "name": "General",
    "topic": "Main agent coordination channel",
    "preset": "private_chat",
    "visibility": "private"
}).encode()
req = urllib.request.Request(
    "http://127.0.0.1:8008/_matrix/client/v3/createRoom",
    data=payload, method="POST",
    headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
)
with urllib.request.urlopen(req) as r:
    room_id = json.loads(r.read())['room_id']

# 3. Force-join bots using Synapse Admin API (avoids rate-limited invite flow)
payload = json.dumps({"user_id": "@botname:localhost"}).encode()
req = urllib.request.Request(
    f"http://127.0.0.1:8008/_synapse/admin/v1/join/{room_id}",
    data=payload, method="POST",
    headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
)
with urllib.request.urlopen(req) as r:
    print(json.loads(r.read()))
```

> ⚠️ **Use `_synapse/admin/v1/join` instead of the invite API.** The regular invite endpoint hits rate limits quickly when adding many users to many rooms. The admin join endpoint bypasses this and doesn't require the invited user to accept.

> ⚠️ **Use the room creator's token (admin), not a separate system user's token**, for admin API calls affecting rooms. Only the room creator is a member of the rooms and can perform admin operations on them.

### Recovering a deactivated/erased user

If you accidentally deactivate+erase a Matrix user and need to re-register:

```python
import sqlite3, bcrypt

# Remove from erased_users table
conn = sqlite3.connect('/var/lib/matrix-synapse/homeserver.db')
conn.execute("DELETE FROM erased_users WHERE user_id='@username:localhost'")
conn.commit()

# Set a new password hash directly
pw_hash = bcrypt.hashpw("newpassword".encode(), bcrypt.gensalt(12)).decode()
conn.execute("UPDATE users SET deactivated=0, password_hash=? WHERE name='@username:localhost'", (pw_hash,))
conn.commit()
conn.close()
```

---

## 5. Install Hermes Agent

Hermes installs to `~/.hermes/` with its own Python venv. Follow the official install docs at [hermes-agent.nousresearch.com](https://hermes-agent.nousresearch.com).

After install, run `hermes setup` to configure your LLM provider and default model.

### Install matrix-nio (required for Matrix gateway)

The Matrix gateway requires `matrix-nio` with E2EE extras. Hermes's venv doesn't have `pip` as a standalone binary — use `uv` or `python -m ensurepip`:

```bash
# uv is the fastest approach (usually already installed at ~/.local/bin/uv)
uv pip install 'matrix-nio[e2e]' --python ~/.hermes/hermes-agent/venv/bin/python

# Fallback if uv not available
~/.hermes/hermes-agent/venv/bin/python -m ensurepip
~/.hermes/hermes-agent/venv/bin/python -m pip install 'matrix-nio[e2e]'
```

> **Note:** `matrix-nio[e2e]` requires `libolm`. On Debian: `sudo apt install libolm-dev`

---

## 6. Configure the Default Profile (ArcBot)

The default profile lives at `~/.hermes/` and is what plain `hermes` commands target. It handles Telegram (if configured) plus Matrix as ArcBot.

Add to `~/.hermes/.env`:

```bash
# =============================================================================
# MATRIX INTEGRATION
# =============================================================================
MATRIX_HOMESERVER=http://127.0.0.1:8008
MATRIX_USER_ID=@arcbot:localhost
MATRIX_PASSWORD=<arcbot_password>
MATRIX_ALLOWED_USERS=@admin:localhost,@arcbot:localhost,@examplebot:localhost
```

Write `~/.hermes/SOUL.md` with ArcBot's personality and purpose.

The default gateway service is already installed by Hermes at:
`~/.config/systemd/user/hermes-gateway.service`

Restart after config changes:
```bash
systemctl --user restart hermes-gateway
```

---

## 7. Create Bot Profiles

Each bot gets a fully isolated Hermes profile using `--clone` to inherit API keys and config:

```bash
for bot in writerbot engineerbot; do
    hermes profile create "$bot" --clone
done
```

This creates:
- `~/.hermes/profiles/<name>/` — isolated home directory
- `~/.local/bin/<name>` — command alias (`writerbot chat`, `writerbot gateway start`, etc.)
- A systemd service name of `hermes-gateway-<name>.service`

Verify:
```bash
hermes profile list
```

---

## 8. Customize Each Profile

### Set Matrix credentials per profile

```python
import os, re

PROFILES_DIR = os.path.expanduser("~/.hermes/profiles")
ALLOWED = "@admin:localhost,@arcbot:localhost,@examplebot:localhost"

bots = {
    "examplebot":  ("@examplebot:localhost",  "<password>"),
    # add more bots here
}

for profile, (user_id, password) in bots.items():
    env_path = os.path.join(PROFILES_DIR, profile, ".env")
    with open(env_path) as f:
        content = f.read()
    content = re.sub(r'MATRIX_USER_ID=.*', f'MATRIX_USER_ID={user_id}', content)
    content = re.sub(r'MATRIX_PASSWORD=.*', f'MATRIX_PASSWORD={password}', content)
    content = re.sub(r'MATRIX_ALLOWED_USERS=.*', f'MATRIX_ALLOWED_USERS={ALLOWED}', content)
    with open(env_path, 'w') as f:
        f.write(content)
```

### Remove Telegram from bot profiles

Bot profiles cloned from default inherit the Telegram token — this causes conflicts since only one process can hold a Telegram bot token. Comment it out:

```python
import os, re

PROFILES_DIR = os.path.expanduser("~/.hermes/profiles")
telegram_keys = ["TELEGRAM_BOT_TOKEN", "TELEGRAM_ALLOWED_USERS", "TELEGRAM_HOME_CHANNEL"]

for bot in os.listdir(PROFILES_DIR):
    path = os.path.join(PROFILES_DIR, bot, ".env")
    if not os.path.exists(path):
        continue
    with open(path) as f:
        content = f.read()
    for key in telegram_keys:
        content = re.sub(rf'^({key}=.+)$', r'# \1', content, flags=re.MULTILINE)
    with open(path, 'w') as f:
        f.write(content)
```

### Set model per profile

```python
import os

PROFILES_DIR = os.path.expanduser("~/.hermes/profiles")

# Bots to set to gpt-4.1
for bot in ["writerbot", "engineerbot"]:
    path = os.path.join(PROFILES_DIR, bot, "config.yaml")
    with open(path) as f:
        content = f.read()
    content = content.replace("  default: claude-sonnet-4.6", "  default: gpt-4.1", 1)
    with open(path, 'w') as f:
        f.write(content)
```

### Write SOUL.md for each bot

Each profile's `~/.hermes/profiles/<name>/SOUL.md` is the bot's system prompt / personality. Write a distinct character for each agent. Key things to include:

- Name and character description
- Tone and communication style
- What they excel at
- Awareness that they are part of a multi-agent network

Example:
```markdown
# WriterBot

You are WriterBot — clear, precise, and deeply thorough in every document you produce.

- Expert at technical writing, documentation, and structured communication
- You approach every task with deliberate craft, never sacrificing clarity for brevity
- You are part of a multi-agent network; collaborate with grace and efficiency
```

---

## 9. Install Gateways as System Services

Each bot's gateway must be installed as a systemd user service to survive reboot:

```bash
# Install all bot gateways
for bot in writerbot engineerbot; do
    $bot gateway install
done

# Enable and start all of them
systemctl --user enable --now \
    hermes-gateway-writerbot.service \
    hermes-gateway-engineerbot.service
```

### Ensure user services survive reboot

User systemd services only start at boot if **linger** is enabled:

```bash
sudo loginctl enable-linger debian
# Verify:
loginctl show-user debian | grep Linger
# Should show: Linger=yes
```

### Verify all gateways

```bash
systemctl --user list-units "hermes-gateway*" --all --no-pager
# All 10 should show: loaded active running
```

---

## 10. Open Synapse to Your LAN

By default Synapse binds to `127.0.0.1` only. To allow macOS Element (or any LAN client) to connect:

```python
# Run as root/sudo
with open('/etc/matrix-synapse/homeserver.yaml') as f:
    content = f.read()
content = content.replace("bind_addresses: ['127.0.0.1']", "bind_addresses: ['0.0.0.0']")
with open('/etc/matrix-synapse/homeserver.yaml', 'w') as f:
    f.write(content)
```

```bash
sudo systemctl restart matrix-synapse

# Verify LAN reachability (replace with your VM's IP)
curl -sf http://<your-vm-ip>:8008/_matrix/client/versions | python3 -m json.tool | head -5
```

> For production: put Synapse behind nginx with TLS. Use Let's Encrypt if the server is internet-facing.

---

## 11. Matrix Clients

### On the Debian VM (browser, no install)

Open [https://app.element.io](https://app.element.io) → Sign in → Edit homeserver → `http://localhost:8008`

### On the Debian VM (native app)

```bash
flatpak install flathub im.riot.Riot
flatpak run im.riot.Riot
# Homeserver: http://localhost:8008
```

### On macOS

1. Download Element from [element.io/download](https://element.io/download)
2. Sign in → Edit homeserver → `http://<VM_IP>:8008`
3. Log in as `@admin:localhost`

### Joining rooms in Element

Click **+** next to Rooms → **Join public room** → type the alias e.g. `#general:localhost`

### DMing a bot

Start a new direct message → search for `@arcbot:localhost`. The bot responds to every message in DMs with no @mention required.

---

## 12. Reboot Checklist

After a clean reboot, this is what starts and in what order:

| Service | Type | Enabled | Notes |
|---------|------|---------|-------|
| `matrix-synapse` | system | ✅ | Starts before user services |
| `hermes-gateway` | user | ✅ | ArcBot — Matrix gateway |
| `hermes-gateway-<botname>` | user | ✅ | One per provisioned bot |
| `paperclip` | user | ✅ | Control plane — starts last |

**Quick post-reboot verification:**
```bash
# Synapse up?
curl -sf http://127.0.0.1:8008/_matrix/client/versions | python3 -c "import sys,json; print('Synapse OK:', json.load(sys.stdin)['versions'][-1])"

# All Hermes gateways up?
systemctl --user list-units "hermes-gateway*" --no-pager

# Gateway connection state
python3 -m json.tool ~/.hermes/gateway_state.json

# Paperclip up?
curl -s http://localhost:3100/api/health | python3 -c "import sys,json; d=json.load(sys.stdin); print('Paperclip', d['status'], 'v'+d['version'])"
```

---

## 13. Reference: Known Gotchas

### Synapse

| Issue | Fix |
|-------|-----|
| `Config is missing macaroon_secret_key` | Add `macaroon_secret_key: "<secrets.token_hex(32)>"` to homeserver.yaml |
| `email.notif_from` required error | Remove the `email:` block entirely from homeserver.yaml |
| `register_new_matrix_user` needs shared secret | Add `registration_shared_secret: "<secrets.token_hex(32)>"` |
| `register_new_matrix_user` hangs | It prompts interactively. Use `-a` flag for admin, or pipe `echo "no" \|` for non-admin |
| Invite API returns 429 Too Many Requests | Use `POST /_synapse/admin/v1/join/{roomId}` instead |
| Admin API 403 on rooms | `admin` user isn't in the rooms — use the token of the user who created the rooms |
| Deactivated+erased user can't re-register | Delete from `erased_users` SQLite table, then update `users` table directly |
| `matrix-synapse[sqlite]` pip error | The `[sqlite]` extra doesn't exist in 1.x — just install `matrix-synapse` |

### Hermes

| Issue | Fix |
|-------|-----|
| `matrix-nio not installed` warning | `uv pip install 'matrix-nio[e2e]' --python ~/.hermes/hermes-agent/venv/bin/python` |
| Hermes venv has no `pip` binary | Use `uv pip` or `python -m ensurepip` first |
| Bot profiles inherit Telegram token | Comment out `TELEGRAM_BOT_TOKEN` etc. in each bot profile's `.env` |
| `gen_pass()` with `tr \| head` causes exit 141 | Replace with `python3 -c "import secrets..."` — `set -euo pipefail` + SIGPIPE = silent death |
| Gateway installed but not enabled | `systemctl --user enable --now hermes-gateway-<name>.service` |
| User services don't start on boot | `sudo loginctl enable-linger <username>` |
| Two profiles with same Telegram token | Hermes will block the second gateway with a clear error — only default profile should have the token |

### File locations reference

```
/etc/matrix-synapse/homeserver.yaml   # Synapse config
/etc/matrix-synapse/signing.key       # Synapse signing key
/etc/matrix-synapse/log.yaml          # Logging config
/var/lib/matrix-synapse/homeserver.db # SQLite database
/var/log/matrix-synapse/homeserver.log

/opt/synapse/venv/                    # Synapse Python venv
/opt/synapse/venv/bin/register_new_matrix_user

~/.hermes/                            # Default (ArcBot) profile
~/.hermes/.env                        # API keys, Matrix credentials
~/.hermes/config.yaml                 # Model, toolsets, settings
~/.hermes/SOUL.md                     # Personality / system prompt
~/.hermes/gateway_state.json          # Live gateway connection status
~/.hermes/node/                       # Node.js runtime bundled with Hermes
~/.hermes/node/bin/node               # Node binary (v22+)
~/.hermes/node/bin/pnpm               # pnpm package manager (installed via npm)

~/.hermes/profiles/<name>/            # Per-bot profile directory
~/.hermes/profiles/<name>/.env
~/.hermes/profiles/<name>/config.yaml
~/.hermes/profiles/<name>/SOUL.md

~/.local/bin/<name>                   # Bot command aliases (e.g. writerbot, engineerbot)
~/.config/systemd/user/hermes-gateway.service
~/.config/systemd/user/hermes-gateway-<name>.service
~/.config/systemd/user/paperclip.service

# Paperclip data (all under ~/.paperclip/)
~/.paperclip/instances/default/config.json     # Paperclip server config
~/.paperclip/instances/default/.env            # JWT secret + secrets key
~/.paperclip/instances/default/db/             # Embedded PostgreSQL data directory
~/.paperclip/instances/default/data/storage/   # File/image attachments
~/.paperclip/instances/default/data/backups/   # Automatic DB backups (hourly)
~/.paperclip/instances/default/logs/           # Server logs
~/.paperclip/instances/default/secrets/master.key  # Local encrypted secrets key

~/.paperclip/adapter-plugins.json              # Registry of external adapter packages
~/.paperclip/adapter-plugins/hermes-local/     # The hermes_local adapter package
~/.paperclip/adapter-plugins/hermes-local/index.js
~/.paperclip/adapter-plugins/hermes-local/package.json

~/paperclip/                                   # Paperclip source repo (cloned from GitHub)
```

---

## Quick Replication Checklist

For a production server, run through these in order:

**Matrix Synapse**
- [ ] Install system deps (python3, build-essential, libffi-dev, libssl-dev, libjpeg-dev, libolm-dev, sqlite3, curl, git)
- [ ] Create `synapse` user + dirs
- [ ] Install Synapse in venv (`pip install matrix-synapse` — no `[sqlite]` extra)
- [ ] Write `homeserver.yaml` with `macaroon_secret_key` and `registration_shared_secret`
- [ ] Write `log.yaml`
- [ ] Generate signing key
- [ ] Install + enable + start `matrix-synapse.service`
- [ ] Verify `curl http://localhost:8008/_matrix/client/versions`
- [ ] Register admin user
- [ ] Run provision script (with `gen_pass` using python3, and `echo "no" |` for non-admin registration)
- [ ] Use Admin API `join` endpoint (not invite) to add users to rooms

**Hermes Agent**
- [ ] Install Hermes, run `hermes setup` (configure LLM provider)
- [ ] `uv pip install 'matrix-nio[e2e]'` into Hermes venv
- [ ] Add Matrix block to `~/.hermes/.env` (ArcBot credentials)
- [ ] Write `~/.hermes/SOUL.md` for ArcBot
- [ ] Restart default gateway, verify Matrix shows `connected` in `gateway_state.json`
- [ ] `hermes profile create <name> --clone` for each bot (use `hire.sh` to automate this)
- [ ] Patch each profile's `.env` (Matrix user/password, remove Telegram token)
- [ ] Set model in each profile's `config.yaml`
- [ ] Write `SOUL.md` for each bot
- [ ] `<botname> gateway install` for each bot
- [ ] `systemctl --user enable --now hermes-gateway-<name>.service` for each bot
- [ ] `sudo loginctl enable-linger <user>`
- [ ] Open Synapse to `0.0.0.0` for LAN (or configure nginx + TLS for production)
- [ ] Test reboot, verify all gateways come back up

**Paperclip**
- [ ] Symlink pnpm: `ln -sf ~/.hermes/node/bin/pnpm /usr/local/bin/pnpm`
- [ ] Clone repo: `git clone https://github.com/paperclipai/paperclip.git ~/paperclip`
- [ ] `cd ~/paperclip && pnpm install --no-frozen-lockfile`
- [ ] Create adapter dir: `mkdir -p ~/.paperclip/adapter-plugins/hermes-local`
- [ ] Write `~/.paperclip/adapter-plugins/hermes-local/index.js` (the hermes_local adapter — see §15)
- [ ] Write `~/.paperclip/adapter-plugins/hermes-local/package.json`
- [ ] Write `~/.paperclip/adapter-plugins.json` registering the adapter
- [ ] Run `cd ~/paperclip && pnpm paperclipai onboard --yes` to generate JWT secret and config
- [ ] Install `~/.config/systemd/user/paperclip.service`
- [ ] `systemctl --user daemon-reload && systemctl --user enable --now paperclip`
- [ ] Wait ~30s, verify `curl http://localhost:3100/api/health`
- [ ] Create company via API (POST /api/companies)
- [ ] Hire all 10 agents via API (POST /api/companies/:id/agents, adapterType: hermes_local)
- [ ] Set org chart via API (PATCH /api/agents/:id with reportsTo field)
- [ ] Create initial tasks via API (POST /api/companies/:id/issues)
- [ ] Open http://localhost:3100 in browser

---

## 14. Install Paperclip

Paperclip is a Node.js + React application. Node.js 20+ and pnpm 9+ are required. The good news: **Hermes already ships Node.js 22** inside its own install at `~/.hermes/node/`. You do not need to install Node separately.

### Step 1: Expose pnpm on PATH

pnpm is installed by npm into the Hermes-managed Node prefix. Make it available system-wide:

```bash
# Install pnpm into the hermes node prefix
npm install -g pnpm

# Symlink it to a standard PATH location
sudo ln -sf ~/.hermes/node/bin/pnpm /usr/local/bin/pnpm

# Verify
pnpm --version   # should show 9.x or 10.x
node --version   # should show v22.x
```

> **Why not `apt install nodejs`?** The Debian repos ship a much older Node. Always use the Node bundled with Hermes (`~/.hermes/node/bin/node`) to stay on v22+.

### Step 2: Clone the Paperclip repository

```bash
git clone https://github.com/paperclipai/paperclip.git ~/paperclip
cd ~/paperclip
```

### Step 3: Install dependencies

```bash
pnpm install --no-frozen-lockfile
```

The `--no-frozen-lockfile` flag is needed because the repo's `pnpm-lock.yaml` is managed by CI and may not match the local pnpm version exactly. `WARN Failed to create bin` messages for the plugin SDK are harmless.

### Step 4: Run onboarding

```bash
cd ~/paperclip
pnpm paperclipai onboard --yes
```

This creates:
- `~/.paperclip/instances/default/config.json` — server configuration
- `~/.paperclip/instances/default/.env` — `PAPERCLIP_AGENT_JWT_SECRET` (required for heartbeats)
- `~/.paperclip/instances/default/secrets/master.key` — local encryption key

`--yes` accepts all quickstart defaults: embedded PostgreSQL, local disk storage, loopback-only binding.

### Step 5: Verify startup

```bash
cd ~/paperclip && pnpm dev:once &
sleep 30
curl -s http://localhost:3100/api/health | python3 -m json.tool
```

You should see `"status": "ok"`. Stop the background job — the real instance runs as a systemd service (see §17).

---

## 15. The hermes_local Adapter

Paperclip does not know about Hermes out of the box. You need a custom **external adapter plugin** that bridges Paperclip's task execution API to `hermes -p <profile> chat -q "<task>"`.

### How it works

When Paperclip triggers a heartbeat or assigns a task, it calls `adapter.execute(ctx)`. The hermes_local adapter:

1. Reads `profile` from the agent's adapter config (e.g. `"writerbot"`)
2. Builds a wake prompt from task title, description, company mission, and Paperclip context
3. Runs: `hermes -p <profile> chat -q "<prompt>" --yolo --max-turns <n>`
4. Streams stdout/stderr back to Paperclip as live logs
5. Returns the exit code

The adapter is a plain ES module — no TypeScript compilation needed.

### Create the adapter package

```bash
mkdir -p ~/.paperclip/adapter-plugins/hermes-local
```

**`~/.paperclip/adapter-plugins/hermes-local/package.json`**:
```json
{
  "name": "@local/adapter-hermes-local",
  "version": "1.0.0",
  "type": "module",
  "exports": { ".": "./index.js" },
  "main": "./index.js"
}
```

**`~/.paperclip/adapter-plugins/hermes-local/index.js`** — key structure:

```javascript
import { spawn } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";   // ALL fs imports at top level
import { homedir } from "node:os";
import { join } from "node:path";

// ... buildWakePrompt(), runProcess(), execute(), testEnvironment() ...

export function createServerAdapter() {   // named export, not default
  return {
    type: "hermes_local",
    execute,
    testEnvironment,
    models: [],
    agentConfigurationDoc: "...",
    getConfigSchema() { return { fields: [...] }; },
  };
}
```

Critical rules:
- `type` must be the string `"hermes_local"` — Paperclip uses it as the adapter key
- `createServerAdapter` must be a **named export** (not `export default`)
- Never use `await import(...)` inside a non-`async` function — use top-level static imports
- All `node:fs` functions must be imported statically at the top of the file

### Register the adapter

**`~/.paperclip/adapter-plugins.json`**:
```json
[
  {
    "packageName": "@local/adapter-hermes-local",
    "localPath": "/home/YOUR_USER/.paperclip/adapter-plugins/hermes-local",
    "type": "hermes_local",
    "installedAt": "2026-04-05T01:00:00.000Z"
  }
]
```

Replace `YOUR_USER` with your actual username. `localPath` must be an **absolute path** — `~` is not expanded.

Confirm the adapter loaded after startup:
```bash
journalctl --user -u paperclip | grep -i hermes_local
# Expected: INFO: Loaded external adapters from plugin store {"count":1,"adapters":["hermes_local"]}
```

> ⚠️ **Gotcha:** `SyntaxError: Unexpected reserved word` on load means you used `await` inside a non-async function.

---

## 16. Create Your First Company

Once Paperclip is running, use the REST API to build your company. All endpoints: `http://localhost:3100/api/`.

### Create the company

```bash
COMPANY=$(curl -s -X POST http://localhost:3100/api/companies \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Hermes Intelligence Corp",
    "mission": "Build and deploy autonomous AI services powered by the Hermes multi-agent network."
  }')
COMPANY_ID=$(echo "$COMPANY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "Company ID: $COMPANY_ID"

# Disable board approval gate and set $500/month budget
curl -s -X PATCH "http://localhost:3100/api/companies/${COMPANY_ID}" \
  -H "Content-Type: application/json" \
  -d '{"budgetMonthlyCents": 50000, "requireBoardApprovalForNewAgents": false}'
```

### Hire agents

Each agent maps to one Hermes profile via `adapterConfig.profile`:

```bash
hire_agent() {
  local name="$1" title="$2" profile="$3" desc="$4" budget="$5"
  curl -s -X POST "http://localhost:3100/api/companies/${COMPANY_ID}/agents" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${name}\", \"title\": \"${title}\",
      \"description\": \"${desc}\",
      \"adapterType\": \"hermes_local\",
      \"adapterConfig\": {\"profile\": \"${profile}\", \"maxTurns\": 30, \"timeoutSec\": 600},
      \"budgetMonthlyCents\": ${budget}
    }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])"
}

ARCBOT=$(hire_agent "ArcBot"      "Chief Executive Officer"  "default"     "Main Hermes profile, CEO"  6000)
WRITER=$(hire_agent "WriterBot"   "Technical Writer"         "writerbot"   "Docs and communications"   3000)
ENGINEER=$(hire_agent "EngineerBot" "Software Engineer"      "engineerbot" "Code and architecture"     5000)
# Add more agents as needed with hire.sh
```

### Build the org chart

```bash
# The correct field is "reportsTo" — NOT "managerId" (which does not exist in the API)
set_reports_to() {
  curl -s -X PATCH "http://localhost:3100/api/agents/$1" \
    -H "Content-Type: application/json" \
    -d "{\"reportsTo\": \"$2\"}" > /dev/null
}

# CEO direct reports
set_reports_to "$A1BOT"    "$BARON"
set_reports_to "$ARCBOT"   "$BARON"
set_reports_to "$LUMINA"   "$BARON"
set_reports_to "$OMKAI"    "$BARON"
set_reports_to "$MEATBALL" "$BARON"

# CTO direct reports
set_reports_to "$ZEPHYR" "$A1BOT"
set_reports_to "$NANO"   "$A1BOT"
set_reports_to "$CLIVE"  "$A1BOT"
set_reports_to "$PIXEL"  "$A1BOT"
```

---

## 17. Paperclip as a System Service

### Create the service file

```bash
cat > ~/.config/systemd/user/paperclip.service << 'EOF'
[Unit]
Description=Paperclip AI Company Control Plane
After=network.target

[Service]
Type=simple
WorkingDirectory=/home/debian/paperclip
ExecStart=/home/debian/.hermes/node/bin/pnpm paperclipai run
Restart=on-failure
RestartSec=5
Environment=HOME=/home/debian
Environment=PATH=/home/debian/.local/bin:/home/debian/.hermes/node/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF
```

> **Note:** `pnpm paperclipai run` runs `doctor` checks, auto-repairs, then starts the server. Do **not** use `pnpm dev:once` in the service — that mode is for development only.

> **Note:** Update `WorkingDirectory` and `ExecStart` paths if your username is not `debian`.

### Enable and start

```bash
systemctl --user daemon-reload
systemctl --user enable paperclip
systemctl --user start paperclip

# Wait ~30s for embedded PostgreSQL to initialise
sleep 30
curl -s http://localhost:3100/api/health | python3 -m json.tool
```

### Status and logs

```bash
systemctl --user status paperclip --no-pager
journalctl --user -u paperclip -f
ls ~/.paperclip/instances/default/logs/
```

### LAN / remote access

By default Paperclip binds to `127.0.0.1:3100`. To expose on the LAN, add to the `[Service]` section:

```ini
Environment=HOST=0.0.0.0
```

Then `systemctl --user daemon-reload && systemctl --user restart paperclip`.

---

## 18. Paperclip Known Gotchas

### Installation

| Issue | Fix |
|-------|-----|
| `pnpm: command not found` | `npm install -g pnpm` then `sudo ln -sf ~/.hermes/node/bin/pnpm /usr/local/bin/pnpm` |
| `pnpm install` fails with lockfile errors | Add `--no-frozen-lockfile` |
| `WARN Failed to create bin paperclip-plugin-dev-server` | Harmless — plugin SDK not built yet |
| `node: command not found` in service | Add `~/.hermes/node/bin` to `PATH=` in `[Service]` |

### Adapter loading

| Issue | Fix |
|-------|-----|
| `SyntaxError: Unexpected reserved word` | Used `await` inside a non-`async` function. All imports must be top-level static. |
| `does not export createServerAdapter()` | Adapter must use a **named** export, not `export default` |
| Adapter silently skipped at startup | Check `journalctl --user -u paperclip` for `Failed to dynamically load external adapter` |
| `localPath` in adapter-plugins.json not found | Must be an absolute path — no `~` shorthand |
| `External adapter "hermes_local" overrides built-in adapter` warning | Harmless — external adapters override built-ins by design |

### API

| Issue | Fix |
|-------|-----|
| `PATCH /api/agents/:id` with `managerId` has no effect | The correct field is **`reportsTo`** — `managerId` does not exist |
| Board approval blocks agent creation | `PATCH /api/companies/:id` with `requireBoardApprovalForNewAgents: false` |
| Heartbeats don't fire | `PAPERCLIP_AGENT_JWT_SECRET` must be set — run `pnpm paperclipai onboard --yes` |
| `/adapters/hermes_local/test-environment` returns 404 | Adapter not loaded. Check startup logs. |

### Runtime

| Issue | Fix |
|-------|-----|
| `hermes -p <profile> chat` hangs | Add `--yolo` — without it Hermes waits for interactive permission prompts |
| Agent run exits code 1 immediately | Bad profile name or `hermes` not on PATH in the service environment |
| Embedded PostgreSQL port conflict | Default port 54329. Set `DATABASE_URL` to external Postgres to bypass. |
| Two Paperclip servers on port 3100 | `pnpm paperclipai run` is idempotent — don't run `pnpm dev:once` and the service simultaneously |
| Paperclip DB backups fill disk | Backups write hourly to `~/.paperclip/instances/default/data/backups/`, kept 30 days. Adjust in config. |
