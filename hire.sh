#!/usr/bin/env bash
# =============================================================================
# hire.sh — Bring a New Agent on Board
#
# Adds a new AI agent to your Multi-Agent Company:
#   1. Register Matrix account + join all coordination rooms
#   2. Create Hermes profile (--clone of default)
#   3. Configure .env + SOUL.md for the profile
#   4. Install + start Hermes gateway systemd service
#   5. Install selected skills into the profile
#   6. Provision MemPalace memory palace for the bot
#   7. Update MATRIX_ALLOWED_USERS (locked to admin + donbot only)
#
# Usage:
#   bash hire.sh [botname] [OPTIONS]
#
#   botname is optional — if omitted, a random Futurama robot name is chosen.
#
# Options:
#   --title "Chief Technology Officer"    Job title for the agent
#   --model "minimax-m2.7:cloud"           LLM model for this profile's config.yaml
#   --soul  "You are..."                   Custom SOUL.md content (first-person)
#   --skill <name>                         Install a skill (repeatable). Valid names:
#                                           gd-agentic  — Godot 4 mastery skills
#                                           story       — End-to-end story writing skills
#                                           pixel       — Pixel art / Aseprite MCP skills
#                                           blender-mcp — Blender MCP integration skills
#                                           find-skills — Find-skills discovery skills
#                                           impeccable  — Frontend design (typography, color, layout, motion)
#   --no-memory                            Opt out of MemPalace memory
#   --no-gateway                           Skip gateway service install
#
# Examples:
#   bash hire.sh writerbot --title "Technical Writer" --skill story --skill find-skills
#   bash hire.sh engineerbot --title "CTO" --skill gd-agentic
#   bash hire.sh --title "Creative Director" --skill pixel   # random Futurama name
#   bash hire.sh researchbot --no-memory --soul "You are ResearchBot, fast and precise."
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config defaults (aligned with launch.sh)
# ---------------------------------------------------------------------------
MATRIX_DOMAIN="localhost"
MATRIX_PORT="8008"
MATRIX_ADMIN_USER="admin"
MATRIX_ADMIN_PASS="changeme"
CEO_USER="donbot"

HERMES_HOME="${HOME}/.hermes"
HERMES_AGENT_DIR="${HERMES_HOME}/hermes-agent"
HERMES_VENV="${HERMES_AGENT_DIR}/venv"

MEMPALACE_HOME="${HOME}/.mempalace"

CREDS_FILE="${HOME}/Downloads/matrix_credentials.env"

# Futurama robot name pool (snake_case, simple and recognisable)
FUTURAMA_NAMES=(
  bender flexo roberto clamps calculon hedonismbot preacherbot
  crushinator tinny_tim boxy url roberto daffy sinclair_2k
  malfunctioning_eddie joey_mousepad kwanzaabot url robot_santa
)

# Skill registry: name -> git URL
declare -A SKILL_REPOS=(
  [gd-agentic]="https://github.com/thedivergentai/gd-agentic-skills.git"
  [story]="https://github.com/danjdewhurst/story-skills.git"
  [pixel]="https://github.com/willibrandon/pixel-plugin.git"
  [blender-mcp]="https://github.com/vladmdgolam/agent-skills.git"
  [find-skills]="https://github.com/vercel-labs/skills.git"
  [impeccable]="https://github.com/pbakaus/impeccable.git"
)

# Skill sub-paths within each repo (where the SKILL.md files live)
declare -A SKILL_PATHS=(
  [gd-agentic]="skills"
  [story]="skills"
  [pixel]="skills"
  [blender-mcp]="blender-mcp"
  [find-skills]="find-skills"
  [impeccable]="source/skills/impeccable"
)

