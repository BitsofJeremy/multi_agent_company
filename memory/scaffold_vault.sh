#!/usr/bin/env bash
# ============================================================================
# scaffold_vault.sh — create the Obsidian vault skeleton
# ============================================================================
# Run ONCE (launch.sh does it for you). Safe to re-run: it creates missing
# folders and seeds missing files, and NEVER overwrites a file that already
# exists — the vault accumulates real content, and a re-run must not eat it.
# Files it skips are reported so you can diff them yourself.
#
#   ./scaffold_vault.sh ~/vault
#
# The vault is plain Markdown on disk. Browse it in Obsidian on any machine
# via Syncthing or rsync — no server, no plugin, no API key. See README.md.
# ============================================================================
set -euo pipefail

VAULT_PATH="${1:-${OBSIDIAN_VAULT_PATH:-}}"
if [[ -z "$VAULT_PATH" ]]; then
  echo "usage: $0 /path/to/vault   (or set OBSIDIAN_VAULT_PATH)" >&2
  exit 64
fi

TODAY="$(date +%F)"
created=0 skipped=0

# Write stdin to $1 only if it does not already exist.
write_if_absent() {
  local dest="$1"
  if [[ -e "$dest" ]]; then
    echo "  skip    ${dest#"$VAULT_PATH"/}  (exists)"
    skipped=$((skipped + 1))
    cat >/dev/null            # drain stdin so the heredoc doesn't SIGPIPE
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cat > "$dest"
  echo "  create  ${dest#"$VAULT_PATH"/}"
  created=$((created + 1))
}

echo "Scaffolding vault at $VAULT_PATH"

mkdir -p "$VAULT_PATH"/{Daily,System/Assistant/logs,Work,Personal,Projects,People,Inbox}

# --- System/Assistant/context.md --------------------------------------------
write_if_absent "$VAULT_PATH/System/Assistant/context.md" <<'EOF'
# Context

What's live right now. Read this when the present situation matters to how
you answer.

## Who you talk to

[Describe the operator and deploy context here.]

## Live right now

- Fresh deploy.

---
Last updated: __TODAY__
EOF

# --- System/Assistant/preferences.md ----------------------------------------
write_if_absent "$VAULT_PATH/System/Assistant/preferences.md" <<'EOF'
# Preferences

How the operator likes things done. Read this when unsure about tone, format,
or approach.

## Communication

- Concise and direct.
- Facts first, personality second. Times, names, numbers, what's due —
  clean and up front.
- Explain the mechanism, not just the result.
- Say plainly when something failed or was skipped.

## Briefings

- Morning (Matins): due today, then overdue with age, then scheduled, then
  what's open. Overdue count stated plainly.
- Evening (Vespers): what actually closed, what's still open, one honest line.
- An empty day gets said, not padded.

---
Last updated: __TODAY__
EOF

# --- System/Assistant/environment.md ----------------------------------------
write_if_absent "$VAULT_PATH/System/Assistant/environment.md" <<'EOF'
# Environment

The machine and the ways it has broken before. Read this BEFORE
troubleshooting — most failures here are already described.

## Hardware

[Describe the box here.]

## Services

| Service | Bind | Unit |
|---|---|---|
| [Service name] | [address] | [systemd unit] |

## Key paths

| What | Path |
|---|---|
| Hermes home | ~/.hermes/ |
| Hot memory | ~/.hermes/memories/MEMORY.md, USER.md |
| Fact store (Mnemosyne) | ~/.hermes/mnemosyne/data/ |
| This vault | __VAULT_PATH__ |

## Known issues & patterns

[Document recurring failure patterns here as they're discovered.]

---
Last updated: __TODAY__
EOF

# --- System/Assistant/logs/issues-fixes-log.md -------------------------------
write_if_absent "$VAULT_PATH/System/Assistant/logs/issues-fixes-log.md" <<'EOF'
# Issues & Fixes Log

Append-only. Every technical failure and what actually resolved it.

Format:

### YYYY-MM-DD — short name
- **Symptom:** what was observed
- **Cause:** what was actually wrong
- **Fix:** what resolved it
- **Status:** resolved | recurring | open

---

_No entries yet._
EOF

# --- People/MOC.md ------------------------------------------------------------
write_if_absent "$VAULT_PATH/People/MOC.md" <<'EOF'
# People — Map of Content

One note per person. Everyone mentioned in a daily page should be linked here.

---
Last updated: __TODAY__
EOF

# --- Inbox/README.md ----------------------------------------------------------
write_if_absent "$VAULT_PATH/Inbox/README.md" <<'EOF'
# Inbox

Unclassified. When you don't know where something belongs it lands here,
rather than getting forced into the wrong folder.

Review periodically and file.
EOF

# Substitute date tokens
find "$VAULT_PATH" -name '*.md' -type f -exec \
  perl -pi -e "s|__TODAY__|$TODAY|g; s|\Q__VAULT_PATH__\E|$VAULT_PATH|g" {} +

echo
echo "Done: $created created, $skipped skipped."
