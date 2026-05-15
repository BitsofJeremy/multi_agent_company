# Multi-Machine Agent Federation — Research & Implementation Plan

**Audience:** This document is written for an LLM or engineer tasked with implementing a
multi-machine Hermes agent network. Read it fully before writing any code.

**Status:** WireGuard mesh is already operational across all machines on a private IPv4
network. Approach B (Paperclip as cross-host bus) is the chosen starting point.
A hybrid with Matrix federation is the long-term target but not the immediate goal.

---

## The Concrete Use Case

> "I want an agent on my VPS to receive build/deploy/edit commands from my Mac, deploy
> and maintain a website, and run scheduled sysadmin health checks via cron."

Two distinct agent roles on the VPS:

| Role | Agent name (suggestion) | Trigger | Responsibilities |
|------|------------------------|---------|-----------------|
| **Deploy agent** | `deploybot` | Paperclip task from Mac's Donbot | Pull repo, build site, restart services, report status |
| **Cron/sysadmin agent** | `cronbot` | systemd timer (scheduled) | Disk/memory/CPU checks, log rotation, uptime report, alert on anomalies |

These can be two separate Hermes profiles on the VPS, or one profile with two gateway
instances (one event-driven, one cron-invoked). Two profiles is cleaner.

---

## The Question (original)

> "I have multiple computers and VMs with Hermes Agents — my Linux desktop, a Mac,
> a VPS, and a Raspberry Pi. How would the agents talk and work with each other?"

---

## Context: The Current Single-Host Setup

On a single Debian VM, `launch.sh` installs:
- **Matrix Synapse** at `http://127.0.0.1:8008` — the agents' message bus
- **Hermes Agent** — `donbot` (CEO) as default profile, other agents via `hire.sh`
- **Paperclip** at `http://localhost:3100` — the company control plane (org chart, tasks)
- **MemPalace** — per-agent local memory palaces

All agents run as systemd user services on the same host. Donbot is the only agent with a
Matrix gateway open to the human operator. Peer agents receive work via Paperclip's
`hermes_local` adapter and report results back.

---

## The Federation Problem

When agents live on different machines, three things break:

| Thing | Why it breaks |
|---|---|
| Matrix rooms | `127.0.0.1:8008` is not reachable from other hosts |
| Paperclip `hermes_local` adapter | Calls local Hermes binary — won't reach a remote agent |
| MemPalace | Each host has its own local palace; they don't share memories |

**WireGuard solves the networking layer.** Every host already has a stable WireGuard IPv4
address. No Tailscale or port-forwarding needed. Services can bind to the WireGuard
interface and be reachable at e.g. `10.x.x.x:3100`.

---

## Approach B — Paperclip as Cross-Host Bus (CHOSEN — implement this first)

Central Paperclip runs on the Mac (or the desktop Linux box — wherever the human operator
sits). Remote agents on the VPS expose their Hermes runtime via a thin HTTP shim. Paperclip
dispatches tasks to the right agent by URL. No Matrix federation needed. WireGuard provides
the secure transport.

### Topology (WireGuard private IPv4)

```
Mac (10.x.x.1)       → Donbot CEO (Paperclip UI + Matrix gateway)
VPS (10.x.x.2)       → deploybot  (web deploy/build tasks)
                      → cronbot    (scheduled sysadmin checks)
Linux Desktop (10.x.x.3) → local dev agents (optional)
RPi (10.x.x.4)       → cronbot-rpi (lightweight monitoring, sensors)
```

### How Paperclip reaches a remote agent

The `hermes_local` adapter calls a local binary. For remote agents you need one of:

**Option B1 — HTTP shim (recommended):** A minimal FastAPI/Flask service on each remote
host that accepts `POST /task` with a JSON body `{"query": "..."}`, shells out to
`hermes -p <profile> chat -q "$query" --yolo`, and returns the result. Paperclip gets a
new `hermes_remote` adapter that POSTs to `http://10.x.x.2:<port>/task`.

**Option B2 — SSH exec:** Paperclip's adapter SSHes into the remote host and runs
`hermes -p deploybot chat -q "$task" --yolo`. Simpler to stand up, harder to scale.
Use this for a quick proof-of-concept.

**Option B3 — Hermes gateway HTTP mode:** Check if `hermes gateway run` exposes an HTTP
API. If it does, Paperclip can call it directly without a shim. Check the Hermes docs /
source before building B1.

### VPS agent setup

Run `hire.sh` on the VPS (after cloning the repo):

