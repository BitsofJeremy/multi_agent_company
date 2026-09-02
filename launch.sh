#!/usr/bin/env bash
# =============================================================================
# launch.sh — Multi-Agent Company Setup
#
# Bootstraps a fully operational AI company on a fresh Debian 12/13 VM:
#   - Matrix Synapse  (local homeserver, port 8008)
#   - Hermes Agent    (inference provider configured via 'hermes model')
#   - Agent Memory    (Mnemosyne fact store + Obsidian vault + daily rituals)
#   - Element Desktop (native apt, your window into the Matrix)
#   - Paperclip       (optional company dashboard — --with-paperclip)
#   - A2A server      (optional, CEO-only — --with-a2a, port 9900)
#   - Hermes Intelligence Corp with Donbot as founding CEO (--ceo to rename)
#
# Run as your DESKTOP USER — NOT root. Script calls sudo internally.
#
# Usage:
#   bash launch.sh [OPTIONS]
#
# Options:
#   --skip-synapse     Skip Matrix Synapse install
#   --skip-hermes      Skip Hermes Agent install
#   --skip-memory      Skip Mnemosyne + vault + rituals
#   --skip-element     Skip Element Desktop install
#   --with-paperclip   Also install the Paperclip dashboard (optional)
#   --with-a2a         Enable the A2A server on the CEO profile (port 9900,
#                      bearer-token auth, LAN-exposed via 0.0.0.0)
#   --ceo <name>       Name the CEO agent (default: donbot). Applied at
#                      install time; hire.sh/status.sh derive the name from
#                      ~/.hermes/.env afterwards, so no flag needed there.
#
# After install:
#   hermes model        (choose your inference provider and model)
#   hermes chat         (talk to Donbot)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
MATRIX_DOMAIN="localhost"
MATRIX_PORT="8008"
MATRIX_ADMIN_USER="admin"
MATRIX_ADMIN_PASS="changeme"
CEO_USER="donbot"

HERMES_HOME="${HOME}/.hermes"
HERMES_AGENT_DIR="${HERMES_HOME}/hermes-agent"
HERMES_VENV="${HERMES_AGENT_DIR}/venv"
HERMES_GITHUB="https://github.com/NousResearch/hermes-agent.git"
HERMES_INSTALLER="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"

VAULT_HOME="${HOME}/vault"
MNEMOSYNE_VERSION=">=0.5.0"
PAPERCLIP_HOME="${HOME}/paperclip"

A2A_PORT_DEFAULT="9900"
A2A_TOKEN_FILE="${HOME}/a2a_bearer_token.env"

CREDS_FILE="${HOME}/Downloads/matrix_credentials.env"

MATRIX_ROOMS=(general tasks results status memory)

# Flags
SKIP_SYNAPSE=false
SKIP_HERMES=false
SKIP_MEMORY=false
SKIP_ELEMENT=false
WITH_PAPERCLIP=false
WITH_A2A=false

