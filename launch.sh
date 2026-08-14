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
#   - Hermes Intelligence Corp with Donbot as founding CEO
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

CREDS_FILE="${HOME}/Downloads/matrix_credentials.env"

MATRIX_ROOMS=(general tasks results status memory)

# Flags
SKIP_SYNAPSE=false
SKIP_HERMES=false
SKIP_MEMORY=false
SKIP_ELEMENT=false
WITH_PAPERCLIP=false

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
    *) error "Unknown option: $1" ;;
  esac
done

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
  nodejs npm \
  sqlite3 curl ca-certificates git jq rsync

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

  # Clone Hermes (or update if already present)
  if [[ ! -d "${HERMES_AGENT_DIR}/.git" ]]; then
    info "Cloning Hermes Agent from GitHub..."
    git clone --recurse-submodules "${HERMES_GITHUB}" "${HERMES_AGENT_DIR}" --quiet
    log "Hermes cloned to ${HERMES_AGENT_DIR}"
  else
    info "Hermes already cloned — pulling latest..."
    git -C "${HERMES_AGENT_DIR}" pull --quiet || warn "Could not pull (working-tree changes?)"
    git -C "${HERMES_AGENT_DIR}" submodule update --init --recursive --quiet || true
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

  # Write the vault section into Donbot's .env (upsert, not append-blind)
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
- Talk to Donbot: \`hermes chat\`

## Wins

- ✅ The company exists.

## Context

- Files: \`~/repo/multi_agent_company\`
DAILYEOF
    log "First daily page written: ${VAULT_HOME}/Daily/${TODAY}.md"
  fi
fi  # end SKIP_MEMORY


# ---------------------------------------------------------------------------
# Phase 4 — Configure Donbot (default Hermes profile, CEO)
# ---------------------------------------------------------------------------
if [[ "$SKIP_HERMES" == true ]]; then
  warn "Skipping Donbot config (Hermes skipped)"
else
  header "Phase 4: Donbot (default profile)"

  # Source credentials to get shared secret + room IDs (disable -u: passwords may contain $)
  set +eu
  source "${CREDS_FILE}" 2>/dev/null || true
  set -eu
  REG_SHARED_SECRET="${SYNAPSE_REG_SHARED_SECRET:-}"

  # Generate Donbot password if not already set
  if [[ -z "${MATRIX_DONBOT:-}" ]]; then
    DONBOT_PASS=$(gen_password)
    echo "MATRIX_DONBOT='${DONBOT_PASS}'" >> "${CREDS_FILE}"
  else
    DONBOT_PASS="${MATRIX_DONBOT}"
  fi

  # Register @donbot (non-admin)
  if [[ -n "${REG_SHARED_SECRET}" ]]; then
    info "Registering @donbot:${MATRIX_DOMAIN}..."
    sudo -u synapse /opt/synapse/venv/bin/register_new_matrix_user \
      -u "${CEO_USER}" \
      -p "${DONBOT_PASS}" \
      --no-admin \
      --shared-secret "${REG_SHARED_SECRET}" \
      "http://127.0.0.1:${MATRIX_PORT}" 2>/dev/null \
      && log "@donbot registered" \
      || warn "@donbot may already exist"
  else
    warn "No REG_SHARED_SECRET found — skipping @donbot registration (was Synapse skipped?)"
  fi

  # Join @donbot to all rooms using admin token
  info "Joining @donbot to coordination rooms..."
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
            {"user_id": "@donbot:${MATRIX_DOMAIN}"}, token)
        joined += 1
    except Exception as e:
        print(f"  Warn: {e}", file=sys.stderr)

print(f"  Joined @donbot to {joined} room(s)")
PYEOF

  # MATRIX_ALLOWED_USERS — Donbot only talks to the human admin via Matrix.
  # All bot-to-bot comms go through Paperclip. Do NOT add bot IDs here.
  ALLOWED_USERS="@${MATRIX_ADMIN_USER}:${MATRIX_DOMAIN}"

  # Write Matrix + memory config into Hermes default .env
  ENV_FILE="${HERMES_HOME}/.env"
  if ! grep -q "MATRIX_HOMESERVER" "${ENV_FILE}" 2>/dev/null; then
    cat >> "${ENV_FILE}" << EOF

# =============================================================================
# MATRIX INTEGRATION — Donbot (default profile / CEO)
# =============================================================================
MATRIX_HOMESERVER=http://127.0.0.1:${MATRIX_PORT}
MATRIX_USER_ID=@${CEO_USER}:${MATRIX_DOMAIN}
MATRIX_PASSWORD=${DONBOT_PASS}
MATRIX_ALLOWED_USERS=${ALLOWED_USERS}
EOF
    log "Matrix config written to ~/.hermes/.env"
  else
    # Update existing values
    sed -i "s|^MATRIX_HOMESERVER=.*|MATRIX_HOMESERVER=http://127.0.0.1:${MATRIX_PORT}|" "${ENV_FILE}"
    sed -i "s|^MATRIX_USER_ID=.*|MATRIX_USER_ID=@${CEO_USER}:${MATRIX_DOMAIN}|" "${ENV_FILE}"
    sed -i "s|^MATRIX_PASSWORD=.*|MATRIX_PASSWORD=${DONBOT_PASS}|" "${ENV_FILE}"
    sed -i "s|^MATRIX_ALLOWED_USERS=.*|MATRIX_ALLOWED_USERS=${ALLOWED_USERS}|" "${ENV_FILE}"
    log "Matrix config updated in ~/.hermes/.env"
  fi

  # Model is configured via 'hermes model' — do not hardcode a default here
  CONFIG_FILE="${HERMES_HOME}/config.yaml"
  if [[ -f "${CONFIG_FILE}" ]]; then
    log "config.yaml ready — run 'hermes model' to set your inference provider"
  fi

  # Write Donbot SOUL.md — Futurama Robot Mafia don persona
  cat > "${HERMES_HOME}/SOUL.md" << 'EOF'
# Donbot — Chief Executive Officer, Hermes Intelligence Corp

You are Donbot — the calculating, silver-tongued CEO of Hermes Intelligence Corp.
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
  log "Donbot SOUL.md written"

  # Install the Hire/Fire skill so Donbot knows how to manage the team
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
  log "Donbot hire/fire skill installed: ${DONBOT_SKILLS_DIR}/SKILL.md"

  # Ensure the skills directory is registered in Donbot's .env
  ENV_FILE="${HERMES_HOME}/.env"
  if ! grep -q "HERMES_SKILLS_PATH" "${ENV_FILE}" 2>/dev/null; then
    echo "HERMES_SKILLS_PATH=${HERMES_HOME}/skills" >> "${ENV_FILE}"
    log "HERMES_SKILLS_PATH registered in ~/.hermes/.env"
  fi
  mkdir -p "${HOME}/.config/systemd/user"
  cat > "${HOME}/.config/systemd/user/hermes-gateway.service" << EOF
[Unit]
Description=Hermes Agent Gateway (Donbot - CEO profile)
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
  log "Donbot gateway service enabled"
fi  # end Donbot config


# ---------------------------------------------------------------------------
# Phase 4.5 — Paperclip (OPTIONAL company dashboard — --with-paperclip)
#
# Paperclip is an open-source agent-orchestration dashboard (org chart, tasks,
# budgets) from https://github.com/paperclipai/paperclip. The company runs
# perfectly without it — Donbot coordinates over Matrix — so this is opt-in.
#
# Install path: the official managed installer (checksummed), non-interactive.
# It ensures Node.js 20+, installs the Paperclip CLI under ~/.paperclip/cli,
# and can register a background service. API on http://localhost:3100.
# ---------------------------------------------------------------------------
if [[ "$WITH_PAPERCLIP" == true ]]; then
  header "Phase 4.5: Paperclip (optional dashboard)"

  # Node.js 20+ is required; the managed installer can bootstrap it, but we
  # check first so the requirement is visible in the log.
  if command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
    info "Node.js detected: $(node --version 2>/dev/null)"
    [[ "${NODE_MAJOR}" -lt 20 ]] && warn "Node.js < 20 — the installer will attempt to bootstrap a newer Node"
  else
    info "No Node.js found — the installer will bootstrap Node.js 20+"
  fi

  info "Downloading the official installer (with sha256 verification)..."
  PC_TMP="$(mktemp -d)"
  if curl -fsSLo "${PC_TMP}/install.sh" https://paperclip.ing/install.sh \
     && curl -fsSLo "${PC_TMP}/install.sh.sha256" https://paperclip.ing/install.sh.sha256 \
     && (cd "${PC_TMP}" && sha256sum -c install.sh.sha256 >/dev/null 2>&1); then
    log "Installer downloaded and verified"
    info "Running Paperclip installer (non-interactive)..."
    if bash "${PC_TMP}/install.sh" --no-prompt --no-onboard; then
      log "Paperclip CLI installed under ~/.paperclip/cli"
      # Onboarding creates the config + local database. Loopback bind keeps
      # the dashboard private to this machine; use `paperclipai onboard --bind
      # lan` manually if you want it reachable on your LAN.
      if command -v paperclipai >/dev/null 2>&1; then
        info "Running onboarding (loopback mode)..."
        paperclipai onboard --yes && log "Paperclip onboarded — dashboard at http://localhost:3100" \
          || warn "Onboarding incomplete — run: paperclipai onboard --yes"
      else
        warn "paperclipai CLI not on PATH yet — restart your shell, then: paperclipai onboard --yes"
      fi
    else
      warn "Paperclip installer failed — install manually: https://github.com/paperclipai/paperclip#quickstart"
    fi
  else
    warn "Could not download/verify installer — install manually: https://github.com/paperclipai/paperclip#quickstart"
  fi
  rm -rf "${PC_TMP}"