```bash
# On VPS — needs Hermes already installed (run launch.sh --skip-synapse --skip-element)
bash hire.sh deploybot \
  --title "Deployment Engineer" \
  --soul "You are Deploybot. You pull repos, build sites, restart services, and report outcomes. You run on the VPS and never talk to humans directly — only Donbot delegates to you via Matrix." \
  --no-gateway    # we'll use the HTTP shim instead of Matrix gateway

bash hire.sh cronbot \
  --title "Sysadmin & Cron Agent" \
  --soul "You are Cronbot. You run scheduled health checks: disk, memory, CPU, log anomalies, service status. You produce a concise report and flag anything that needs human attention." \
  --no-gateway
```

### Cron / scheduled health checks

Cronbot is invoked by a systemd timer (preferred over crontab — integrates with journald):

```ini
# /etc/systemd/system/cronbot-check.service
[Unit]
Description=Cronbot sysadmin health check

[Service]
Type=oneshot
User=<your-user>
ExecStart=/home/<user>/.local/bin/hermes -p cronbot chat -q \
  "Run a full sysadmin health check: disk usage, memory, top CPU processes, \
   failed systemd services, last 50 nginx/apache error log lines. \
   Summarise findings and flag anything critical." --yolo
StandardOutput=journal
StandardError=journal
```

```ini
# /etc/systemd/system/cronbot-check.timer
[Unit]
Description=Run cronbot health check every 6 hours

[Timer]
OnCalendar=*-*-* 00,06,12,18:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now cronbot-check.timer
```

Results land in journald. If you want alerting, add a second oneshot service that reads
cronbot's output and POSTs a Matrix DM to Donbot (who then forwards to your Element client).

### Deploy workflow (Mac → VPS)

1. You tell Donbot (via Matrix/Element on Mac): *"Deploy the latest version of mysite.com"*
2. Donbot creates a Paperclip task for `deploybot` via the API
3. Paperclip sends `POST /task` to the HTTP shim on VPS at `http://10.x.x.2:<port>/task`
4. Shim runs: `hermes -p deploybot chat -q "Deploy mysite.com: git pull, pnpm build, restart nginx" --yolo`
5. Deploybot executes the steps and returns a result
6. Shim returns result to Paperclip
7. Paperclip marks task complete; Donbot gets the result and reports back to you in Matrix

---

## Approach A — Matrix Federation (Future / Hybrid)

Matrix is a federated protocol. Each host can run its own Synapse homeserver. Agents on
different hosts appear in the same Matrix rooms, and Donbot on the Mac can delegate to a
`deploybot` on the VPS via a Matrix DM — without Paperclip as the intermediary.

**Why defer this:**
- Requires TLS + valid domain/hostname for each Synapse instance (even on WireGuard IPs,
  Matrix federation uses HTTPS)
- More moving parts to keep in sync
- The Paperclip approach gives you task tracking, budgets, and org chart for free

**When to add Matrix federation:**
- When you want agents on different machines to participate naturally in `#general:` rooms
- When you want Donbot replicas across machines (e.g. always-on Donbot on VPS even if Mac is offline)
- When the HTTP shim approach starts feeling like a bottleneck

---

## Approach C — Hybrid (Long-term target)

- Matrix federation for human-facing conversation (Donbot visible on every host)
- Paperclip HTTP adapter for structured task dispatch to remote agents
- MemPalace sync for shared memory

Implementation order: get Approach B working → add Matrix federation per host → wire up
MemPalace sync. Don't attempt all three at once.

---

## MemPalace Federation

MemPalace is local-first. Options for cross-host memory sharing:

| Option | Effort | Notes |
|---|---|---|
| **rsync over WireGuard** | Low | Sync palace dirs on a schedule; eventual consistency; start here |
| **MemPalace MCP server on VPS** | Medium | Expose MCP server at `10.x.x.2:<port>`; all agents query it |
| **Shared ChromaDB backend on VPS** | Medium | Point all MemPalace instances at a single ChromaDB |
| **Git-backed palace** | Medium | Commit palace to a private git repo; agents pull/push |

**Recommended start:** rsync from VPS to Mac every 15 minutes via a systemd timer over
the WireGuard interface.

```bash
# On Mac — pull VPS memories
rsync -az --delete 10.x.x.2:~/.mempalace/data/ ~/.mempalace/data/vps/
```

---

## Per-Host Role Assignments

