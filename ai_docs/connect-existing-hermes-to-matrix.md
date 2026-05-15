# Connecting Existing Hermes Agents to Matrix

**Use case:** Two VMs, each running a Hermes agent with Telegram. Add Matrix as an internal coordination layer. No Donbot, no new bot provisioning scripts — just wire existing agents into a shared Synapse.

**Topology:**
```
RODAN (10.15.0.16)          MOGUERA (10.15.0.1)
┌─────────────────────┐       ┌─────────────────────┐
│ Hermes (existing)   │       │ Hermes (existing)   │
│ + Telegram gateway   │◄─────►│ + Telegram gateway   │
│ + Matrix Synapse ★  │       │                     │
└─────────────────────┘       └─────────────────────┘
         ★ New: Synapse installed here via launch.sh
```

---

## Step 1 — RODAN: Install Matrix Synapse

On RODAN, run `launch.sh` but skip everything you already have:

```bash
# Run as your desktop user (not root), sudo is called internally
bash launch.sh --skip-hermes --skip-element --skip-mempalace
```

This installs only:
- Matrix Synapse at `http://0.0.0.0:8008`
- Creates 5 coordination rooms (`#general`, `#tasks`, `#results`, `#status`, `#memory`)

After install, the admin credentials are the same as before:
- **User:** `@admin:localhost` / `changeme`

---

## Step 2 — RODAN: Register RODAN's Existing Hermes Agent in Synapse

On RODAN, pick a Matrix user ID for the existing Hermes agent. If the agent's profile is called `arcbot`, use `@arcbot:localhost`. If it's the default profile, use `@default:localhost` or `@hermes:localhost`.

Decide the bot name. Below we use `rodan` as an example.

```bash
# Generate a strong password for the bot (run on either VM)
python3 -c "
import secrets, string
chars = string.ascii_letters + string.digits + '!@#\$%^&*'
print(''.join(secrets.choice(chars) for _ in range(28)))
"
# Example output: Kx9#mP2!vR4nL8@qW7eJ3bY6tN
```

Register the bot with Synapse. On RODAN, as your desktop user (not root):

```bash
# Read the registration shared secret from the homeserver config
REG_SHARED_SECRET=$(sudo grep "registration_shared_secret" /etc/matrix-synapse/homeserver.yaml | grep -oP '(?<=")[^"]+')

# Register the bot (non-admin)
sudo -u synapse /opt/synapse/venv/bin/register_new_matrix_user \
  -u "rodan" \
  -p "Kx9#mP2!vR4nL8@qW7eJ3bY6tN" \
  --no-admin \
  --shared-secret "${REG_SHARED_SECRET}" \
  "http://127.0.0.1:8008"
```

Save the bot's password — you'll need it for Step 4.

Also save the bot's Matrix ID: `@rodan:localhost`

---

## Step 3 — MOGUERA: Register MOGUERA's Hermes Agent in RODAN's Synapse

On MOGUERA, repeat the registration but point at RODAN's Synapse (using RODAN's LAN IP).

First, get the registration shared secret from RODAN:

```bash
# On RODAN — get the reg secret
sudo grep "registration_shared_secret" /etc/matrix-synapse/homeserver.yaml | grep -oP '(?<=")[^"]+'
```

Copy that secret. On MOGUERA, use it to register their bot:

```bash
# On MOGUERA — install synapse tools for the registration command
# (or use the same Python approach directly against the API — see below)

# Generate a password on MOGUERA
python3 -c "
import secrets, string
chars = string.ascii_letters + string.digits + '!@#\$%^&*'
print(''.join(secrets.choice(chars) for _ in range(28)))
"
# Example output: Bp2@vK8!mR5nL9@X3wJ6tQ4cN
```

**Alternative: Register via the admin API directly (no sudo needed)**

On MOGUERA, you can register the remote bot via the Synapse admin API using Python:

```python
# Run on MOGUERA to register @moguera:localhost via RODAN's admin API
import json, urllib.request, urllib.error

SYNAPSE_HOST = "http://10.15.0.16:8008"   # RODAN's LAN IP
ADMIN_USER   = "admin"
ADMIN_PASS   = "changeme"                   # RODAN's admin password
BOT_NAME     = "moguera"
BOT_PASS     = "Bp2@vK8!mR5nL9@X3wJ6tQ4cN"  # password you generated above

# Login as admin
req = urllib.request.Request(
    f"{SYNAPSE_HOST}/_matrix/client/v3/login",
    data=json.dumps({"type": "m.login.password", "user": ADMIN_USER, "password": ADMIN_PASS}).encode(),
    headers={"Content-Type": "application/json"}
)
resp = urllib.request.urlopen(req, timeout=10)
admin_token = json.loads(resp.read())["access_token"]

# Register the bot
req = urllib.request.Request(
    f"{SYNAPSE_HOST}/_synapse/admin/v1/register",
    data=json.dumps({"username": BOT_NAME, "password": BOT_PASS}).encode(),
    headers={"Content-Type": "application/json", "Authorization": f"Bearer {admin_token}"}
)
try:
    resp = urllib.request.urlopen(req, timeout=10)
    result = json.loads(resp.read())
    print(f"Registered @{BOT_NAME}:localhost")
    print(f"Password: {BOT_PASS}")
except urllib.error.HTTPError as e:
    print(f"Registration failed: {e.code} — {e.read().decode()[:200]}")
```