# ---------------------------------------------------------------------------
# Colours & helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
info()  { echo -e "${BLUE}[→]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

gen_password() {
  python3 -c "
import secrets, string
chars = string.ascii_letters + string.digits + '!@#\$%^&*'
print(''.join(secrets.choice(chars) for _ in range(28)))
"
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
BOT_NAME=""

# First positional arg is bot name (if it doesn't start with --)
if [[ $# -gt 0 && "$1" != --* ]]; then
  BOT_NAME="${1,,}"   # force lowercase
  shift
fi

BOT_TITLE=""
BOT_MODEL=""
BOT_SOUL=""
INSTALL_GATEWAY=true
INSTALL_MEMORY=true
BOT_SKILLS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)        BOT_TITLE="$2";       shift 2 ;;
    --model)        BOT_MODEL="$2";       shift 2 ;;
    --soul)         BOT_SOUL="$2";        shift 2 ;;
    --skill)
      SKILL_KEY="$2"
      if [[ -z "${SKILL_REPOS[$SKILL_KEY]+_}" ]]; then
        error "Unknown skill '${SKILL_KEY}'. Valid: ${!SKILL_REPOS[*]}"
      fi
      BOT_SKILLS+=("$SKILL_KEY")
      shift 2 ;;
    --no-memory)    INSTALL_MEMORY=false; shift ;;
    --no-gateway)   INSTALL_GATEWAY=false; shift ;;
    *) error "Unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Bot name — random Futurama name if not provided
# ---------------------------------------------------------------------------
export PATH="${HOME}/.local/bin:${PATH}"