| Host | WireGuard IP | Primary Role | Agents | Notes |
|---|---|---|---|---|
| **Mac** | 10.x.x.1 | Human interface + orchestrator | Donbot (CEO) | Runs Paperclip UI; Matrix gateway; user's primary machine |
| **VPS** | 10.x.x.2 | Always-on worker | deploybot, cronbot | 24/7 uptime; faces the public internet; runs websites |
| **Linux Desktop** | 10.x.x.3 | Heavy compute / dev | Local dev agents | Fast hardware; Ollama local models; build machines |
| **RPi** | 10.x.x.4 | Lightweight cron / sensors | cronbot-rpi | Low power; always on; home network monitoring |

---

## HTTP Shim — Reference Implementation

The implementer should write this. Here is the shape:

```python
# vps_agent_shim.py — FastAPI HTTP shim for remote Hermes agents
# Run with: uvicorn vps_agent_shim:app --host 10.x.x.2 --port 8420

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import subprocess, os

app = FastAPI()
HERMES_BIN = os.path.expanduser("~/.local/bin/hermes")

PROFILES = {"deploybot", "cronbot"}  # allowlist

class TaskRequest(BaseModel):
    profile: str
    query: str

class TaskResponse(BaseModel):
    result: str
    exit_code: int

@app.post("/task", response_model=TaskResponse)
def run_task(req: TaskRequest):
    if req.profile not in PROFILES:
        raise HTTPException(status_code=400, detail=f"Unknown profile: {req.profile}")
    proc = subprocess.run(
        [HERMES_BIN, "-p", req.profile, "chat", "-q", req.query, "--yolo"],
        capture_output=True, text=True, timeout=600
    )
    return TaskResponse(result=proc.stdout + proc.stderr, exit_code=proc.returncode)

@app.get("/health")
def health():
    return {"status": "ok"}
```

Run as a systemd user service on the VPS. Bind only to the WireGuard interface IP — do
**not** expose on `0.0.0.0` unless you add auth (bearer token or mTLS).

---

## Auth Between Hosts

Since WireGuard already encrypts traffic between known peers, the minimum viable auth is:
- **Bind shim to WireGuard IP only** (not 0.0.0.0) — only WireGuard peers can reach it
- **Shared bearer token** in an `Authorization: Bearer <token>` header — add to the shim
  and to the Paperclip `hermes_remote` adapter config

More robust later: mTLS with self-signed certs generated per host.

---

## Open Questions for the Implementer

1. **Does `hermes gateway run` expose an HTTP API on a port?** If yes, Approach B3 skips
   the need for the shim entirely. Check Hermes source / `hermes gateway --help`.
2. **Paperclip `hermes_remote` adapter:** Does it exist yet? If not, it needs to be written
   as a Paperclip plugin (see `~/.paperclip/adapters/`). The reference interface is in
   `launch.sh` where `hermes_local` is registered.
3. **Cronbot result forwarding:** How should cronbot alert Donbot when something is critical?
   Options: Matrix DM via `matrix-commander` CLI, POST to Paperclip `/tasks`, or write to
   a shared MemPalace room that Donbot polls.
4. **Deploybot working directory:** The agent needs write access to the web root and
   permission to restart nginx/caddy. Use a dedicated deploy user + sudoers rule, or
   run deploybot under the web server user.
5. **Idempotency of deploy tasks:** If Paperclip retries a failed task, deploybot must
   handle duplicate deploys gracefully (git pull is idempotent; `pnpm build` usually is).

---

## Suggested Implementation Order

1. ✅ WireGuard mesh operational (done)
2. Run `launch.sh` on VPS with `--skip-element` (no GUI needed on server)
3. Run `hire.sh deploybot` and `hire.sh cronbot` on VPS with `--no-gateway --no-paperclip`
4. Write + deploy the HTTP shim on VPS (FastAPI, bind to WireGuard IP)
5. Write the `hermes_remote` Paperclip adapter (or check if B3 applies)
6. Register deploybot + cronbot in central Paperclip on Mac
7. Set up `cronbot-check.timer` on VPS
8. Test end-to-end: tell Donbot to deploy, watch Paperclip route the task to VPS
9. Add rsync-based MemPalace sync
10. (Later) Matrix federation if desired

---

## Reference Links

- [Matrix Federation](https://spec.matrix.org/latest/server-server-api/)
- [MemPalace MCP tools](https://mempalaceofficial.com/reference/mcp-tools)
- [Paperclip adapters](https://github.com/paperclipai/paperclip)
- [Hermes Agent docs](https://docs.ollama.com/integrations/hermes)
- [Ollama REST API](https://github.com/ollama/ollama/blob/main/docs/api.md)
- [FastAPI](https://fastapi.tiangolo.com/)
- [WireGuard](https://www.wireguard.com/quickstart/)
