#!/usr/bin/env bash
# ============================================================================
# status.sh — the company heartbeat
#
# One screen: is the infrastructure up, is every agent alive, is anything
# actually being remembered, did the rituals run, does today's page exist.
#
# Exit code 0 = everything healthy, 1 = something is down (cron-friendly).
#
# Usage:
#   bash status.sh
# ============================================================================
set -uo pipefail   # NOT -e: failing checks are the whole point

HERMES_HOME="${HOME}/.hermes"
VAULT_HOME="${HOME}/vault"
RITUALS_LOG="${HOME}/rituals.log"
PAPERCLIP_HOME="${HOME}/paperclip"
TODAY="$(date +%F)"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'
DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

FAILURES=0
ok()  { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
bad() { printf "  ${RED}✗${NC} %s\n" "$*"; FAILURES=$((FAILURES+1)); }
na()  { printf "  ${DIM}—${NC} %s\n" "$*"; }

svc_state() { systemctl is-active "$1" 2>/dev/null || true; }

# ----------------------------------------------------------------------------
printf "${BOLD}Company status${NC} — %s %s\n\n" "$(date '+%A %Y-%m-%d')" "$(date '+%H:%M %Z')"

# --- Infrastructure ---------------------------------------------------------
printf "${BOLD}Infrastructure${NC}\n"

_syn="$(svc_state matrix-synapse)"
if [[ "$_syn" == "active" ]]; then
  ok "matrix-synapse    active"
else
  bad "matrix-synapse    ${_syn:-not found}"
fi

# --- Agents -----------------------------------------------------------------
printf "\n${BOLD}Agents${NC}\n"

# memory_counts <db-path> → "working/episodic/facts" or reason
memory_counts() {
  local db="$1"
  if [[ ! -f "$db" ]]; then
    echo "no memories yet"
    return
  fi
  if command -v sqlite3 &>/dev/null; then
    sqlite3 -readonly "$db" \
      "SELECT (SELECT COUNT(*) FROM working_memory)
            || '/' || (SELECT COUNT(*) FROM episodic_memory)
            || '/' || (SELECT COUNT(*) FROM facts);" 2>/dev/null \
      || echo "unreadable"
  else
    echo "sqlite3 not installed"
  fi
}

# Donbot (default profile, service 'hermes-gateway')
_don="$(svc_state hermes-gateway)"
if [[ "$_don" == "active" ]]; then
  ok "donbot (CEO)      active — memory: $(memory_counts "${HERMES_HOME}/mnemosyne/data/mnemosyne.db")"
elif systemctl --user list-unit-files 2>/dev/null | grep -q '^hermes-gateway\.service'; then
  bad "donbot (CEO)      ${_don:-unknown}"
else
  na "donbot (CEO)      not installed (run launch.sh)"
fi

# Hired bots — one row per installed gateway service
_shopt_nullglob="$(shopt -p nullglob || true)"
shopt -s nullglob
_bot_seen=0
for _svc in "${HOME}"/.config/systemd/user/hermes-gateway-*.service; do
  _name="$(basename "${_svc}" .service)"
  _name="${_name#hermes-gateway-}"
  _bot_seen=1
  _st="$(svc_state "hermes-gateway-${_name}")"
  _mem="$(memory_counts "${HERMES_HOME}/profiles/${_name}/mnemosyne/data/mnemosyne.db")"
  if [[ "$_st" == "active" ]]; then
    ok "$(printf '%-18s' "${_name}")  active — memory: ${_mem}"
  else
    bad "$(printf '%-18s' "${_name}")  ${_st:-unknown} — memory: ${_mem}"
  fi
done
eval "$_shopt_nullglob"
[[ $_bot_seen -eq 0 ]] && na "no hired agents yet (run hire.sh)"

# --- Rituals + vault (CEO only; skipped entirely with --skip-memory) -------
if [[ -d "${HERMES_HOME}/rituals" || -d "${VAULT_HOME}" ]]; then
  printf "\n${BOLD}Rituals & vault${NC}\n"
  if grep -q "=== matins ${TODAY}" "${RITUALS_LOG}" 2>/dev/null; then
    ok "matins ran today"
  else
    printf "  ${YELLOW}!${NC} matins has not run today (weekdays 06:50)\n"
  fi
  if grep -q "=== vespers ${TODAY}" "${RITUALS_LOG}" 2>/dev/null; then
    ok "vespers ran today"
  else
    printf "  ${YELLOW}!${NC} vespers has not run today (22:00)\n"
  fi
  if [[ -f "${VAULT_HOME}/Daily/${TODAY}.md" ]]; then
    ok "daily page exists (vault/Daily/${TODAY}.md)"
  else
    printf "  ${YELLOW}!${NC} no daily page yet — vault/Daily/${TODAY}.md\n"
  fi
fi

# --- Paperclip (optional) ----------------------------------------------------
printf "\n${BOLD}Paperclip${NC}\n"
if [[ -d "${PAPERCLIP_HOME}" ]]; then
  _code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:3100 2>/dev/null || echo 000)"
  if [[ "${_code}" =~ ^2 ]]; then
    ok "dashboard up — http://127.0.0.1:3100 (${_code})"
  else
    bad "dashboard not responding (${_code}) — cd ~/paperclip && pnpm dev"
  fi
else
  na "not installed (launch.sh --with-paperclip)"
fi

# --- Verdict -----------------------------------------------------------------
printf "\n"
if [[ ${FAILURES} -eq 0 ]]; then
  printf "${GREEN}${BOLD}All systems nominal.${NC}\n"
  exit 0
else
  printf "${RED}${BOLD}${FAILURES} problem(s) detected.${NC}\n"
  exit 1
fi