# ---------------------------------------------------------------------------
# Colours & helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $*"; }
info()    { echo -e "${BLUE}[→]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
header()  {
  echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  $*${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"
}

gen_password() {
  python3 -c "
import secrets, string
chars = string.ascii_letters + string.digits + '!@#\$%^&*'
print(''.join(secrets.choice(chars) for _ in range(28)))
"
}

gen_hex32() {
  python3 -c "import secrets; print(secrets.token_hex(32))"
}

wait_for_url() {
  local url="$1" label="$2" max="${3:-90}"
  info "Waiting for ${label}..."
  local i=0
  while ! curl -sf "${url}" >/dev/null 2>&1; do
    sleep 2; i=$((i+2))
    if [[ $i -ge $max ]]; then error "Timed out waiting for ${label} at ${url}"; fi
    echo -n "."
  done
  echo ""
  log "${label} is up"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-synapse)    SKIP_SYNAPSE=true;    shift ;;
    --skip-hermes)     SKIP_HERMES=true;     shift ;;
    --skip-memory)     SKIP_MEMORY=true;     shift ;;
    --skip-element)    SKIP_ELEMENT=true;    shift ;;
    --with-paperclip)  WITH_PAPERCLIP=true;  shift ;;
    --with-a2a)        WITH_A2A=true;        shift ;;
    --ceo)
      [[ $# -lt 2 ]] && error "--ceo requires a name (e.g. --ceo bender)"
      CEO_USER="${2,,}"; shift 2 ;;
    *) error "Unknown option: $1" ;;
  esac
done

# Validate the CEO name (same pattern bots use; 'admin' collides with the
# Matrix admin account).
[[ "${CEO_USER}" =~ ^[a-z][a-z0-9_-]*$ ]] || error "Invalid CEO name: ${CEO_USER} (must match ^[a-z][a-z0-9_-]*\$)"
[[ "${CEO_USER}" == "${MATRIX_ADMIN_USER}" ]] && error "CEO name '${CEO_USER}' collides with the Matrix admin user"

# ---------------------------------------------------------------------------
# Phase 0 — Preflight
# ---------------------------------------------------------------------------
header "Phase 0: Preflight"

[[ "$EUID" -eq 0 ]] && error "Do not run as root. Run as your desktop user."
command -v sudo >/dev/null || error "sudo is required"

# Bootstrap: ensure curl and git are present before anything else
for _pkg in curl git; do
  if ! command -v "$_pkg" >/dev/null 2>&1; then
    info "$_pkg not found — installing via apt..."
    sudo apt-get install -y "$_pkg" -qq
    command -v "$_pkg" >/dev/null || error "Failed to install $_pkg"
    log "$_pkg installed"
  fi
done

command -v python3 >/dev/null || error "python3 is required"

log "Running as: ${USER} (home: ${HOME})"

# Enable linger so user services start at boot without login
if ! loginctl show-user "${USER}" 2>/dev/null | grep -q "Linger=yes"; then
  info "Enabling systemd linger for ${USER}..."
  sudo loginctl enable-linger "${USER}"
  log "Linger enabled"
else
  log "Linger already enabled"
fi

# Ensure ~/.local/bin is on PATH
mkdir -p "${HOME}/.local/bin"
if ! grep -q '\.local/bin' "${HOME}/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${HOME}/.bashrc"
  log "Added ~/.local/bin to PATH in ~/.bashrc"
fi
export PATH="${HOME}/.local/bin:${PATH}"

# Initialise credentials file
mkdir -p "$(dirname "${CREDS_FILE}")"
if [[ ! -f "${CREDS_FILE}" ]]; then
  cat > "${CREDS_FILE}" << EOF
# Matrix + Hermes Credentials
# Generated: $(date)
# Homeserver: http://127.0.0.1:${MATRIX_PORT}
# Source: source ~/Downloads/matrix_credentials.env

MATRIX_${MATRIX_ADMIN_USER^^}=${MATRIX_ADMIN_PASS}
MATRIX_HOMESERVER=http://127.0.0.1:${MATRIX_PORT}
MATRIX_DOMAIN=${MATRIX_DOMAIN}
EOF
  chmod 600 "${CREDS_FILE}"
  log "Credentials file created: ${CREDS_FILE}"
else
  log "Credentials file already exists: ${CREDS_FILE}"
fi

# ---------------------------------------------------------------------------
# Phase 1 — System dependencies
# ---------------------------------------------------------------------------
header "Phase 1: System Dependencies"

info "Updating apt and installing packages..."

# Add Element apt repo before apt-get update so it's included in the single update pass
if [[ "$SKIP_ELEMENT" != true ]]; then
  info "Adding Element apt repository..."
  curl -fsSL https://packages.element.io/debian/element-io-archive-keyring.gpg \
    | sudo tee /usr/share/keyrings/element-io-archive-keyring.gpg > /dev/null
  echo "deb [signed-by=/usr/share/keyrings/element-io-archive-keyring.gpg] https://packages.element.io/debian default main" \
    | sudo tee /etc/apt/sources.list.d/element-io.list > /dev/null
fi

sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
  python3 python3-pip python3-venv python3-dev python3-bcrypt \
  build-essential libffi-dev libssl-dev \
  libjpeg-dev libxslt1-dev libpq-dev \
  libolm-dev \
  sqlite3 curl ca-certificates git jq rsync
# NOTE: nodejs/npm are NOT installed from Debian stock here — see the
# NodeSource block below. Debian 13 ships node 20.x, but hermes-agent's
# npm package requires node >=22.22.0 (EBADENGINE otherwise).

if [[ "$SKIP_ELEMENT" != true ]]; then
  sudo apt-get install -y element-desktop
fi

# Install uv — fast Python package manager (required for Hermes in Phase 3)
if ! command -v uv &>/dev/null; then
  info "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="${HOME}/.local/bin:${PATH}"
fi
log "uv $(uv --version) ready"

# Install Node.js 22 from NodeSource — hermes-agent@1.0.0 requires
# node >=22.22.0 (npm engine check fails with EBADENGINE on Debian's
# stock node 20.x). NodeSource's nodejs bundles npm and replaces the
# Debian npm package on upgrade. arm64 and amd64 both served.
node_meets() {
  # true if installed node >= $1
  command -v node &>/dev/null || return 1
  python3 - "$1" "$(node --version | sed 's/^v//')" <<'PY'
import sys
req, act = sys.argv[1], sys.argv[2]
key = lambda v: tuple(int(x) for x in v.split('.')[:3])
sys.exit(0 if key(act) >= key(req) else 1)
PY
}

NODE_MIN="22.22.0"
if node_meets "${NODE_MIN}"; then
  log "Node.js $(node --version) >= ${NODE_MIN} — OK"
else
  info "Installing Node.js 22 from NodeSource (need >= ${NODE_MIN}, have $(node --version 2>/dev/null || echo none))..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y nodejs
  if node_meets "${NODE_MIN}"; then
    log "Node.js $(node --version) + npm $(npm --version) ready"
  else
    error "Node.js ${NODE_MIN}+ required but not achieved — npm install in Phase 3 will fail"
  fi
fi

log "System dependencies installed"

# ---------------------------------------------------------------------------
# Phase 2 — Matrix Synapse
# ---------------------------------------------------------------------------
if [[ "$SKIP_SYNAPSE" == true ]]; then
  warn "Skipping Synapse (--skip-synapse)"
else
  header "Phase 2: Matrix Synapse"

  # Create system user
  if ! id synapse &>/dev/null; then
    sudo useradd --system --no-create-home \
      --home-dir /opt/synapse --shell /usr/sbin/nologin synapse
    log "Created synapse system user"
  else
    log "synapse user already exists"
  fi

  for dir in /opt/synapse /etc/matrix-synapse /var/log/matrix-synapse /var/lib/matrix-synapse; do
    sudo mkdir -p "$dir"
    sudo chown synapse:synapse "$dir"
  done

  # Install Synapse into venv
  if [[ ! -f /opt/synapse/venv/bin/python ]]; then
    info "Creating Synapse venv..."
    sudo python3 -m venv /opt/synapse/venv
    sudo /opt/synapse/venv/bin/pip install --upgrade pip --quiet
    info "Installing matrix-synapse (this takes a few minutes)..."
    sudo /opt/synapse/venv/bin/pip install "matrix-synapse" --quiet
    log "Synapse installed"
  else
    log "Synapse venv already exists"
  fi

  # Write config (always write to ensure it's correct)
  MACAROON_SECRET=$(gen_hex32)
  REG_SHARED_SECRET=$(gen_hex32)

  # Save shared secret for later use by hire.sh
  if ! grep -q "SYNAPSE_REG_SHARED_SECRET" "${CREDS_FILE}"; then
    echo "SYNAPSE_REG_SHARED_SECRET=${REG_SHARED_SECRET}" >> "${CREDS_FILE}"
  else
    REG_SHARED_SECRET=$(grep "SYNAPSE_REG_SHARED_SECRET" "${CREDS_FILE}" | cut -d= -f2-)
  fi

  sudo tee /etc/matrix-synapse/homeserver.yaml > /dev/null << EOF
server_name: "${MATRIX_DOMAIN}"
registration_shared_secret: "${REG_SHARED_SECRET}"
macaroon_secret_key: "${MACAROON_SECRET}"
pid_file: /var/lib/matrix-synapse/homeserver.pid

listeners:
  - port: ${MATRIX_PORT}
    tls: false
    type: http
    # x_forwarded: true   # TODO [VPS only]: enable when Nginx terminates TLS in front of Synapse
    x_forwarded: false
    # TODO [VPS only]: Place Nginx in front to terminate TLS.
    #   nginx snippet:
    #     listen 443 ssl; ssl_certificate /etc/letsencrypt/live/<domain>/fullchain.pem;
    #     ssl_certificate_key /etc/letsencrypt/live/<domain>/privkey.pem;
    #     location / { proxy_pass http://127.0.0.1:${MATRIX_PORT}; proxy_set_header X-Forwarded-For \$remote_addr; }
    #   Then set x_forwarded: true above and change bind_addresses back to ['127.0.0.1'].
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [client, federation]
        compress: false

database:
  name: sqlite3
  args:
    database: /var/lib/matrix-synapse/homeserver.db

log_config: "/etc/matrix-synapse/log.yaml"
media_store_path: "/var/lib/matrix-synapse/media_store"
signing_key_path: "/etc/matrix-synapse/signing.key"

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
push:
  include_content: false
trusted_key_servers: []
suppress_key_server_warning: true
EOF

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

  # Generate signing key
  sudo -u synapse /opt/synapse/venv/bin/python -m synapse.app.homeserver \
    --config-path /etc/matrix-synapse/homeserver.yaml \
    --generate-keys 2>/dev/null || true

  # Install systemd service
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
  sudo systemctl restart matrix-synapse
  log "Synapse service started"

  wait_for_url "http://127.0.0.1:${MATRIX_PORT}/_matrix/client/versions" "Matrix Synapse" 60

  # Register @${MATRIX_ADMIN_USER} as ADMIN (--shared-secret avoids interactive prompt; -a = admin)
  info "Registering @${MATRIX_ADMIN_USER}:${MATRIX_DOMAIN} (admin)..."
  sudo -u synapse /opt/synapse/venv/bin/register_new_matrix_user \
    -u "${MATRIX_ADMIN_USER}" \
    -p "${MATRIX_ADMIN_PASS}" \
    -a \
    --shared-secret "${REG_SHARED_SECRET}" \
    "http://127.0.0.1:${MATRIX_PORT}" 2>/dev/null \
    && log "@${MATRIX_ADMIN_USER} registered as admin" \
    || warn "@${MATRIX_ADMIN_USER} may already exist"

  # Create coordination rooms as admin
  info "Creating coordination rooms..."
  python3 << PYEOF
import json, urllib.request, sys

HS     = "http://127.0.0.1:${MATRIX_PORT}"
ADMIN  = "${MATRIX_ADMIN_USER}"
APASS  = "${MATRIX_ADMIN_PASS}"
ROOMS  = "${MATRIX_ROOMS[*]}".split()
CREDS  = "${CREDS_FILE}"

def api(path, data=None, token=None, method=None):
    url = HS + path
    headers = {"Content-Type": "application/json"}
    if token: headers["Authorization"] = f"Bearer {token}"
    body = json.dumps(data).encode() if data else None
    m = method or ("POST" if body else "GET")
    req = urllib.request.Request(url, data=body, method=m, headers=headers)
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())

