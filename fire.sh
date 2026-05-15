#!/usr/bin/env bash
# =============================================================================
# fire.sh — Terminate an AI Agent
#
# Reverses hire.sh for a named bot:
#   1. Stop + disable + remove the Hermes gateway systemd service
#   2. Remove the Hermes profile directory
#   3. Remove the MemPalace memory palace
#   4. Deactivate the Matrix account (soft-delete via admin API)
#   5. Remove the bot's password entry from matrix_credentials.env
#
# Usage:
#   bash fire.sh <botname> [OPTIONS]
#
# Options:
#   --keep-matrix      Skip Matrix account deactivation
#   --keep-memory      Skip MemPalace palace removal
#   --keep-creds       Skip credential file cleanup
#   --yes              Skip confirmation prompt
#
# Examples:
#   bash fire.sh writerbot
#   bash fire.sh engineerbot --keep-matrix --yes
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config defaults (aligned with hire.sh / launch.sh)
# ---------------------------------------------------------------------------
MATRIX_DOMAIN="localhost"
MATRIX_PORT="8008"
MATRIX_ADMIN_USER="admin"
MATRIX_ADMIN_PASS="changeme"

HERMES_HOME="${HOME}/.hermes"
MEMPALACE_HOME="${HOME}/.mempalace"
CREDS_FILE="${HOME}/Downloads/matrix_credentials.env"

# ---------------------------------------------------------------------------
# Colours & helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
info()  { echo -e "${BLUE}[→]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
BOT_NAME=""
if [[ $# -gt 0 && "$1" != --* ]]; then
  BOT_NAME="${1,,}"
  shift
fi

KEEP_MATRIX=false
KEEP_MEMORY=false
KEEP_CREDS=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-matrix)    KEEP_MATRIX=true;    shift ;;
    --keep-memory)    KEEP_MEMORY=true;    shift ;;
    --keep-creds)     KEEP_CREDS=true;     shift ;;
    --yes)            AUTO_YES=true;       shift ;;
    *) error "Unknown option: $1" ;;
  esac
done

[[ -z "${BOT_NAME}" ]] && error "Usage: bash fire.sh <botname> [OPTIONS]"

if ! [[ "${BOT_NAME}" =~ ^[a-z][a-z0-9_-]*$ ]]; then
  error "Bot name must be lowercase alphanumeric+underscore. Got: '${BOT_NAME}'"
fi

export PATH="${HOME}/.local/bin:${PATH}"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ "$EUID" -eq 0 ]] && error "Do not run as root."

echo ""
echo -e "${BOLD}${RED}  Firing: @${BOT_NAME}:${MATRIX_DOMAIN}${NC}"
echo    "  ─────────────────────────────────────────────────"
echo    "  Profile  : ${HERMES_HOME}/profiles/${BOT_NAME}/"
echo    "  Service  : hermes-gateway-${BOT_NAME}"
echo    "  Memory   : ${MEMPALACE_HOME}/data/${BOT_NAME}/"
echo    "  Matrix   : $( [[ "${KEEP_MATRIX}"    == true ]] && echo "kept" || echo "deactivated" )"
echo ""

