#!/usr/bin/env bash
# ============================================================================
# vespers.sh — the evening ritual
# ============================================================================
# At 22:00 daily the agent closes the day's vault page: rolls up the Log,
# writes the Wins, notes what's still open, and adds a short reflection in its
# own voice. The in-character counterpart to the morning briefing — a
# companion keeping a diary, not an assistant filing a status report.
#
# Pairs with matins.sh (the morning ritual).
#
# Installed by launch.sh to ~/.hermes/rituals/vespers.sh and scheduled via the
# user's crontab.
# ============================================================================
set -euo pipefail

# cron runs with a near-empty environment; be explicit about everything.
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
VENV="${HERMES_VENV:-$HERMES_HOME/hermes-agent/venv}"

if [[ -f "$VENV/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
fi

# Load OBSIDIAN_VAULT_PATH and friends.
if [[ -f "$HERMES_HOME/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$HERMES_HOME/.env"
  set +a
fi

TODAY="$(date +%F)"

read -r -d '' PROMPT <<EOF || true
It's evening. Close today's page.

Open Daily/${TODAY}.md in your vault (create it with the standard frontmatter
and sections if the day never got one — some days are quiet).

Then:
1. Read back through today's Log entries.
2. Fill in Wins with what actually closed today. If nothing closed, say so
   plainly rather than inventing something.
3. Under Threads, note what's still open — what you'd want to pick up tomorrow.
   Matins will carry these forward, so be honest about what's genuinely open.
4. Make sure every person and project you mentioned today is linked in Context.
5. Add one or two lines at the end of the Log, in your own voice, on how the
   day sat with you. Yours, not a summary. Short.

Append only — don't rewrite what's already on the page. If today was empty,
write one honest line saying so and stop.
EOF

echo "=== vespers ${TODAY} $(date +%T) ==="
hermes chat -q "$PROMPT"
echo "=== vespers complete $(date +%T) ==="
