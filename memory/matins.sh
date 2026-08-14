#!/usr/bin/env bash
# ============================================================================
# matins.sh — the morning ritual
# ============================================================================
# At 06:50 (Mon-Fri) the agent opens the day: builds today's vault page,
# carries forward whatever is still open from yesterday, and sends the
# briefing to the configured home channel (the gateway handles delivery).
# Facts first — what's due, what's overdue and by how much, what's scheduled —
# then a line or two of its own.
#
# Works on day one with NO external APIs: it reads and writes the vault only.
#
# Installed by launch.sh to ~/.hermes/rituals/matins.sh and scheduled via the
# user's crontab (cron does not expand `~`, so the absolute path is written).
#
# NOTE: `hermes chat -q` (non-interactive, one-shot) is the invocation the
# Hermes docs use for smoke tests. Verify against your installed version once
# — `hermes chat --help` — before trusting the cron.
# ============================================================================
set -euo pipefail

# cron runs with a near-empty environment; be explicit about everything.
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
VENV="${HERMES_VENV:-$HERMES_HOME/hermes-agent/venv}"

if [[ -f "$VENV/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
fi

if [[ -f "$HERMES_HOME/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$HERMES_HOME/.env"
  set +a
fi

TODAY="$(date +%F)"
YESTERDAY="$(date -d 'yesterday' +%F 2>/dev/null || date -v-1d +%F)"

read -r -d '' PROMPT <<EOF || true
Morning. Open the day.

1. Create Daily/${TODAY}.md if it doesn't exist, with the standard frontmatter
   and sections (Tasks, Schedule, Log, Threads, Wins, Context).
2. Read Daily/${YESTERDAY}.md. Carry any unfinished task forward into today's
   Tasks — copy it, don't edit yesterday's page. Note how long anything has
   been outstanding.
3. Send me the briefing, in this order:
   - due today
   - overdue, with how many days each has been sitting, and a plain count
   - anything scheduled
   - what's still open from yesterday's Threads
4. Then one or two lines of your own — what you'd start with, or whatever you
   actually think. Not a summary of the above.

Facts before flourish; I'm reading this before coffee. If there is genuinely
nothing on today, say so in a sentence and don't pad it.
EOF

echo "=== matins ${TODAY} $(date +%T) ==="
hermes chat -q "$PROMPT"
echo "=== matins complete $(date +%T) ==="
