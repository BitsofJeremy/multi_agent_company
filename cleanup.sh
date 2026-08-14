#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — Full Multi-Agent Company Teardown
#
# Reverses launch.sh — removes the entire stack from the system:
#   1. Stop + disable all Hermes gateway services (bots + Donbot)
#   2. Remove ~/.hermes (all profiles, sessions, skills, memories)
#   3. crontab: strip the matins/vespers ritual entries
#   4. Stop + remove Matrix Synapse (service, venv, data, config)
#   5. Remove Element Desktop (apt purge)
#   6. Remove credentials file
#
# Run as your DESKTOP USER — NOT root. Script calls sudo internally.
#
# Usage:
#   bash cleanup.sh [OPTIONS]
#
# Options:
#   --skip-synapse     Skip Matrix Synapse removal
#   --skip-hermes      Skip Hermes + profiles removal
#   --keep-vault       Keep the Obsidian vault (~/vault) and ritual crontab
#   --skip-element     Skip Element Desktop removal
#   --keep-creds       Keep ~/Downloads/matrix_credentials.env
#   --yes              Skip confirmation prompt
#
# WARNING: This is destructive and irreversible.
#          All agent data, fact stores, vault pages, and Matrix history
#          will be lost. Back up ~/vault before running if you want the record.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config (aligned with launch.sh)
# ---------------------------------------------------------------------------
HERMES_HOME="${HOME}/.hermes"
VAULT_HOME="${HOME}/vault"
CREDS_FILE="${HOME}/Downloads/matrix_credentials.env"

# Flags
SKIP_SYNAPSE=false
SKIP_HERMES=false
KEEP_VAULT=false
SKIP_ELEMENT=false
KEEP_CREDS=false
AUTO_YES=false

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
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-synapse)   SKIP_SYNAPSE=true;   shift ;;
    --skip-hermes)    SKIP_HERMES=true;    shift ;;
    --keep-vault)     KEEP_VAULT=true;     shift ;;
    --skip-element)   SKIP_ELEMENT=true;   shift ;;
    --keep-creds)     KEEP_CREDS=true;     shift ;;
    --yes)            AUTO_YES=true;       shift ;;
    *) error "Unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ "$EUID" -eq 0 ]] && error "Do not run as root. Run as your desktop user."

echo ""
echo -e "${BOLD}${RED}  ██████╗ ██╗      █████╗ ███╗   ██╗${NC}"
echo -e "${BOLD}${RED}  ██╔══██╗██║     ██╔══██╗████╗  ██║${NC}"
echo -e "${BOLD}${RED}  ██████╔╝██║     ███████║██╔██╗ ██║${NC}"
echo -e "${BOLD}${RED}  ██╔═══╝ ██║     ██╔══██║██║╚██╗██║${NC}"
echo -e "${BOLD}${RED}  ██║     ███████╗██║  ██║██║ ╚████║${NC}"
echo -e "${BOLD}${RED}  ╚═╝     ╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝${NC}"
echo ""
echo -e "${BOLD}  Multi-Agent Company — FULL TEARDOWN${NC}"
echo    "  ─────────────────────────────────────────────────"
echo    "  This will permanently remove:"
[[ "${SKIP_HERMES}"    == false ]] && echo "    • All Hermes profiles and bot data  (~/.hermes — includes fact stores)"
[[ "${KEEP_VAULT}"     == false ]] && echo "    • The company vault + rituals        (${VAULT_HOME} + crontab)"
[[ "${SKIP_SYNAPSE}"   == false ]] && echo "    • Matrix Synapse + all room history  (/var/lib/matrix-synapse)"
[[ "${SKIP_ELEMENT}"   == false ]] && echo "    • Element Desktop (apt purge)"
[[ "${KEEP_CREDS}"     == false ]] && echo "    • Credentials file                  (${CREDS_FILE})"
echo ""

if [[ "${AUTO_YES}" == false ]]; then
  read -rp "  Type 'yes' to confirm full teardown: " _confirm
  [[ "${_confirm}" == "yes" ]] || { echo "Aborted."; exit 0; }
  echo ""
fi

# ---------------------------------------------------------------------------
# Phase 1 — Stop all Hermes gateway services
# ---------------------------------------------------------------------------
if [[ "${SKIP_HERMES}" == false ]]; then
  info "Phase 1: Stopping all Hermes gateway services..."

  # Stop default Donbot gateway
  if systemctl --user is-active "hermes-gateway" &>/dev/null; then
    systemctl --user stop "hermes-gateway" 2>/dev/null || true
    log "hermes-gateway stopped"
  fi
  if systemctl --user is-enabled "hermes-gateway" &>/dev/null; then
    systemctl --user disable "hermes-gateway" 2>/dev/null || true
  fi
  rm -f "${HOME}/.config/systemd/user/hermes-gateway.service"

  # Stop all per-bot gateways
  for _svc_file in "${HOME}/.config/systemd/user"/hermes-gateway-*.service; do
    [[ -f "${_svc_file}" ]] || continue
    _svc_name=$(basename "${_svc_file}" .service)
    if systemctl --user is-active "${_svc_name}" &>/dev/null; then
      systemctl --user stop "${_svc_name}" 2>/dev/null || true
      log "${_svc_name} stopped"
    fi
    systemctl --user disable "${_svc_name}" 2>/dev/null || true
    rm -f "${_svc_file}"
  done

  systemctl --user daemon-reload 2>/dev/null || true
  log "All gateway services removed"
fi