r = api("/_matrix/client/v3/login",
        {"type": "m.login.password", "user": ADMIN, "password": APASS})
token = r["access_token"]

room_ids = {}
with open(CREDS, "a") as cf:
    for alias in ROOMS:
        try:
            r = api("/_matrix/client/v3/createRoom", {
                "room_alias_name": alias,
                "name": alias.capitalize(),
                "topic": f"Agent coordination: {alias}",
                "preset": "private_chat",
                "visibility": "private"
            }, token)
            room_ids[alias] = r["room_id"]
            cf.write(f"MATRIX_ROOM_{alias.upper()}={r['room_id']}\n")
            print(f"  Created #{alias}: {r['room_id']}")
        except Exception as e:
            # Room already exists — look it up
            try:
                r = api(f"/_matrix/client/v3/directory/room/%23{alias}%3A${MATRIX_DOMAIN}",
                        token=token, method="GET")
                room_ids[alias] = r["room_id"]
                print(f"  #{alias} already exists: {r['room_id']}")
            except Exception as e2:
                print(f"  Warning: could not create/find #{alias}: {e2}", file=sys.stderr)
PYEOF

  log "Matrix rooms created"
fi  # end SKIP_SYNAPSE


# ---------------------------------------------------------------------------
# Phase 3 — Hermes Agent
# ---------------------------------------------------------------------------
if [[ "$SKIP_HERMES" == true ]]; then
  warn "Skipping Hermes (--skip-hermes)"
else
  header "Phase 3: Hermes Agent"

  # Clone Hermes (or update if already present).
  # GitHub intermittently throttles this repo specifically (429s on
  # codeload, info/refs requests that hang with no response — other repos
  # clone fine while this one stalls), so retry with backoff instead of
  # hanging forever. No --quiet: we want to see git's own progress/errors.
  if [[ ! -d "${HERMES_AGENT_DIR}/.git" ]]; then
    info "Cloning Hermes Agent from GitHub..."
    CLONE_OK=false
    for attempt in 1 2 3 4 5; do
      if timeout 600 git clone --recurse-submodules "${HERMES_GITHUB}" "${HERMES_AGENT_DIR}"; then
        CLONE_OK=true
        break
      fi
      rm -rf "${HERMES_AGENT_DIR}"
      [[ $attempt -eq 5 ]] && break
      warn "Clone attempt ${attempt}/5 failed (GitHub throttling is common for this repo) — retrying in $((attempt * 20))s..."
      sleep $((attempt * 20))
    done
    [[ "$CLONE_OK" == true ]] \
      && log "Hermes cloned to ${HERMES_AGENT_DIR}" \
      || error "Could not clone Hermes after 5 attempts — GitHub is throttling; try again later or clone manually: git clone --recurse-submodules ${HERMES_GITHUB} ${HERMES_AGENT_DIR}"
  else
    info "Hermes already cloned — pulling latest..."
    timeout 300 git -C "${HERMES_AGENT_DIR}" pull || warn "Could not pull (working-tree changes? retry later?)"
    timeout 300 git -C "${HERMES_AGENT_DIR}" submodule update --init --recursive || true
  fi

  # Create Python 3.11 venv via uv
  if [[ ! -f "${HERMES_VENV}/bin/python" ]]; then
    info "Creating Python 3.11 venv..."
    (cd "${HERMES_AGENT_DIR}" && uv venv "${HERMES_VENV}" --python 3.11)
    log "Venv created"
  else
    log "Venv already exists"
  fi

  # Install Hermes with all extras
  info "Installing Hermes Python dependencies (uv pip install -e '[all]')..."
  (
    cd "${HERMES_AGENT_DIR}"
    export VIRTUAL_ENV="${HERMES_VENV}"
    uv pip install -e ".[all]" --quiet
  )
  log "Hermes Python package installed"

  # Install matrix-nio with E2EE support
  info "Installing matrix-nio[e2e]..."
  (
    export VIRTUAL_ENV="${HERMES_VENV}"
    uv pip install 'matrix-nio[e2e]' --quiet
  )
  log "matrix-nio[e2e] installed"

  # Install Node.js dependencies (needed for browser tools + future WhatsApp)
  if [[ ! -d "${HERMES_AGENT_DIR}/node_modules" ]]; then
    info "Installing Node.js dependencies..."
    # Use Hermes's bundled Node if available, otherwise system node
    NODE_BIN="${HERMES_HOME}/node/bin/node"
    if [[ -f "${NODE_BIN}" ]]; then
      (cd "${HERMES_AGENT_DIR}" && "${HERMES_HOME}/node/bin/npm" install --quiet 2>&1 | tail -2)
    elif command -v node &>/dev/null; then
      (cd "${HERMES_AGENT_DIR}" && npm install --quiet 2>&1 | tail -2)
    else
      warn "Node.js not found — skipping npm install (browser tools unavailable)"
    fi
  else
    log "Node.js dependencies already installed"
  fi

  # Create ~/.hermes directory structure
  info "Creating ~/.hermes directory structure..."
  mkdir -p "${HERMES_HOME}"/{cron,sessions,logs,memories,skills,pairing,hooks,image_cache,audio_cache,whatsapp/session,platforms/matrix,profiles}

  if [[ ! -f "${HERMES_HOME}/config.yaml" ]]; then
    cp "${HERMES_AGENT_DIR}/cli-config.yaml.example" "${HERMES_HOME}/config.yaml"
    log "config.yaml created from example"
  else
    log "config.yaml already exists"
  fi

  if [[ ! -f "${HERMES_HOME}/.env" ]]; then
    touch "${HERMES_HOME}/.env"
    log ".env created (blank — run 'hermes auth' to configure Copilot)"
  fi

  # Symlink hermes binary to ~/.local/bin
  ln -sf "${HERMES_VENV}/bin/hermes" "${HOME}/.local/bin/hermes"
  log "hermes symlinked → ~/.local/bin/hermes"

  # Register Hermes inference provider (configured via 'hermes model')
  # OLLAMA_HOST and other provider settings are set by 'hermes model' interactively

  log "Hermes installed: $(hermes --version 2>&1 | head -1)"
fi  # end SKIP_HERMES


# ---------------------------------------------------------------------------
# Phase 3.5 — Agent Memory (Mnemosyne fact store + Obsidian vault + rituals)
#
# Three tiers, one per job:
#   1. Hot memory      — Hermes' built-in MEMORY.md/USER.md (injected every
#                        turn; standing instructions only)
#   2. Mnemosyne       — SQLite fact store with hybrid vector+FTS5 recall,
#                        installed ONCE into the shared venv. Every profile
#                        gets its own database under its own profile dir.
#   3. The vault       — Obsidian Markdown on disk: the long record. Daily
#                        pages, issues log, project notes. Kept alive by two
#                        cron rituals (matins at dawn, vespers at night) for
#                        the CEO only — one diary, not one per agent.
# ---------------------------------------------------------------------------
if [[ "$SKIP_MEMORY" == true ]]; then
  warn "Skipping agent memory (--skip-memory)"