Run with:
```bash
python3 << 'PYEOF'
# (paste the script above)
PYEOF
```

---

## Step 4 — Both VMs: Configure Each Hermes Agent's .env for Matrix

On each VM, update the Hermes profile's `.env` to include Matrix credentials.

**RODAN — update the existing profile's .env:**

```bash
# Find the Hermes profile .env — likely at ~/.hermes/.env for the default profile
# or ~/.hermes/profiles/<name>/.env for a named profile

HERMES_HOME="${HOME}/.hermes"

# Add these to the .env file (append or edit):
cat >> "${HERMES_HOME}/.env" << 'EOF'

# =============================================================================
# MATRIX INTEGRATION
# =============================================================================
MATRIX_HOMESERVER=http://127.0.0.1:8008
MATRIX_USER_ID=@rodan:localhost
MATRIX_PASSWORD=Kx9#mP2!vR4nL8@qW7eJ3bY6tN
MATRIX_ALLOWED_USERS=@admin:localhost,@moguera:localhost
EOF
```

**MOGUERA — update its profile's .env to point at RODAN's Synapse:**

```bash
HERMES_HOME="${HOME}/.hermes"

cat >> "${HERMES_HOME}/.env" << 'EOF'

# =============================================================================
# MATRIX INTEGRATION
# =============================================================================
MATRIX_HOMESERVER=http://10.15.0.16:8008
MATRIX_USER_ID=@moguera:localhost
MATRIX_PASSWORD=Bp2@vK8!mR5nL9@X3wJ6tQ4cN
MATRIX_ALLOWED_USERS=@admin:localhost,@rodan:localhost
EOF
```

**Important:** `MATRIX_ALLOWED_USERS` restricts which users the gateway will respond to. Both bots need to allow each other and `@admin` to communicate.

---

## Step 5 — Both VMs: Verify the Coordination Rooms Exist on RODAN

On RODAN, get the room IDs for the 5 coordination rooms (needed for the next step):

```bash
# On RODAN — read room IDs from the credentials file
cat ~/Downloads/matrix_credentials.env | grep MATRIX_ROOM_
```

You should see:
```
MATRIX_ROOM_GENERAL=<room_id>
MATRIX_ROOM_TASKS=<room_id>
MATRIX_ROOM_RESULTS=<room_id>
MATRIX_ROOM_STATUS=<room_id>
MATRIX_ROOM_MEMORY=<room_id>
```

If the file is empty or missing room IDs, create the rooms first:

```bash
# On RODAN — create all 5 rooms as admin
python3 << 'PYEOF'
import json, urllib.request, urllib.error

SYNAPSE = "http://127.0.0.1:8008"
ADMIN   = "admin"
APASS   = "changeme"

req = urllib.request.Request(
    f"{SYNAPSE}/_matrix/client/v3/login",
    data=json.dumps({"type": "m.login.password", "user": ADMIN, "password": APASS}).encode(),
    headers={"Content-Type": "application/json"}
)
admin_token = json.loads(urllib.request.urlopen(req, timeout=10).read())["access_token"]

rooms = ["general", "tasks", "results", "status", "memory"]
for alias in rooms:
    req = urllib.request.Request(
        f"{SYNAPSE}/_matrix/client/v3/createRoom",
        data=json.dumps({"room_alias_name": alias, "name": alias.capitalize(), "preset": "private_chat", "visibility": "private"}).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {admin_token}"}
    )
    resp = urllib.request.urlopen(req, timeout=10)
    room_id = json.loads(resp.read())["room_id"]
    print(f"#{alias}: {room_id}")
PYEOF
```

---

## Step 6 — Both VMs: Join Both Bots to the Coordination Rooms

On RODAN, join `rodan` to all 5 rooms using the admin API (this bypasses invite requirements):