# ---------------------------------------------------------------------------
# Phase 2 — Remove Hermes home directory
# ---------------------------------------------------------------------------
if [[ "${SKIP_HERMES}" == false ]]; then
  info "Phase 2: Removing Hermes home (${HERMES_HOME})..."
  if [[ -d "${HERMES_HOME}" ]]; then
    rm -rf "${HERMES_HOME}"
    log "~/.hermes removed"
  else
    warn "~/.hermes not found — already clean"
  fi

  # Remove hermes symlink from ~/.local/bin
  rm -f "${HOME}/.local/bin/hermes"
  log "hermes symlink removed from ~/.local/bin"
fi

# ---------------------------------------------------------------------------
# Phase 3 — Rituals (crontab) and vault
#
# The fact stores live under ~/.hermes/profiles/<agent>/mnemosyne/ and are
# removed with Phase 2. The vault is a separate directory (~/vault) and the
# rituals are user crontab entries — handle them explicitly.
# ---------------------------------------------------------------------------
if [[ "${KEEP_VAULT}" == false ]]; then
  # Strip matins/vespers from the user crontab
  if crontab -l 2>/dev/null | grep -qE 'matins|vespers'; then
    info "Phase 3: Removing ritual crontab entries..."
    crontab -l 2>/dev/null | grep -vE 'matins|vespers' | crontab -
    log "Ritual crontab entries removed"
  else
    warn "No ritual crontab entries found — nothing to strip"
  fi

  # Remove the vault itself
  info "Phase 3: Removing Obsidian vault (${VAULT_HOME})..."
  if [[ -d "${VAULT_HOME}" ]]; then
    rm -rf "${VAULT_HOME}"
    log "~/vault removed (back it up first if you wanted the record — too late now)"
  else
    warn "~/vault not found — already clean"
  fi
else
  warn "Keeping vault + rituals (--keep-vault)"
fi

# ---------------------------------------------------------------------------
# Phase 4 — Matrix Synapse
# ---------------------------------------------------------------------------
if [[ "${SKIP_SYNAPSE}" == false ]]; then
  info "Phase 4: Removing Matrix Synapse..."

  if sudo systemctl is-active matrix-synapse &>/dev/null; then
    sudo systemctl stop matrix-synapse 2>/dev/null || true
    log "matrix-synapse service stopped"
  fi
  if sudo systemctl is-enabled matrix-synapse &>/dev/null; then
    sudo systemctl disable matrix-synapse 2>/dev/null || true
  fi
  sudo rm -f /etc/systemd/system/matrix-synapse.service
  sudo systemctl daemon-reload 2>/dev/null || true

  # Remove Synapse venv, config, data, and logs
  for _dir in /opt/synapse /etc/matrix-synapse /var/lib/matrix-synapse /var/log/matrix-synapse; do
    if sudo test -d "${_dir}" 2>/dev/null; then
      sudo rm -rf "${_dir}"
      log "Removed ${_dir}"
    fi
  done

  # Remove Element apt repo (added by launch.sh)
  sudo rm -f /etc/apt/sources.list.d/element-io.list
  sudo rm -f /usr/share/keyrings/element-io-archive-keyring.gpg

  # Remove synapse system user
  if id synapse &>/dev/null; then
    sudo userdel synapse 2>/dev/null || warn "Could not remove synapse system user"
    log "synapse system user removed"
  fi

  log "Matrix Synapse removed"
fi

# ---------------------------------------------------------------------------
# Phase 6 — Element Desktop
# ---------------------------------------------------------------------------
if [[ "${SKIP_ELEMENT}" == false ]]; then
  info "Phase 6: Removing Element Desktop..."
  if dpkg -l element-desktop &>/dev/null 2>&1; then
    sudo apt-get purge -y element-desktop --quiet 2>/dev/null || warn "apt purge element-desktop failed"
    sudo apt-get autoremove -y --quiet 2>/dev/null || true
    log "Element Desktop removed"
  else
    warn "Element Desktop not installed via apt — skipping"
  fi
fi

# ---------------------------------------------------------------------------
# Phase 5 — Element Desktop
# ---------------------------------------------------------------------------
if [[ "${SKIP_ELEMENT}" == false ]]; then
  info "Phase 5: Removing Element Desktop..."
  if dpkg -l element-desktop &>/dev/null 2>&1; then
    sudo apt-get purge -y element-desktop --quiet 2>/dev/null || warn "apt purge element-desktop failed"
    sudo apt-get autoremove -y --quiet 2>/dev/null || true
    log "Element Desktop removed"
  else
    warn "Element Desktop not installed via apt — skipping"
  fi
fi

# ---------------------------------------------------------------------------
# Phase 6 — Credentials file
# ---------------------------------------------------------------------------
if [[ "${KEEP_CREDS}" == true ]]; then
  warn "Keeping credentials file (--keep-creds): ${CREDS_FILE}"
elif [[ -f "${CREDS_FILE}" ]]; then
  info "Phase 6: Removing credentials file..."
  rm -f "${CREDS_FILE}"
  log "Credentials file removed: ${CREDS_FILE}"
else
  warn "Credentials file not found — already clean"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}  Teardown complete.${NC}"
echo    "  ─────────────────────────────────────────────────"
[[ "${SKIP_HERMES}"    == false ]] && echo "  Hermes    : removed"
[[ "${KEEP_VAULT}"     == false ]] && echo "  Vault     : removed (fact stores went with ~/.hermes)"
[[ "${SKIP_SYNAPSE}"   == false ]] && echo "  Synapse   : removed"
[[ "${SKIP_ELEMENT}"   == false ]] && echo "  Element   : removed"
[[ "${KEEP_CREDS}"     == false ]] && echo "  Creds     : removed"
echo ""
echo    "  To rebuild the company, run: bash launch.sh"
echo ""