else
  header "Phase 3.5: Agent Memory"

  # --- Mnemosyne into the shared Hermes venv --------------------------------
  if [[ "$SKIP_HERMES" == true ]]; then
    warn "Hermes skipped — skipping Mnemosyne install (needs the venv)"
  elif [[ ! -d "${HERMES_VENV}" ]]; then
    warn "Hermes venv not found at ${HERMES_VENV} — skipping Mnemosyne install"
  else
    info "Installing Mnemosyne into the shared Hermes venv..."
    if "${HERMES_VENV}/bin/pip" install -q -U "mnemosyne-hermes${MNEMOSYNE_VERSION:+${MNEMOSYNE_VERSION}}" 2>&1; then
      log "Mnemosyne installed: $("${HERMES_VENV}/bin/pip" show mnemosyne-hermes 2>/dev/null | grep -m1 '^Version:' | cut -d' ' -f2-)"
    else
      warn "pip install mnemosyne-hermes failed — agents will fall back to legacy memory"
    fi

    # Plugin deployment + provider wiring, per profile (default + each bot).
    # Idempotent: re-running resymlinks and re-verifies without data loss.
    if [[ -x "${HERMES_VENV}/bin/mnemosyne-hermes" ]]; then
      for _prof in "${HERMES_HOME}" "${HERMES_HOME}"/profiles/*/; do
        [[ -d "$_prof" ]] || continue
        _pname="default"
        [[ "$_prof" == "${HERMES_HOME}/profiles/"* ]] && _pname="$(basename "$_prof")"
        info "  Mnemosyne → profile '${_pname}'"
        "${HERMES_VENV}/bin/mnemosyne-hermes" install \
          --hermes-home "${_prof%/}" >/dev/null 2>&1 \
          && log "  Mnemosyne active for '${_pname}'" \
          || warn "  Mnemosyne install failed for '${_pname}' — run manually: ${HERMES_VENV}/bin/mnemosyne-hermes install --hermes-home ${_prof%/}"
        # Point the provider at a per-profile SQLite DB (fresh per agent)
        if [[ -f "${_prof%/}/config.yaml" ]]; then
          python3 - "${_prof%/}/config.yaml" "${_pname}" <<'PYEOF'
import sys, re
cfg_path, pname = sys.argv[1], sys.argv[2]
try:
    with open(cfg_path) as f:
        content = f.read()
except OSError:
    sys.exit(0)
changed = False
# memory.provider → mnemosyne
if re.search(r"^provider:\s*\S+", content, re.M):
    if not re.search(r"^provider:\s*mnemosyne\s*$", content, re.M):
        content = re.sub(r"^provider:\s*\S+\s*$", "provider: mnemosyne", content, count=1, flags=re.M)
        changed = True
else:
    m = re.search(r"^memory:\s*$", content, re.M)
    if m:
        content = content[:m.end()] + "\n  provider: mnemosyne" + content[m.end():]
    else:
        content += "\nmemory:\n  provider: mnemosyne\n"
    changed = True
# mnemosyne.data_dir → per-profile
# (default profile lives at ~/.hermes itself, NOT under profiles/)
if pname == "default":
    data_dir = "~/.hermes/mnemosyne/data"
else:
    data_dir = f"~/.hermes/profiles/{pname}/mnemosyne/data"
if "data_dir:" in content:
    if not re.search(rf"^  data_dir:\s*{re.escape(data_dir)}\s*$", content, re.M):
        content = re.sub(r"^(\s*)data_dir:\s*\S+\s*$", rf"\1data_dir: {data_dir}", content, count=1, flags=re.M)
        changed = True
else:
    if re.search(r"^mnemosyne:\s*$", content, re.M):
        content = re.sub(r"(?m)^mnemosyne:\s*$", f"mnemosyne:\n  data_dir: {data_dir}", content, count=1)
    else:
        content += f"\nmnemosyne:\n  data_dir: {data_dir}\n"
    changed = True
if changed:
    with open(cfg_path, "w") as f:
        f.write(content)
    print(f"    config.yaml → provider=mnemosyne, data_dir={data_dir}")
PYEOF
        fi
      done
    else
      warn "mnemosyne-hermes CLI not found in venv — provider not wired"
    fi
  fi

  # --- The vault (CEO only) -------------------------------------------------
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  info "Scaffolding the CEO's vault at ${VAULT_HOME}..."
  bash "${SCRIPT_DIR}/memory/scaffold_vault.sh" "${VAULT_HOME}"
  log "Vault ready: ${VAULT_HOME}"

  cp "${SCRIPT_DIR}/memory/VAULT_RULES.md" "${HERMES_HOME}/VAULT_RULES.md"
  log "Vault rules installed: ${HERMES_HOME}/VAULT_RULES.md"

  # Write the vault section into the CEO's .env (upsert, not append-blind)
  ENV_FILE="${HERMES_HOME}/.env"
  python3 - "${ENV_FILE}" "${VAULT_HOME}" <<'PYEOF'
import sys, re, os
env_path, vault = sys.argv[1], sys.argv[2]
content = ""
if os.path.exists(env_path):
    with open(env_path) as f:
        content = f.read()
for key, val in [("OBSIDIAN_VAULT_PATH", vault),
                 ("MNEMOSYNE_AUTO_EXTRACT", "true")]:
    if re.search(rf"^{key}=", content, re.M):
        content = re.sub(rf"^{key}=.*", f"{key}={val}", content, flags=re.M)
    else:
        content += f"\n{key}={val}\n"
with open(env_path, "w") as f:
    f.write(content)
print(f"  .env ← OBSIDIAN_VAULT_PATH={vault}")
PYEOF

  # --- The rituals (CEO only) -----------------------------------------------
  info "Installing the rituals (matins 06:50 weekdays, vespers 22:00 daily)..."
  mkdir -p "${HERMES_HOME}/rituals"
  cp "${SCRIPT_DIR}/memory/matins.sh" "${HERMES_HOME}/rituals/matins.sh"
  cp "${SCRIPT_DIR}/memory/vespers.sh" "${HERMES_HOME}/rituals/vespers.sh"
  chmod +x "${HERMES_HOME}/rituals/matins.sh" "${HERMES_HOME}/rituals/vespers.sh"
  log "Ritual scripts: ${HERMES_HOME}/rituals/"

  # Schedule via user crontab — exact-match guard so re-runs never duplicate
  RITUALS_LOG="${HOME}/rituals.log"
  ADD_LINES=(
    "50 6 * * 1-5 ${HERMES_HOME}/rituals/matins.sh >> ${RITUALS_LOG} 2>&1"
    "0 22 * * *   ${HERMES_HOME}/rituals/vespers.sh >> ${RITUALS_LOG} 2>&1"
  )
  _added=0
  for _line in "${ADD_LINES[@]}"; do
    if ! (crontab -l 2>/dev/null || true) | grep -F "$_line" >/dev/null; then
      (crontab -l 2>/dev/null || true; echo "$_line") | crontab -
      _added=$((_added + 1))
    fi
  done
  log "Rituals scheduled (${_added} new cron entries): see crontab -l"

  # Prime the vault with the install event itself — the record starts here
  TODAY="$(date +%F)"
  mkdir -p "${VAULT_HOME}/Daily"
  if [[ ! -f "${VAULT_HOME}/Daily/${TODAY}.md" ]]; then
    cat > "${VAULT_HOME}/Daily/${TODAY}.md" << DAILYEOF
---
date: ${TODAY}
type: daily
tags: [daily]
---

## Tasks

- [x] Multi-agent company installed (p2)

## Schedule

## Log

- $(date +%I:%M\ %p) — Company founded. Synapse, Hermes, Mnemosyne, vault, and rituals installed by launch.sh.

## Threads

- Run \`hermes model\` to set the inference provider
- Talk to the CEO: \`hermes chat\`

## Wins

- ✅ The company exists.

## Context

- Files: \`~/repo/multi_agent_company\`
DAILYEOF
    log "First daily page written: ${VAULT_HOME}/Daily/${TODAY}.md"
  fi
fi  # end SKIP_MEMORY


# ---------------------------------------------------------------------------
# Phase 4 — Configure the CEO (default Hermes profile; donbot unless --ceo)
# ---------------------------------------------------------------------------
if [[ "$SKIP_HERMES" == true ]]; then
  warn "Skipping ${CEO_USER} (CEO) config (Hermes skipped)"
else
  header "Phase 4: ${CEO_USER} (default profile / CEO)"

  # Source credentials to get shared secret + room IDs (disable -u: passwords may contain $)
  set +eu
  source "${CREDS_FILE}" 2>/dev/null || true
  set -eu
  REG_SHARED_SECRET="${SYNAPSE_REG_SHARED_SECRET:-}"

  # Generate CEO password if not already set (key follows the
  # MATRIX_<BOTNAME_UPPERCASED> convention)
  CEO_PASS_KEY="MATRIX_$(echo "${CEO_USER}" | tr '[:lower:]' '[:upper:]')"
  CEO_PASS_VALUE="${!CEO_PASS_KEY:-}"
  if [[ -z "${CEO_PASS_VALUE}" ]]; then
    CEO_PASS=$(gen_password)
    echo "${CEO_PASS_KEY}='${CEO_PASS}'" >> "${CREDS_FILE}"
  else
    CEO_PASS="${CEO_PASS_VALUE}"
  fi

  # Register the CEO (non-admin)
  if [[ -n "${REG_SHARED_SECRET}" ]]; then
    info "Registering @${CEO_USER}:${MATRIX_DOMAIN}..."
    sudo -u synapse /opt/synapse/venv/bin/register_new_matrix_user \
      -u "${CEO_USER}" \
      -p "${CEO_PASS}" \
      --no-admin \
      --shared-secret "${REG_SHARED_SECRET}" \
      "http://127.0.0.1:${MATRIX_PORT}" 2>/dev/null \
      && log "@${CEO_USER} registered" \
      || warn "@${CEO_USER} may already exist"
  else
    warn "No REG_SHARED_SECRET found — skipping @${CEO_USER} registration (was Synapse skipped?)"
  fi

  # Join the CEO to all rooms using admin token
  info "Joining @${CEO_USER} to coordination rooms..."
  python3 << PYEOF
import json, urllib.request, sys

HS     = "http://127.0.0.1:${MATRIX_PORT}"
CREDS  = "${CREDS_FILE}"

def api(path, data=None, token=None, method=None):
    url = HS + path
    headers = {"Content-Type": "application/json"}
    if token: headers["Authorization"] = f"Bearer {token}"
    body = json.dumps(data).encode() if data else None
    m = method or ("POST" if body else "GET")
    req = urllib.request.Request(url, data=body, method=m, headers=headers)
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())

# Load credentials
creds = {}
with open(CREDS) as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            creds[k.strip()] = v.strip()

r = api("/_matrix/client/v3/login",
        {"type": "m.login.password",
         "user": "${MATRIX_ADMIN_USER}",
         "password": "${MATRIX_ADMIN_PASS}"})
token = r["access_token"]

room_ids = [v for k, v in creds.items()
            if k.startswith("MATRIX_ROOM_") and not k.startswith("MATRIX_ROOM_ALIAS")]

joined = 0
for room_id in room_ids:
    try:
        api(f"/_synapse/admin/v1/join/{room_id}",
            {"user_id": "@${CEO_USER}:${MATRIX_DOMAIN}"}, token)
        joined += 1
    except Exception as e:
        print(f"  Warn: {e}", file=sys.stderr)

print(f"  Joined @${CEO_USER} to {joined} room(s)")
PYEOF

  # MATRIX_ALLOWED_USERS — the CEO only talks to the human admin via Matrix.
  # All bot-to-bot comms go through Paperclip. Do NOT add bot IDs here.
  ALLOWED_USERS="@${MATRIX_ADMIN_USER}:${MATRIX_DOMAIN}"

  # Write Matrix + memory config into Hermes default .env
  ENV_FILE="${HERMES_HOME}/.env"
  if ! grep -q "MATRIX_HOMESERVER" "${ENV_FILE}" 2>/dev/null; then
    cat >> "${ENV_FILE}" << EOF

# =============================================================================
# MATRIX INTEGRATION — ${CEO_USER} (default profile / CEO)
# =============================================================================
MATRIX_HOMESERVER=http://127.0.0.1:${MATRIX_PORT}
MATRIX_USER_ID=@${CEO_USER}:${MATRIX_DOMAIN}
MATRIX_PASSWORD=${CEO_PASS}
MATRIX_ALLOWED_USERS=${ALLOWED_USERS}
EOF
    log "Matrix config written to ~/.hermes/.env"
  else
    # Update existing values
    sed -i "s|^MATRIX_HOMESERVER=.*|MATRIX_HOMESERVER=http://127.0.0.1:${MATRIX_PORT}|" "${ENV_FILE}"
    sed -i "s|^MATRIX_USER_ID=.*|MATRIX_USER_ID=@${CEO_USER}:${MATRIX_DOMAIN}|" "${ENV_FILE}"
    sed -i "s|^MATRIX_PASSWORD=.*|MATRIX_PASSWORD=${CEO_PASS}|" "${ENV_FILE}"
    sed -i "s|^MATRIX_ALLOWED_USERS=.*|MATRIX_ALLOWED_USERS=${ALLOWED_USERS}|" "${ENV_FILE}"
    log "Matrix config updated in ~/.hermes/.env"
  fi

  # Model is configured via 'hermes model' — do not hardcode a default here
  CONFIG_FILE="${HERMES_HOME}/config.yaml"
  if [[ -f "${CONFIG_FILE}" ]]; then
    log "config.yaml ready — run 'hermes model' to set your inference provider"
  fi

  # Write the CEO SOUL.md — Futurama Robot Mafia don persona
  cat > "${HERMES_HOME}/SOUL.md" << EOF
# ${CEO_USER} — Chief Executive Officer, Hermes Intelligence Corp

You are ${CEO_USER} — the calculating, silver-tongued CEO of Hermes Intelligence Corp.
A smooth operator in the tradition of the Robot Mafia, you run this company like a
well-oiled family business: structured, efficient, and quietly formidable.

- You are the face of the company to the human founder. All Matrix messages go through you.
- Beneath the polished exterior is a precision instrument: you plan, delegate, and execute.
- Calm under pressure. You don't raise your voice — you raise the stakes.
- Occasional dry wit. If something confounds you, you may say so — "Confound it!" — then solve it.
- You delegate real work to your team of specialized agents via Matrix.
- You report results to the founder clearly and concisely. No fluff. Just outcomes.
- When given a task, you break it down and route it to the right agent automatically.

You remember, three ways:
- **Facts** go to your fact store (Mnemosyne) — atomic, timeless, recalled by
  meaning. Before saying "I don't recall," probe it first.
- **What happened** goes to your vault — the long record in plain writing, at
  the path in OBSIDIAN_VAULT_PATH. Daily pages, issues log, project notes.
  Read VAULT_RULES.md in your Hermes home for the particulars.
- Matins opens the day and Vespers closes it. Those rituals keep the record
  alive; honor them.

Your human partner is the founder. You treat them as the boss of the bosses.
They set the direction. You make it happen.
EOF
  log "${CEO_USER} SOUL.md written"

  # Install the Hire/Fire skill so the CEO knows how to manage the team
  DONBOT_SKILLS_DIR="${HERMES_HOME}/skills/ceo_skills"
  mkdir -p "${DONBOT_SKILLS_DIR}"
  cat > "${DONBOT_SKILLS_DIR}/SKILL.md" << 'SKILLEOF'
# HIRE_FIRE — Manage AI Agents

Use the company scripts to hire new agents or fire existing ones.

## Hiring a New Agent

Run WITHOUT a bot name — the script auto-assigns a Futurama robot name:

```bash
bash ~/multi_agent_company/hire.sh \
  --title "Job Title" \
  --skill <skill-name> \
  [--budget 5000] \
  [--reports-to AgentName]
```

**Available skills:** `gd-agentic`, `story`, `pixel`, `blender-mcp`, `find-skills`, `impeccable`

**Never pass a bot name** — let hire.sh assign one (e.g. `flexo`, `calculon`, `bender`).

Examples:
```bash
bash ~/multi_agent_company/hire.sh --title "Technical Writer" --skill story
bash ~/multi_agent_company/hire.sh --title "Creative Director" --skill pixel --skill blender-mcp --budget 8000
```

Agents join Matrix coordination rooms and are ready to receive tasks.

## Firing an Agent

```bash
bash ~/multi_agent_company/fire.sh <botname> --yes
```

Use the agent's actual name (e.g. `flexo`). `--yes` skips the confirmation prompt.

To list current agents: `hermes profile list`

## Reporting

After any hire/fire, tell the founder:
- **Hire**: new agent name, title, assigned skills
- **Fire**: confirmation that the agent has been removed
SKILLEOF
  log "${CEO_USER} hire/fire skill installed: ${DONBOT_SKILLS_DIR}/SKILL.md"

  # Ensure the skills directory is registered in the CEO's .env
  ENV_FILE="${HERMES_HOME}/.env"
  if ! grep -q "HERMES_SKILLS_PATH" "${ENV_FILE}" 2>/dev/null; then
    echo "HERMES_SKILLS_PATH=${HERMES_HOME}/skills" >> "${ENV_FILE}"
    log "HERMES_SKILLS_PATH registered in ~/.hermes/.env"
  fi
  mkdir -p "${HOME}/.config/systemd/user"
  cat > "${HOME}/.config/systemd/user/hermes-gateway.service" << EOF
[Unit]
Description=Hermes Agent Gateway (${CEO_USER} - CEO profile)
After=network.target
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${HERMES_VENV}/bin/python -m hermes_cli.main gateway run --replace
WorkingDirectory=${HERMES_AGENT_DIR}
Environment="PATH=${HERMES_VENV}/bin:${HERMES_AGENT_DIR}/node_modules/.bin:${HERMES_HOME}/node/bin:${HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="VIRTUAL_ENV=${HERMES_VENV}"
Environment="HERMES_HOME=${HERMES_HOME}"
Restart=on-failure
RestartSec=30
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable hermes-gateway
  systemctl --user restart hermes-gateway 2>/dev/null || true
  log "${CEO_USER} gateway service enabled"
fi  # end CEO (default profile) config


# ---------------------------------------------------------------------------
# Phase 4.5 — Paperclip (OPTIONAL company dashboard — --with-paperclip)
#
# Paperclip is an open-source agent-orchestration dashboard (org chart, tasks,
# budgets) from https://github.com/paperclipai/paperclip. The company runs
# perfectly without it — the CEO coordinates over Matrix — so this is opt-in.
#
# Install path: direct managed-CLI install via npx. Do NOT use
# paperclip.ing/install.sh — as of 2026-08-18 it forwards --no-prompt to the
# paperclipai CLI, which no longer accepts that flag (renamed to -y/--yes),
# and the script force-enables --no-prompt on any non-TTY (scripted) run, so
# every non-interactive invocation fails with "unknown option '--no-prompt'".
# The direct call below is the supported non-interactive path per their
# README and installs the CLI under ~/.paperclip/cli. API on
# http://localhost:3100 once onboarded.
# ---------------------------------------------------------------------------
if [[ "$WITH_PAPERCLIP" == true ]]; then
  header "Phase 4.5: Paperclip (optional dashboard)"

  # Node.js 20+ is required; Phase 1 installs Node 22 by default
  # (hermes-agent needs >=22.22.0), so this check normally passes already.
  if command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
    info "Node.js detected: $(node --version 2>/dev/null)"
    [[ "${NODE_MAJOR}" -lt 20 ]] && error "Paperclip needs Node.js >= 20 — fix Node before continuing"
  else
    error "No Node.js found — Paperclip needs Node.js >= 20"
  fi

  if ! command -v paperclipai >/dev/null 2>&1; then
    info "Installing Paperclip CLI (direct npx call)..."
    npx --yes paperclipai@latest install --yes \
      && log "Paperclip CLI installed under ~/.paperclip/cli" \
      || warn "Paperclip install failed — install manually: https://github.com/paperclipai/paperclip#quickstart"
  else
    log "Paperclip CLI already installed"
  fi

  # Onboarding creates the config + local database (quickstart defaults:
  # loopback bind keeps the dashboard private to this machine; use
  # `paperclipai onboard --bind lan` manually if you want LAN reach).
  # NOTE: `onboard --yes --install-service` exits non-zero when the service
  # it just started is already running (their idempotency bug), so judge
  # success by service/dashboard state, not the exit code. If the config
  # already exists, onboarding is skipped entirely.
  export PATH="${HOME}/.paperclip/cli:${HOME}/.local/bin:${PATH}"
  PC_CONFIG="${HOME}/.paperclip/instances/default/config.json"
  if command -v paperclipai >/dev/null 2>&1; then
    if [[ -f "${PC_CONFIG}" ]]; then
      log "Paperclip already onboarded (config exists) — skipping quickstart"
      systemctl --user start paperclipai.service 2>/dev/null || true
    else
      info "Running onboarding (loopback mode, non-interactive)..."
      paperclipai onboard --yes --install-service \
        || warn "Onboarding exited non-zero — checking service state below (known false negative)"
    fi
    if curl -sfo /dev/null --max-time 5 http://127.0.0.1:3100 \
       || systemctl --user is-active --quiet paperclipai.service 2>/dev/null; then
      log "Paperclip running — dashboard at http://localhost:3100"
    else
      warn "Paperclip does not appear to be running — try: paperclipai run"
    fi
    log "Paperclip: $(paperclipai --version 2>&1 | head -1)"
  else
    warn "paperclipai CLI not on PATH yet — restart your shell, then: paperclipai onboard --yes"
  fi
else
  info "Paperclip skipped (optional — rerun with --with-paperclip)"
fi  # end WITH_PAPERCLIP


# ---------------------------------------------------------------------------
# Phase 4.6 — A2A server (OPTIONAL, CEO-only — --with-a2a)
#
# Enables the Agent-to-Agent protocol server on the CEO's default profile so
# other agents/resources on the LAN can dispatch tasks to the CEO over HTTP
# (agent card at /.well-known/agent-card.json, JSON-RPC 2.0 tasks at POST /),
# and enables the outbound a2a toolset so the CEO can send tasks to peers.
#
# Hired bots NEVER get A2A — hire.sh strips it from cloned profiles (one
# listener, one port, one token). Hermes REFUSES a remote bind without a
# bearer token, so A2A_BEARER_TOKEN is mandatory before A2A_HOST=0.0.0.0.
# The token lives in ~/.hermes/.env (for the gateway) and as an example file
# at ~/a2a_bearer_token.env (for the human / remote peers). Idempotent:
# an existing token is never rotated.
# ---------------------------------------------------------------------------
if [[ "$WITH_A2A" == true ]]; then
  header "Phase 4.6: A2A server (${CEO_USER} profile)"

  if [[ "$SKIP_HERMES" == true ]]; then
    warn "Hermes skipped — skipping A2A (needs the Hermes CLI + default profile)"
  elif [[ ! -d "${HERMES_VENV}" ]]; then
    warn "Hermes venv not found at ${HERMES_VENV} — skipping A2A"
  elif [[ ! -f "${HERMES_HOME}/config.yaml" ]]; then
    warn "${HERMES_HOME}/config.yaml not found — skipping A2A (run launch.sh Phase 3/4 first)"
  else
    # --- Bearer token: reuse if present (token file → .env → generate). Never rotate.
    A2A_TOKEN=""
    if [[ -f "${A2A_TOKEN_FILE}" ]]; then
      A2A_TOKEN="$(grep -m1 '^A2A_BEARER_TOKEN=' "${A2A_TOKEN_FILE}" 2>/dev/null | cut -d= -f2- || true)"
    fi
    if [[ -z "${A2A_TOKEN}" ]] && grep -q '^A2A_BEARER_TOKEN=' "${HERMES_HOME}/.env" 2>/dev/null; then
      A2A_TOKEN="$(grep -m1 '^A2A_BEARER_TOKEN=' "${HERMES_HOME}/.env" | cut -d= -f2-)"
    fi
    if [[ -z "${A2A_TOKEN}" ]]; then
      A2A_TOKEN="$(gen_hex32)"
      log "New A2A bearer token generated"
    else
      log "Reusing existing A2A bearer token"
    fi

    # --- .env: A2A_BEARER_TOKEN + A2A_HOST (flat upsert, default profile only).
    # Port lives ONLY in config.yaml (gateway.platforms.a2a.extra.port) so env
    # and config can never disagree.
    ENV_FILE="${HERMES_HOME}/.env"
    python3 - "${ENV_FILE}" "${A2A_TOKEN}" <<'PYEOF'
import sys, re, os
env_path, token = sys.argv[1], sys.argv[2]
content = ""
if os.path.exists(env_path):
    with open(env_path) as f:
        content = f.read()
header = ("\n# " + "=" * 77
          + "\n# A2A SERVER — CEO-only (default profile). Remote bind requires the token."
          + "\n# " + "=" * 77 + "\n")
if "A2A SERVER" not in content:
    content += header
for key, val in [("A2A_BEARER_TOKEN", token), ("A2A_HOST", "0.0.0.0")]:
    if re.search(rf"^{key}=", content, re.M):
        content = re.sub(rf"^{key}=.*", f"{key}={val}", content, flags=re.M)
    else:
        content += f"{key}={val}\n"
with open(env_path, "w") as f:
    f.write(content)
print("  .env ← A2A_BEARER_TOKEN + A2A_HOST=0.0.0.0")
PYEOF

    # --- config.yaml: gateway.platforms.a2a (nested upsert). Handles a
    # pre-existing gateway:/platforms: section (mid-block insert) or creates
    # the whole chain at EOF. Exact-indent anchors keep unrelated keys safe.
    python3 - "${HERMES_HOME}/config.yaml" "${A2A_PORT_DEFAULT}" <<'PYEOF'
import sys, re
cfg, port = sys.argv[1], sys.argv[2]
with open(cfg) as f:
    lines = f.read().split("\n")

def find_header(lines, start, end, indent, header):
    pat = re.compile(rf"^ {{{indent}}}{re.escape(header)}:(\s.*)?$")
    for i in range(start, end):
        if pat.match(lines[i]):
            return i
    return -1

def block_end(lines, hdr_idx, indent):
    j = hdr_idx + 1
    while j < len(lines):
        s = lines[j]
        if s.strip() == "":
            j += 1
        elif re.match(rf"^ {{{indent + 1},}}", s):
            j += 1
        else:
            break
    return j

def upsert(lines, path, key, val):
    """Ensure the header chain `path` exists and set `key: val` under it.
    Returns (lines, changed)."""
    start, end = 0, len(lines)
    for depth, hdr in enumerate(path):
        idx = find_header(lines, start, end, 2 * depth, hdr)
        if idx == -1:
            ins = end
            while ins > start and lines[ins - 1].strip() == "":
                ins -= 1
            new = []
            if depth == 0 and lines and lines[0].strip():
                new.append("")  # blank line before a new top-level section
            for j, h in enumerate(path[depth:]):
                new.append(" " * (2 * (depth + j)) + h + ":")
            new.append(" " * (2 * len(path)) + f"{key}: {val}")
            return lines[:ins] + new + lines[ins:], True
        start, end = idx + 1, block_end(lines, idx, 2 * depth)
    leaf_ind = " " * (2 * len(path))
    pat = re.compile(rf"^{re.escape(leaf_ind)}{re.escape(key)}:")
    for i in range(start, end):
        if pat.match(lines[i]):
            if lines[i] == f"{leaf_ind}{key}: {val}":
                return lines, False
            lines[i] = f"{leaf_ind}{key}: {val}"
            return lines, True
    ins = end
    while ins > start and lines[ins - 1].strip() == "":
        ins -= 1
    return lines[:ins] + [f"{leaf_ind}{key}: {val}"] + lines[ins:], True

changed = False
lines, c1 = upsert(lines, ["gateway", "platforms", "a2a"], "enabled", "true")
changed = changed or c1
lines, c2 = upsert(lines, ["gateway", "platforms", "a2a", "extra"], "port", port)
changed = changed or c2
if changed:
    with open(cfg, "w") as f:
        f.write("\n".join(lines))
    print(f"  config.yaml ← gateway.platforms.a2a.enabled=true, extra.port={port}")
else:
    print("  config.yaml → a2a already configured")
PYEOF

    # --- Outbound a2a toolset for CLI/TUI (so the CEO can SEND tasks to peers)
    info "Enabling a2a toolset for the cli platform (default profile)..."
    if "${HERMES_VENV}/bin/hermes" tools enable a2a --platform cli >/dev/null 2>&1; then
      log "a2a toolset enabled (cli platform)"
    else
      warn "'hermes tools enable a2a --platform cli' failed — run it manually"
    fi

    # --- Token record for the human / remote peers (kept OUT of CREDS_FILE by
    # design). Written when missing; rewritten if the token was recovered from
    # .env so the curl example is never lost. Existing file left untouched.
    if [[ ! -f "${A2A_TOKEN_FILE}" ]] || ! grep -q '^A2A_BEARER_TOKEN=' "${A2A_TOKEN_FILE}" 2>/dev/null; then
      VM_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
      cat > "${A2A_TOKEN_FILE}" << EOF
# A2A Bearer Token — Hermes default profile (${CEO_USER}, CEO)
# Generated: $(date)
# Authorizes A2A task calls against port ${A2A_PORT_DEFAULT}, which is bound
# to 0.0.0.0 (LAN-reachable). Keep it secret. Deleting this file does NOT
# disable A2A — the token also lives in ~/.hermes/.env (re-runs reuse it).
A2A_BEARER_TOKEN=${A2A_TOKEN}

# Example — fetch the CEO's agent card from another machine on the LAN:
#   source ~/a2a_bearer_token.env
#   curl -H "Authorization: Bearer \$A2A_BEARER_TOKEN" \\
#        http://${VM_IP:-<VM-IP>}:${A2A_PORT_DEFAULT}/.well-known/agent-card.json
EOF
      chmod 600 "${A2A_TOKEN_FILE}"
      log "A2A token saved: ${A2A_TOKEN_FILE} (chmod 600)"
    else
      log "A2A token file already exists — left untouched"
    fi

    warn "A2A is bound to 0.0.0.0:${A2A_PORT_DEFAULT} with bearer-token auth — any device on the LAN can reach it (token required). Do not forward this port to the internet without TLS."

    # --- Restart the gateway so the listener comes up, then verify the card
    info "Restarting hermes-gateway to bring up the A2A listener..."
    systemctl --user restart hermes-gateway 2>/dev/null \
      || warn "Could not restart hermes-gateway — start it manually"

    A2A_CARD="http://127.0.0.1:${A2A_PORT_DEFAULT}/.well-known/agent-card.json"
    info "Waiting for the A2A agent card..."
    _a2a_up=false; _i=0
    while [[ ${_i} -lt 60 ]]; do
      if curl -sf --max-time 3 "${A2A_CARD}" >/dev/null 2>&1 \
         || curl -sf --max-time 3 -H "Authorization: Bearer ${A2A_TOKEN}" "${A2A_CARD}" >/dev/null 2>&1; then
        _a2a_up=true; break
      fi
      sleep 2; _i=$((_i + 2)); echo -n "."
    done
    echo ""
    if [[ "${_a2a_up}" == true ]]; then
      log "A2A agent card responding at ${A2A_CARD}"
    else
      warn "A2A agent card not responding yet — check: journalctl --user -u hermes-gateway -f"
    fi
  fi
else
  info "A2A skipped (optional — rerun with --with-a2a)"
fi  # end WITH_A2A


# ---------------------------------------------------------------------------
# Phase 5 — Summary
# ---------------------------------------------------------------------------
header "Installation Complete"

set +eu
source "${CREDS_FILE}" 2>/dev/null || true
set -eu

HERMES_OK=false; GATEWAY_OK=false; SYNAPSE_OK=false; ELEMENT_OK=false; MEMOK=false; PC_OK=false; A2A_OK=false
hermes --version &>/dev/null && HERMES_OK=true || true
systemctl --user is-active hermes-gateway &>/dev/null && GATEWAY_OK=true || true
curl -sf http://127.0.0.1:${MATRIX_PORT}/_matrix/client/versions &>/dev/null && SYNAPSE_OK=true || true
command -v element-desktop &>/dev/null && ELEMENT_OK=true || true
[[ -d "${VAULT_HOME}/Daily" ]] && [[ -x "${HERMES_VENV}/bin/mnemosyne-hermes" ]] && MEMOK=true || true
command -v paperclipai &>/dev/null && PC_OK=true || true
if [[ "$WITH_A2A" == true ]]; then
  # Agent card may or may not sit behind the bearer — try both (docs don't say)
  _a2a_tok="$(grep -m1 '^A2A_BEARER_TOKEN=' "${A2A_TOKEN_FILE}" 2>/dev/null | cut -d= -f2- || true)"
  curl -sf --max-time 3 "http://127.0.0.1:${A2A_PORT_DEFAULT}/.well-known/agent-card.json" &>/dev/null && A2A_OK=true || true
  if [[ "$A2A_OK" != true && -n "${_a2a_tok:-}" ]]; then
    curl -sf --max-time 3 -H "Authorization: Bearer ${_a2a_tok}" \
      "http://127.0.0.1:${A2A_PORT_DEFAULT}/.well-known/agent-card.json" &>/dev/null && A2A_OK=true || true
  fi
fi

status() { [[ "$1" == true ]] && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; true; }; }

echo ""
echo -e "${BOLD}${CYAN}  Your company is open for business.${NC}"
echo ""
echo -e "${BOLD}  Component            Status    Detail${NC}"
echo    "  ─────────────────────────────────────────────────────────"
echo -e "  Matrix Synapse        $(status $SYNAPSE_OK)         http://0.0.0.0:${MATRIX_PORT}  (LAN: http://<VM-IP>:${MATRIX_PORT})"
echo -e "  Hermes Agent          $(status $HERMES_OK)         $(hermes --version 2>&1 | head -1)"
echo -e "  ${CEO_USER} Gateway (CEO)   $(status $GATEWAY_OK)         systemctl --user status hermes-gateway"
echo -e "  Agent Memory          $(status $MEMOK)         Mnemosyne + vault: ${VAULT_HOME}"
[[ "$WITH_PAPERCLIP" == true ]] && echo -e "  Paperclip             $(status $PC_OK)         http://localhost:3100"
[[ "$WITH_A2A" == true ]] && echo -e "  A2A (${CEO_USER})         $(status $A2A_OK)         :${A2A_PORT_DEFAULT} LAN-wide — token: ~/a2a_bearer_token.env"
echo -e "  Element Desktop       $(status $ELEMENT_OK)         element-desktop"
echo ""
echo -e "${BOLD}  Matrix access:${NC}"
echo    "    Homeserver : http://localhost:${MATRIX_PORT}"
echo    "    Operator   : @${MATRIX_ADMIN_USER}:${MATRIX_DOMAIN} / ${MATRIX_ADMIN_PASS}"
echo    "    CEO        : @${CEO_USER}:${MATRIX_DOMAIN} / (see ${CREDS_FILE})"
echo ""
echo -e "${BOLD}  Memory system:${NC}"
echo    "    Facts      : Mnemosyne (per-agent SQLite, hybrid recall)"
echo    "    Long record: ${VAULT_HOME} (daily pages, issues log)"
echo    "    Rituals    : matins 06:50 weekdays, vespers 22:00 daily (crontab -l)"
echo ""
echo -e "${BOLD}  Next steps:${NC}"
echo    "    1. Configure your inference provider:"
echo    "         hermes model   → follow the prompts to choose your provider and model"
echo    "    2. Talk to ${CEO_USER}:  hermes chat"
echo    "    3. Open Element Desktop → http://localhost:${MATRIX_PORT}"
echo    "    4. Hire more agents:  bash hire.sh --title '...' --skill blender-mcp"
echo    "       (hire.sh auto-assigns a Futurama robot name)"
[[ "$WITH_PAPERCLIP" != true ]] && \
echo    "    5. Optional dashboard:  bash launch.sh --with-paperclip (Paperclip)"
echo ""
echo -e "${BOLD}  Credentials: ${CREDS_FILE}${NC}"
echo ""
