# Matrix Client Setup

Connect Element (or any Matrix client) to your local homeserver and start talking to your agents.

**Homeserver:** `http://localhost:8008`  
**Your account:** `@admin:localhost` / `changeme`

---

## On the Debian VM

### Option A — Element Desktop (Flatpak)
```bash
flatpak install flathub im.riot.Riot
flatpak run im.riot.Riot
```
When prompted for a homeserver, enter: `http://localhost:8008`

### Option B — Browser (no install)
Open: [https://app.element.io](https://app.element.io)

1. Click **Sign in**
2. Click **Edit** next to the homeserver URL
3. Enter `http://localhost:8008`
4. Log in as `@admin:localhost` / `changeme`

---

## On a Remote Machine

1. Download **Element** from [https://element.io/download](https://element.io/download)
2. Open Element → click **Sign in**
3. Click **Edit** next to the homeserver URL
4. Enter `http://<your-vm-ip>:8008`
5. Log in as `@admin:localhost` / `changeme`

---

## Accounts

| User | Matrix ID | Password |
|------|-----------|----------|
| You (operator) | `@admin:localhost` | `changeme` |
| ArcBot (default) | `@arcbot:localhost` | *(see matrix_credentials.env)* |
| Any provisioned bot | `@<botname>:localhost` | *(see matrix_credentials.env)* |

---

## Coordination Rooms

| Room | Alias | Purpose |
|------|-------|---------|
| General | `#general:localhost` | Main agent coordination |
| Tasks | `#tasks:localhost` | Task assignment and tracking |
| Results | `#results:localhost` | Agent output and results |
| Status | `#status:localhost` | Agent health / heartbeat |
| Memory | `#memory:localhost` | Shared knowledge and context |

To join a room in Element: click **+** next to Rooms → **Join public room** → enter the alias.

---

## Talking to Bots

- **DM any bot** — start a direct message with e.g. `@arcbot:localhost`. It will respond to every message, no @mention needed.
- **In a room** — bots respond to all messages in rooms they have joined.
- **Start a bot gateway** (each bot runs independently):

```bash
# Start a specific bot's gateway
writerbot gateway start
engineerbot gateway start
# etc.

# Or install as a persistent systemd service
writerbot gateway install
engineerbot gateway install
```

The default profile (ArcBot) gateway is already running as a system service.

---

## Hermes Bot Profiles

| Profile | Matrix ID | Model | Command |
|---------|-----------|-------|---------|
| default (ArcBot) | `@arcbot:localhost` | *(configured via `hermes model`)* | `hermes` |
| writerbot | `@writerbot:localhost` | gpt-4.1 | `writerbot` |
| engineerbot | `@engineerbot:localhost` | gpt-4.1 | `engineerbot` |

Profiles are created with `bash hire.sh <botname> --title "..." --model "..."`. Each provisioned bot's command is simply its name.