```python
# On RODAN — run as your desktop user (not root)
python3 << 'PYEOF'
import json, urllib.request, urllib.error

SYNAPSE  = "http://127.0.0.1:8008"
CREDS    = "/root/Downloads/matrix_credentials.env"  # or ~/Downloads/...
ADMIN    = "admin"
APASS    = "changeme"
BOT      = "@rodan:localhost"

# Login as admin
req = urllib.request.Request(
    f"{SYNAPSE}/_matrix/client/v3/login",
    data=json.dumps({"type": "m.login.password", "user": ADMIN, "password": APASS}).encode(),
    headers={"Content-Type": "application/json"}
)
admin_token = json.loads(urllib.request.urlopen(req, timeout=10).read())["access_token"]

# Read room IDs
room_ids = []
with open("/root/Downloads/matrix_credentials.env") as f:
    for line in f:
        if line.startswith("MATRIX_ROOM_") and "ALIAS" not in line:
            room_ids.append(line.strip().split("=")[1])

# Join each room
for room_id in room_ids:
    req = urllib.request.Request(
        f"{SYNAPSE}/_synapse/admin/v1/join/{room_id}",
        data=json.dumps({"user_id": BOT}).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {admin_token}"}
    )
    try:
        resp = urllib.request.urlopen(req, timeout=10)
        print(f"Joined {room_id}")
    except Exception as e:
        print(f"Failed to join {room_id}: {e}")
PYEOF
```

On MOGUERA, do the same but for `@moguera:localhost` against `http://10.15.0.16:8008`:

```python
# On MOGUERA — join @moguera to all 5 rooms on RODAN's Synapse
python3 << 'PYEOF'
import json, urllib.request, urllib.error

SYNAPSE  = "http://10.15.0.16:8008"
CREDS    = "/root/Downloads/matrix_credentials.env"
ADMIN    = "admin"
APASS    = "changeme"
BOT      = "@moguera:localhost"

req = urllib.request.Request(
    f"{SYNAPSE}/_matrix/client/v3/login",
    data=json.dumps({"type": "m.login.password", "user": ADMIN, "password": APASS}).encode(),
    headers={"Content-Type": "application/json"}
)
admin_token = json.loads(urllib.request.urlopen(req, timeout=10).read())["access_token"]

room_ids = []
with open("/root/Downloads/matrix_credentials.env") as f:
    for line in f:
        if line.startswith("MATRIX_ROOM_") and "ALIAS" not in line:
            room_ids.append(line.strip().split("=")[1])

for room_id in room_ids:
    req = urllib.request.Request(
        f"{SYNAPSE}/_synapse/admin/v1/join/{room_id}",
        data=json.dumps({"user_id": BOT}).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {admin_token}"}
    )
    try:
        resp = urllib.request.urlopen(req, timeout=10)
        print(f"Joined {room_id}")
    except Exception as e:
        print(f"Failed to join {room_id}: {e}")
PYEOF
```

---

## Step 7 — Both VMs: Restart the Hermes Gateway

On each VM, restart the gateway so it picks up the Matrix credentials:

```bash
# On RODAN — restart the gateway (use the correct service name for your setup)
systemctl --user restart hermes-gateway

# On MOGUERA — restart its gateway (the service name depends on how it was started)
systemctl --user restart hermes-gateway
# or if it was started directly:
hermes gateway restart
```

Check the logs:

```bash
# On RODAN
journalctl --user -u hermes-gateway -f

# On MOGUERA
journalctl --user -u hermes-gateway -f
```

You should see the gateway connecting to Matrix and joining the rooms.

---

## Step 8 — Test: Send a Message to Both Bots

From Element Desktop (connected to `http://10.15.0.16:8008` as `@admin`), send a message to `@rodan:localhost` and `@moguera:localhost`. If the `MATRIX_ALLOWED_USERS` is set correctly, they will respond.

For internal coordination between agents, they can now message each other directly via Matrix DMs or post to the shared rooms (`#tasks`, `#general`, etc.).

---

## Summary of Credentials

| VM | Bot Matrix ID | Password | Synapse |
|---|---|---|---|
| RODAN | `@rodan:localhost` | `Kx9#mP2!vR4nL8@qW7eJ3bY6tN` | `http://127.0.0.1:8008` |
| MOGUERA | `@moguera:localhost` | `Bp2@vK8!mR5nL9@X3wJ6tQ4cN` | `http://10.15.0.16:8008` |

---

## If You Want to Add More VMs

Repeat Steps 3, 4, 6, and 7 for each additional VM. The pattern:
1. Register the new bot with RODAN's Synapse via the admin API
2. Add Matrix credentials to the new VM's Hermes `.env`
3. Join both bots to the 5 coordination rooms
4. Restart the gateway

---

## Updating MATRIX_ALLOWED_USERS

When you add a new bot, update all existing bots' `.env` to include the new bot in `MATRIX_ALLOWED_USERS`. For example, when adding `hermes-c` on VM-C, update both RODAN and MOGUERA's `.env` files:

```
MATRIX_ALLOWED_USERS=@admin:localhost,@rodan:localhost,@moguera:localhost
```