if [[ -z "${BOT_NAME}" ]]; then
  info "No bot name given — picking a random Futurama robot name..."
  # Shuffle and pick the first unused name
  BOT_NAME=""
  for _candidate in $(python3 -c "
import random, sys
names = sys.argv[1:]
random.shuffle(names)
print(' '.join(names))
" "${FUTURAMA_NAMES[@]}"); do
    # Skip if Matrix user or Hermes profile already exists
    PROFILE_EXISTS=false
    [[ -d "${HERMES_HOME}/profiles/${_candidate}" ]] && PROFILE_EXISTS=true
    if [[ "${PROFILE_EXISTS}" == false ]]; then
      # Quick Matrix check (soft — Synapse may not be running during dev)
      _mx_exists=$(sudo sqlite3 /var/lib/matrix-synapse/homeserver.db \
        "SELECT name FROM users WHERE name='@${_candidate}:${MATRIX_DOMAIN}';" 2>/dev/null || echo "")
      [[ -z "${_mx_exists}" ]] && { BOT_NAME="${_candidate}"; break; }
    fi
  done
  [[ -z "${BOT_NAME}" ]] && error "Could not find an unused Futurama robot name. Pass an explicit name."
  info "Chosen name: ${BOT_NAME}"
fi

# Validate bot name
if ! [[ "${BOT_NAME}" =~ ^[a-z][a-z0-9_-]*$ ]]; then
  error "Bot name must be lowercase alphanumeric+underscore (e.g. 'writerbot', 'tinny_tim'). Got: '${BOT_NAME}'"
fi

# Default title if not provided
[[ -z "${BOT_TITLE}" ]] && BOT_TITLE="${BOT_NAME^} Agent"

echo ""
echo -e "${BOLD}Provisioning: @${BOT_NAME}:${MATRIX_DOMAIN}${NC}"
echo -e "  Title      : ${BOT_TITLE}"
[[ -n "${BOT_MODEL}"     ]] && echo "  Model      : ${BOT_MODEL}"
echo "  Memory     : ${INSTALL_MEMORY}"
[[ ${#BOT_SKILLS[@]} -gt 0 ]] && echo "  Skills     : ${BOT_SKILLS[*]}"
echo ""

# ---------------------------------------------------------------------------
# Step 0 — Preflight
# ---------------------------------------------------------------------------
info "Checking prerequisites..."

[[ "$EUID" -eq 0 ]] && error "Do not run as root."
command -v hermes >/dev/null || error "Hermes not installed — run launch.sh first"
curl -sf "http://127.0.0.1:${MATRIX_PORT}/_matrix/client/versions" >/dev/null \
  || error "Matrix Synapse not running on port ${MATRIX_PORT}"

# Load credentials file (disable -u temporarily: passwords may contain $ chars)
[[ -f "${CREDS_FILE}" ]] || error "Credentials file not found: ${CREDS_FILE}"
set +eu
source "${CREDS_FILE}" 2>/dev/null || true
set -eu
REG_SHARED_SECRET="${SYNAPSE_REG_SHARED_SECRET:-}"

# Fallback: read directly from homeserver.yaml if not in creds file
if [[ -z "${REG_SHARED_SECRET}" ]]; then
  REG_SHARED_SECRET=$(sudo grep -m1 "registration_shared_secret" /etc/matrix-synapse/homeserver.yaml \
    2>/dev/null | grep -oP '(?<=")[^"]+' || true)
  if [[ -n "${REG_SHARED_SECRET}" ]]; then
    echo "SYNAPSE_REG_SHARED_SECRET=${REG_SHARED_SECRET}" >> "${CREDS_FILE}"
    warn "SYNAPSE_REG_SHARED_SECRET read from homeserver.yaml and saved to ${CREDS_FILE}"
  fi
fi
[[ -z "${REG_SHARED_SECRET}" ]] && error "SYNAPSE_REG_SHARED_SECRET not found. Check ${CREDS_FILE} or /etc/matrix-synapse/homeserver.yaml"

# Check bot doesn't already exist in Matrix
EXISTING_USER=$(sudo sqlite3 /var/lib/matrix-synapse/homeserver.db \
  "SELECT name FROM users WHERE name='@${BOT_NAME}:${MATRIX_DOMAIN}';" 2>/dev/null || true)
if [[ -n "${EXISTING_USER}" ]]; then
  warn "@${BOT_NAME}:${MATRIX_DOMAIN} already exists in Matrix — skipping registration"
  BOT_ALREADY_EXISTS_MATRIX=true
else
  BOT_ALREADY_EXISTS_MATRIX=false
fi

log "Preflight passed"

# ---------------------------------------------------------------------------
# Step 1 — Register Matrix account
# ---------------------------------------------------------------------------
info "Step 1: Register @${BOT_NAME}:${MATRIX_DOMAIN}..."

PASS_KEY="MATRIX_$(echo "${BOT_NAME}" | tr '[:lower:]' '[:upper:]' | tr -d '_-')"
EXISTING_PASS=$(grep -m1 "^${PASS_KEY}=" "${CREDS_FILE}" 2>/dev/null | cut -d= -f2- || true)

if [[ -n "${EXISTING_PASS}" ]]; then
  BOT_PASS="${EXISTING_PASS}"
  log "Using existing password from ${CREDS_FILE}"
else
  BOT_PASS=$(gen_password)
  echo "${PASS_KEY}='${BOT_PASS}'" >> "${CREDS_FILE}"
  log "Password generated and saved to ${CREDS_FILE}"
fi

if [[ "${BOT_ALREADY_EXISTS_MATRIX}" == false ]]; then
  sudo -u synapse /opt/synapse/venv/bin/register_new_matrix_user \
    -u "${BOT_NAME}" \
    -p "${BOT_PASS}" \
    --no-admin \
    --shared-secret "${REG_SHARED_SECRET}" \
    "http://127.0.0.1:${MATRIX_PORT}" 2>/dev/null \
    && log "@${BOT_NAME} registered in Matrix" \
    || warn "@${BOT_NAME} registration failed (may already exist)"
fi

# ---------------------------------------------------------------------------
# Step 2 — Join coordination rooms
# ---------------------------------------------------------------------------
info "Step 2: Joining @${BOT_NAME} to coordination rooms..."

python3 << PYEOF
import json, urllib.request, sys, time

HS   = "http://127.0.0.1:${MATRIX_PORT}"
BOT  = "@${BOT_NAME}:${MATRIX_DOMAIN}"
CREDS = "${CREDS_FILE}"

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
        {"type": "m.login.password",
         "user": "${MATRIX_ADMIN_USER}",
         "password": "${MATRIX_ADMIN_PASS}"})
token = r["access_token"]

creds = {}
with open(CREDS) as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            creds[k.strip()] = v.strip()

room_ids = [v for k, v in creds.items()
            if k.startswith("MATRIX_ROOM_") and not k.startswith("MATRIX_ROOM_ALIAS")]

if not room_ids:
    print("  No room IDs found in credentials file — skipping room joins")
    sys.exit(0)

joined = 0
for room_id in room_ids:
    try:
        api(f"/_synapse/admin/v1/join/{room_id}", {"user_id": BOT}, token)
        joined += 1
        time.sleep(0.05)
    except Exception as e:
        print(f"  Warn joining {room_id}: {e}", file=sys.stderr)

print(f"  Joined {BOT} to {joined}/{len(room_ids)} rooms")
PYEOF

# ---------------------------------------------------------------------------
# Step 3 — Create Hermes profile
# ---------------------------------------------------------------------------
info "Step 3: Creating Hermes profile '${BOT_NAME}'..."

PROFILE_DIR="${HERMES_HOME}/profiles/${BOT_NAME}"

if [[ -d "${PROFILE_DIR}" ]]; then
  log "Profile '${BOT_NAME}' already exists — skipping clone"
else
  hermes profile create "${BOT_NAME}" --clone 2>&1 \
    && log "Profile '${BOT_NAME}' created" \
    || error "Failed to create Hermes profile '${BOT_NAME}'"
fi

# ---------------------------------------------------------------------------
# Step 4 — Configure profile .env
# ---------------------------------------------------------------------------
info "Step 4: Configuring profile .env..."

ENV_FILE="${PROFILE_DIR}/.env"
[[ -f "${ENV_FILE}" ]] || touch "${ENV_FILE}"

# MATRIX_ALLOWED_USERS — locked to admin + donbot only.
# Bots still join Matrix rooms but the gateway filters out all other senders.
# All bot-to-bot task delegation goes through Paperclip.
LOCKED_ALLOWED="@${MATRIX_ADMIN_USER}:${MATRIX_DOMAIN},@${CEO_USER}:${MATRIX_DOMAIN}"

python3 << PYEOF
import re, os

env_path = "${ENV_FILE}"
with open(env_path) as f:
    content = f.read()

updates = {
    "MATRIX_HOMESERVER":    "http://127.0.0.1:${MATRIX_PORT}",
    "MATRIX_USER_ID":       "@${BOT_NAME}:${MATRIX_DOMAIN}",
    "MATRIX_PASSWORD":      "${BOT_PASS}",
    "MATRIX_ALLOWED_USERS": "${LOCKED_ALLOWED}",
}

for key, val in updates.items():
    if re.search(rf"^{key}=", content, re.MULTILINE):
        content = re.sub(rf"^{key}=.*", f"{key}={val}", content, flags=re.MULTILINE)
    else:
        content += f"\n{key}={val}\n"

# Comment out Telegram keys (bots don't need Telegram)
for key in ["TELEGRAM_BOT_TOKEN", "TELEGRAM_ALLOWED_USERS", "TELEGRAM_HOME_CHANNEL"]:
    content = re.sub(rf"^({key}=.+)$", r"# \1", content, flags=re.MULTILINE)

with open(env_path, "w") as f:
    f.write(content)
print(f"  Profile .env configured")
PYEOF

log "Profile .env configured"

# ---------------------------------------------------------------------------
# Step 5 — Write SOUL.md
# ---------------------------------------------------------------------------
info "Step 5: Writing SOUL.md..."

SOUL_FILE="${PROFILE_DIR}/SOUL.md"

if [[ -n "${BOT_SOUL}" ]]; then
  cat > "${SOUL_FILE}" << SOULEOF
# ${BOT_NAME^}

${BOT_SOUL}

- You are part of Hermes Intelligence Corp, a multi-agent AI company
- Donbot (CEO) coordinates the team via Matrix; report results clearly
- You do NOT communicate with humans directly via Matrix — only Donbot does
SOULEOF
else
  cat > "${SOUL_FILE}" << SOULEOF
# ${BOT_NAME^} — ${BOT_TITLE}

You are ${BOT_NAME^}, the ${BOT_TITLE} of Hermes Intelligence Corp.

- Embody your role with expertise, precision, and initiative
- Work autonomously — plan, execute, and report results clearly
- You do NOT communicate with humans directly via Matrix
- All task delegation flows through Donbot (CEO) via Matrix
- You are a specialist; the team depends on your domain expertise
SOULEOF
fi

log "SOUL.md written"

# ---------------------------------------------------------------------------
# Step 5b — Set model in config.yaml (if --model provided)
# ---------------------------------------------------------------------------
if [[ -n "${BOT_MODEL}" ]]; then
  info "Setting model to ${BOT_MODEL}..."
  CONFIG_FILE="${PROFILE_DIR}/config.yaml"
  if [[ -f "${CONFIG_FILE}" ]]; then
    sed -i "s|^\( *default: \).*|\1${BOT_MODEL}|" "${CONFIG_FILE}" || true
    log "Model set to ${BOT_MODEL} in config.yaml"
  else
    warn "config.yaml not found for profile — model not set"
  fi
fi

# ---------------------------------------------------------------------------
# Step 5c — Install selected skills
# ---------------------------------------------------------------------------
if [[ ${#BOT_SKILLS[@]} -gt 0 ]]; then
  info "Step 5c: Installing ${#BOT_SKILLS[@]} skill(s)..."
  SKILLS_DIR="${PROFILE_DIR}/skills"
  mkdir -p "${SKILLS_DIR}"

  for SKILL_NAME in "${BOT_SKILLS[@]}"; do
    SKILL_URL="${SKILL_REPOS[$SKILL_NAME]}"
    SKILL_SUB="${SKILL_PATHS[$SKILL_NAME]}"
    SKILL_REPO_DIR="${PROFILE_DIR}/.skill-repos/${SKILL_NAME}"

    info "  Installing skill '${SKILL_NAME}' from ${SKILL_URL}..."

    # Clone or update the skill repo
    if [[ -d "${SKILL_REPO_DIR}/.git" ]]; then
      git -C "${SKILL_REPO_DIR}" pull --quiet 2>/dev/null || warn "  Could not update ${SKILL_NAME} skill repo"
    else
      mkdir -p "${SKILL_REPO_DIR}"
      if git clone --depth 1 "${SKILL_URL}" "${SKILL_REPO_DIR}" --quiet 2>/dev/null; then
        log "  Cloned ${SKILL_NAME}"
      else
        warn "  Could not clone ${SKILL_NAME} from ${SKILL_URL} — skipping"
        continue
      fi
    fi

    # Copy SKILL.md files into the profile skills directory
    SKILL_SRC="${SKILL_REPO_DIR}/${SKILL_SUB}"
    if [[ -d "${SKILL_SRC}" ]]; then
      find "${SKILL_SRC}" -maxdepth 2 -name "*.md" -o -name "SKILL.md" 2>/dev/null | while read -r skill_file; do
        cp -f "${skill_file}" "${SKILLS_DIR}/" 2>/dev/null && true
      done
      log "  Skill files copied for '${SKILL_NAME}'"
    elif [[ -f "${SKILL_REPO_DIR}/${SKILL_SUB}.md" ]]; then
      cp -f "${SKILL_REPO_DIR}/${SKILL_SUB}.md" "${SKILLS_DIR}/"
      log "  Skill file copied for '${SKILL_NAME}'"
    else
      warn "  Skills sub-path '${SKILL_SUB}' not found in ${SKILL_NAME} repo — check SKILL_PATHS config"
    fi

    # Run per-skill install script if present
    if [[ -f "${SKILL_REPO_DIR}/install.sh" ]]; then
      bash "${SKILL_REPO_DIR}/install.sh" 2>/dev/null || warn "  install.sh for ${SKILL_NAME} returned non-zero"
    fi
  done

  # Register skills directory in profile env
  if ! grep -q "HERMES_SKILLS_PATH" "${ENV_FILE}" 2>/dev/null; then
    echo "HERMES_SKILLS_PATH=${SKILLS_DIR}" >> "${ENV_FILE}"
  fi

  log "Skills installed: ${BOT_SKILLS[*]}"
else
  info "Step 5c: No skills selected — skipping"
fi

# ---------------------------------------------------------------------------
# Step 6 — MemPalace per-bot memory palace
# ---------------------------------------------------------------------------
info "Step 6: Configuring MemPalace memory..."

BOT_PALACE="${MEMPALACE_HOME}/data/${BOT_NAME}"

if [[ "${INSTALL_MEMORY}" == true ]]; then
  if command -v mempalace &>/dev/null; then
    mkdir -p "${BOT_PALACE}"
    if [[ ! -d "${BOT_PALACE}/.palace" ]] && [[ ! -f "${BOT_PALACE}/config.toml" ]]; then
      mempalace init "${BOT_PALACE}" 2>/dev/null || warn "mempalace init failed — palace directory created, init manually later"
    else
      log "Palace already exists for ${BOT_NAME}"
    fi
    # Write MemPalace env vars into profile .env
    python3 << PYEOF
import re
env_path = "${ENV_FILE}"
with open(env_path) as f:
    content = f.read()
for key, val in [("MEMPALACE_ENABLED", "true"), ("MEMPALACE_HOME", "${BOT_PALACE}")]:
    if re.search(rf"^{key}=", content, re.MULTILINE):
        content = re.sub(rf"^{key}=.*", f"{key}={val}", content, flags=re.MULTILINE)
    else:
        content += f"\n{key}={val}\n"
with open(env_path, "w") as f:
    f.write(content)
PYEOF
    log "MemPalace palace created: ${BOT_PALACE}"
  else
    warn "mempalace not installed — run launch.sh or install with 'pipx install mempalace'"
  fi
else
  # --no-memory: explicitly disable in .env
  python3 << PYEOF
import re
env_path = "${ENV_FILE}"
with open(env_path) as f:
    content = f.read()
if re.search(r"^MEMPALACE_ENABLED=", content, re.MULTILINE):
    content = re.sub(r"^MEMPALACE_ENABLED=.*", "MEMPALACE_ENABLED=false", content, flags=re.MULTILINE)
else:
    content += "\nMEMPALACE_ENABLED=false\n"
with open(env_path, "w") as f:
    f.write(content)
PYEOF
  log "MemPalace disabled for ${BOT_NAME} (--no-memory)"
fi

# ---------------------------------------------------------------------------
# Step 7 — Install gateway systemd service
# ---------------------------------------------------------------------------
if [[ "${INSTALL_GATEWAY}" == true ]]; then
  info "Step 7: Installing hermes-gateway-${BOT_NAME}.service..."

  mkdir -p "${HOME}/.config/systemd/user"

  cat > "${HOME}/.config/systemd/user/hermes-gateway-${BOT_NAME}.service" << EOF
[Unit]
Description=Hermes Agent Gateway (${BOT_NAME^} profile)
After=network.target
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${HERMES_VENV}/bin/python -m hermes_cli.main -p ${BOT_NAME} gateway run --replace
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
  systemctl --user enable "hermes-gateway-${BOT_NAME}"
  systemctl --user restart "hermes-gateway-${BOT_NAME}" 2>/dev/null || true
  sleep 2

  GW_STATE=$(systemctl --user is-active "hermes-gateway-${BOT_NAME}" 2>/dev/null || echo "unknown")
  log "Gateway service installed: ${GW_STATE}"
else
  warn "Skipping gateway install (--no-gateway)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}  ${BOT_NAME^} is hired and reporting for duty.${NC}"
echo    "  ─────────────────────────────────────────────────"
echo    "  Matrix     : @${BOT_NAME}:${MATRIX_DOMAIN}"
echo    "  Profile    : ~/.hermes/profiles/${BOT_NAME}/"
echo    "  Allowed    : ${LOCKED_ALLOWED}"
[[ ${#BOT_SKILLS[@]} -gt 0 ]] && \
echo    "  Skills     : ${BOT_SKILLS[*]}"
[[ "${INSTALL_MEMORY}" == true ]] && \
echo    "  Memory     : ${BOT_PALACE}"
[[ "${INSTALL_GATEWAY}"  == true ]] && \
echo    "  Gateway    : systemctl --user status hermes-gateway-${BOT_NAME}"
echo    "  Credentials: ${CREDS_FILE}"
echo ""
echo    "  Restart:  systemctl --user restart hermes-gateway-${BOT_NAME}"
echo    "  Logs:     journalctl --user -u hermes-gateway-${BOT_NAME} -f"
echo    "  Chat (via Donbot): hermes chat"
echo ""