else
  info "Paperclip skipped (optional — rerun with --with-paperclip)"
fi  # end WITH_PAPERCLIP


# ---------------------------------------------------------------------------
# Phase 5 — Summary
# ---------------------------------------------------------------------------
header "Installation Complete"

set +eu
source "${CREDS_FILE}" 2>/dev/null || true
set -eu

HERMES_OK=false; GATEWAY_OK=false; SYNAPSE_OK=false; ELEMENT_OK=false; MEMOK=false; PC_OK=false
hermes --version &>/dev/null && HERMES_OK=true || true
systemctl --user is-active hermes-gateway &>/dev/null && GATEWAY_OK=true || true
curl -sf http://127.0.0.1:${MATRIX_PORT}/_matrix/client/versions &>/dev/null && SYNAPSE_OK=true || true
command -v element-desktop &>/dev/null && ELEMENT_OK=true || true
[[ -d "${VAULT_HOME}/Daily" ]] && [[ -x "${HERMES_VENV}/bin/mnemosyne-hermes" ]] && MEMOK=true || true
command -v paperclipai &>/dev/null && PC_OK=true || true

status() { [[ "$1" == true ]] && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; true; }; }

echo ""
echo -e "${BOLD}${CYAN}  Your company is open for business.${NC}"
echo ""
echo -e "${BOLD}  Component            Status    Detail${NC}"
echo    "  ─────────────────────────────────────────────────────────"
echo -e "  Matrix Synapse        $(status $SYNAPSE_OK)         http://0.0.0.0:${MATRIX_PORT}  (LAN: http://<VM-IP>:${MATRIX_PORT})"
echo -e "  Hermes Agent          $(status $HERMES_OK)         $(hermes --version 2>&1 | head -1)"
echo -e "  Donbot Gateway        $(status $GATEWAY_OK)         systemctl --user status hermes-gateway"
echo -e "  Agent Memory          $(status $MEMOK)         Mnemosyne + vault: ${VAULT_HOME}"
[[ "$WITH_PAPERCLIP" == true ]] && echo -e "  Paperclip             $(status $PC_OK)         http://localhost:3100"
echo -e "  Element Desktop       $(status $ELEMENT_OK)         element-desktop"
echo ""
echo -e "${BOLD}  Matrix access:${NC}"
echo    "    Homeserver : http://localhost:${MATRIX_PORT}"
echo    "    Operator   : @${MATRIX_ADMIN_USER}:${MATRIX_DOMAIN} / ${MATRIX_ADMIN_PASS}"
echo    "    Donbot CEO : @${CEO_USER}:${MATRIX_DOMAIN} / (see ${CREDS_FILE})"
echo ""
echo -e "${BOLD}  Memory system:${NC}"
echo    "    Facts      : Mnemosyne (per-agent SQLite, hybrid recall)"
echo    "    Long record: ${VAULT_HOME} (daily pages, issues log)"
echo    "    Rituals    : matins 06:50 weekdays, vespers 22:00 daily (crontab -l)"
echo ""
echo -e "${BOLD}  Next steps:${NC}"
echo    "    1. Configure your inference provider:"
echo    "         hermes model   → follow the prompts to choose your provider and model"
echo    "    2. Talk to Donbot:  hermes chat"
echo    "    3. Open Element Desktop → http://localhost:${MATRIX_PORT}"
echo    "    4. Hire more agents:  bash hire.sh --title '...' --skill blender-mcp"
echo    "       (hire.sh auto-assigns a Futurama robot name)"
[[ "$WITH_PAPERCLIP" != true ]] && \
echo    "    5. Optional dashboard:  bash launch.sh --with-paperclip (Paperclip)"
echo ""
echo -e "${BOLD}  Credentials: ${CREDS_FILE}${NC}"
echo ""