if [[ "${AUTO_YES}" == false ]]; then
  read -rp "  Confirm firing ${BOT_NAME}? [y/N] " _confirm
  [[ "${_confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }
  echo ""
fi

# ---------------------------------------------------------------------------
# Step 1 — Stop + remove gateway systemd service
# ---------------------------------------------------------------------------
info "Step 1: Removing hermes-gateway-${BOT_NAME}.service..."

SERVICE_FILE="${HOME}/.config/systemd/user/hermes-gateway-${BOT_NAME}.service"

if systemctl --user is-active "hermes-gateway-${BOT_NAME}" &>/dev/null; then
  systemctl --user stop "hermes-gateway-${BOT_NAME}" 2>/dev/null || true
  log "Service stopped"
else
  warn "Service not running (already stopped or never installed)"
fi

if systemctl --user is-enabled "hermes-gateway-${BOT_NAME}" &>/dev/null; then
  systemctl --user disable "hermes-gateway-${BOT_NAME}" 2>/dev/null || true
  log "Service disabled"
fi

if [[ -f "${SERVICE_FILE}" ]]; then
  rm -f "${SERVICE_FILE}"
  systemctl --user daemon-reload
  log "Service file removed and daemon reloaded"
else
  warn "Service file not found: ${SERVICE_FILE}"
fi

# ---------------------------------------------------------------------------
# Step 2 — Remove Hermes profile
# ---------------------------------------------------------------------------
info "Step 2: Removing Hermes profile '${BOT_NAME}'..."

PROFILE_DIR="${HERMES_HOME}/profiles/${BOT_NAME}"

if [[ -d "${PROFILE_DIR}" ]]; then
  rm -rf "${PROFILE_DIR}"
  log "Profile removed: ${PROFILE_DIR}"
else
  warn "Profile directory not found: ${PROFILE_DIR}"
fi

# ---------------------------------------------------------------------------
# Step 3 — Remove MemPalace palace
# ---------------------------------------------------------------------------
if [[ "${KEEP_MEMORY}" == true ]]; then
  warn "Keeping MemPalace palace (--keep-memory)"
else
  info "Step 3: Removing MemPalace palace for ${BOT_NAME}..."
  BOT_PALACE="${MEMPALACE_HOME}/data/${BOT_NAME}"
  if [[ -d "${BOT_PALACE}" ]]; then
    rm -rf "${BOT_PALACE}"
    log "Palace removed: ${BOT_PALACE}"
  else
    warn "Palace not found: ${BOT_PALACE}"
  fi
fi

# ---------------------------------------------------------------------------
# Step 4 — Deactivate Matrix account
# ---------------------------------------------------------------------------
if [[ "${KEEP_MATRIX}" == true ]]; then
  warn "Keeping Matrix account (--keep-matrix)"
else
  info "Step 4: Deactivating @${BOT_NAME}:${MATRIX_DOMAIN} in Matrix..."

  if curl -sf "http://127.0.0.1:${MATRIX_PORT}/_matrix/client/versions" >/dev/null 2>&1; then
    python3 << PYEOF
import json, urllib.request, sys

HS    = "http://127.0.0.1:${MATRIX_PORT}"
BOT   = "@${BOT_NAME}:${MATRIX_DOMAIN}"
ADMIN = "${MATRIX_ADMIN_USER}"
APASS = "${MATRIX_ADMIN_PASS}"

def api(path, data=None, token=None, method=None):
    url = HS + path
    headers = {"Content-Type": "application/json"}
    if token: headers["Authorization"] = f"Bearer {token}"
    body = json.dumps(data).encode() if data else None
    m = method or ("POST" if body else "GET")
    req = urllib.request.Request(url, data=body, method=m, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code in (404, 400):
            return None
        raise

r = api("/_matrix/client/v3/login",
        {"type": "m.login.password", "user": ADMIN, "password": APASS})
token = r["access_token"]

# Deactivate via Synapse admin API (erase=false preserves room history)
encoded_bot = BOT.replace("@", "%40").replace(":", "%3A")
result = api(f"/_synapse/admin/v1/deactivate/{encoded_bot}",
             data={"erase": False}, token=token, method="POST")
if result is not None:
    print(f"  ✓ {BOT} deactivated in Matrix")
else:
    print(f"  {BOT} not found in Matrix or already deactivated")
PYEOF
    log "Matrix deactivation done"
  else
    warn "Matrix Synapse not running — skipping deactivation"
  fi
fi

# ---------------------------------------------------------------------------
# Step 5 — Remove credentials entry
# ---------------------------------------------------------------------------
if [[ "${KEEP_CREDS}" == true ]]; then
  warn "Keeping credentials entry (--keep-creds)"
elif [[ -f "${CREDS_FILE}" ]]; then
  info "Step 5: Removing ${BOT_NAME} credentials from ${CREDS_FILE}..."
  PASS_KEY="MATRIX_$(echo "${BOT_NAME}" | tr '[:lower:]' '[:upper:]' | tr -d '_-')"
  # Remove the password line; leave all other entries intact
  sed -i "/^${PASS_KEY}=/d" "${CREDS_FILE}" 2>/dev/null || true
  log "Credentials entry removed: ${PASS_KEY}"
else
  warn "Credentials file not found — skipping"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}  ${BOT_NAME^} has been let go.${NC}"
echo    "  ─────────────────────────────────────────────────"
echo    "  Service  : removed"
echo    "  Profile  : removed"
[[ "${KEEP_MEMORY}"    == false ]] && echo "  Memory   : removed"
[[ "${KEEP_MATRIX}"    == false ]] && echo "  Matrix   : deactivated"
[[ "${KEEP_CREDS}"     == false ]] && echo "  Creds    : cleaned"
echo ""
