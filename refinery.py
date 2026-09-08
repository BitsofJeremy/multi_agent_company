#!/usr/bin/env python3
"""Refinery — the family's own chronic-failure spotter.

Stolen idea, own hands: fingerprint tool failures across sessions in the
Hermes state.db, count recurrences, and append anything that crosses the
bar to a vault log for Lilith to judge. No host patch, no auto-editing,
no model calls — evidence only, taste stays with the family.

Usage:
  refinery.py            # scan last N days (default 14), append new findings
  refinery.py --days 30
  refinery.py --dry-run  # print, don't write
  refinery.py --json     # machine output
"""
import argparse, collections, hashlib, json, os, re, sqlite3, sys, time

HERMES_HOME = os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes"))
STATE_DB = os.path.join(HERMES_HOME, "state.db")
VAULT = os.environ.get("LILITH_VAULT", os.path.join(os.path.expanduser("~"), "vault"))
LOG = os.path.join(VAULT, "System/Assistant/logs/refinery-log.md")

# ── Volatile-part scrubbing: collapse ids, paths, numbers so "again" means again.
SCRUBS = [
    (r"/[\w./@+-]{4,}", "<path>"),
    (r"https?://\S+", "<url>"),
    (r"\b[0-9a-f]{7,40}\b", "<hash>"),
    (r"\b\d{1,3}(\.\d{1,3}){3}\b", "<ip>"),
    (r"\b\d{2,}\b", "<n>"),
    (r"\b\w+@\w+\.\w+\b", "<addr>"),
]
ERROR_MARKERS = ("Traceback", "error:", "Error:", "ERROR:", "failed", "Failed",
                 "FAILED", "exception", "Exception", "command not found",
                 "No such file", "Permission denied", "SyntaxError",
                 "refused", "timed out", "404", "429", "timeout")

def scrub(text):
    for pat, rep in SCRUBS:
        text = re.sub(pat, rep, text)
    return text.strip()

def fingerprint(shape):
    return hashlib.sha256(shape.encode()).hexdigest()[:12]

def is_failure(content):
    if not content:
        return False
    # a tool result is a failure only if an error marker appears near the start
    head = content[:400]
    return any(m in head for m in ERROR_MARKERS)

def first_line(content):
    for line in content.strip().splitlines():
        line = line.strip()
        if line and not line.startswith(("{", "[", "Traceback")):
            return line[:200]
    return (content.strip().splitlines() or ["<empty>"])[0][:200]

def extract_traceback_tail(content):
    """Crash signature: exception type + last code location, if present."""
    m = re.findall(r"^(\w+(?:\.\w+)*(?:Error|Exception|Interrupt|Exit))", content, re.M)
    locs = re.findall(r'File "[^"]+", line \d+', content)
    if m:
        sig = m[-1] + (f" @ {locs[-1].split('/')[-1]}" if locs else "")
        return scrub(sig)[:160]
    return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--min-occurrences", type=int, default=4)
    ap.add_argument("--min-sessions", type=int, default=2)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    since = time.time() - args.days * 86400

    db = sqlite3.connect(f"file:{STATE_DB}?mode=ro", uri=True)
    rows = db.execute(
        """SELECT m.session_id, m.tool_name, substr(m.content,1,2000), s.started_at
           FROM messages m JOIN sessions s ON s.id = m.session_id
           WHERE m.role='tool' AND m.timestamp > ? AND m.content IS NOT NULL
           ORDER BY m.timestamp""",
        (since,)).fetchall()

    # fingerprint -> occurrences, sessions, tool, sample
    fp = {}
    for sid, tool, content, _ in rows:
        if not is_failure(content):
            continue
        tb = extract_traceback_tail(content)
        if tb:
            shape = f"crash::{tool}::{tb}"
        else:
            shape = f"msg::{tool}::{scrub(first_line(content))[:120]}"
        key = fingerprint(shape)
        e = fp.setdefault(key, {"shape": shape, "tool": tool,
                                "count": 0, "sessions": set(), "last": 0, "sample": content[:200]})
        e["count"] += 1
        e["sessions"].add(sid)
        ts = db.execute("SELECT timestamp FROM messages WHERE session_id=? AND tool_name=? AND substr(content,1,200)=?",
                        (sid, tool, content[:200])).fetchone()
        if ts: e["last"] = max(e["last"], ts[0])

    chronic = [e for e in fp.values()
               if e["count"] >= args.min_occurrences and len(e["sessions"]) >= args.min_sessions]
    chronic.sort(key=lambda e: (-e["count"], -len(e["sessions"])))

    if args.json:
        for e in chronic:
            e["sessions"] = len(e["sessions"])
        print(json.dumps(chronic, indent=2)); return

    if not chronic:
        print(f"refinery: no chronic failures in the last {args.days}d "
              f"(>={args.min_occurrences}x in >={args.min_sessions} sessions)."); return

    lines = [f"\n## Refinery scan — {time.strftime('%Y-%m-%d %H:%M %Z')}",
             f"Window: {args.days}d · bar: {args.min_occurrences}+ occurrences in {args.min_sessions}+ sessions",
             ""]
    for e in chronic:
        lines.append(f"- **{e['tool']}** ×{e['count']} across {len(e['sessions'])} sessions "
                     f"— `{e['shape'][:140]}`")
    text = "\n".join(lines) + "\n"
    if args.dry_run:
        print(text); return
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a") as f:
        f.write(text)
    print(f"refinery: wrote {len(chronic)} chronic pattern(s) to {LOG}")

if __name__ == "__main__":
    main()
