# Concierge

<p align="center">
  <img src="Concierge_small.png" alt="Concierge logo" width="220" />
</p>


**Concierge** is a production-grade WhatsApp orchestration daemon for **OpenClaw** agent workflows.  
It sits on top of **wacli** (WhatsApp DB sync by *steipete*: https://github.com/steipete/wacli) and **OpenClaw** (formerly Clawdbot/Moltbot) to create **isolated, per-user sessions** with strong sandboxing, smart queueing, and reliable delivery.

## Why Concierge

If you want to:
- deliver AI support or sales on WhatsApp,
- run advanced agents per user or per group,
- enforce isolation between sessions,
- and keep the system resilient under load,

Concierge is the missing layer.

## What it does

- **Per-JID isolated workspaces** (IDENTITY, SOUL, TOOLS, config)  
- **Sandboxed sessions** via OpenClaw (Docker-backed sandboxes)  
- **Per-workspace tool allowlists** (default: no tools; can be set per JID)  
- **Human takeover detection** (auto-pause after a manual reply)  
- **Message coalescing** (3 quick texts = 1 response)  
- **Backlog catch-up** (responds to missed messages safely)  
- **Single-writer wacli sync controller** (prevents DB lock issues)  
- **Auto cleanup of sandboxes** (hourly, configurable)  
- **CLI commands** for reprocess, reset, pause, resume

## Architecture (high-level)

```
WhatsApp
   ↓
wacli sync  →  ~/.wacli/wacli.db
   ↓
Concierge Monitor (poll + backlog)
   ↓
ChatHandler (one per JID)
   ↓
OpenClaw Agent (sandboxed session)
   ↓
wacli send  →  WhatsApp
```

Notifications to the operator are sent via OpenClaw.


## OpenClaw sandbox configuration

Concierge assumes OpenClaw runs sessions in a restricted sandbox. Configure your OpenClaw agent sandbox like this:

```json
{
  "sandbox": {
    "mode": "non-main",
    "workspaceAccess": "none",
    "scope": "session"
  }
}
```

Concierge also reads `messages.responsePrefix` from the OpenClaw/Clawdbot config (via `openclaw config get messages.responsePrefix` or `clawdbot config get messages.responsePrefix`). If you don't want a prefix, set it to an empty string in OpenClaw.

For background on sandboxing and why session isolation matters, see the OpenClaw docs:
https://docs.openclaw.ai/


## Security model

Each WhatsApp JID gets:
- its **own workspace** (`agents/<jid>/`) with a dedicated prompt, identity, and config
- **sandboxed execution** in OpenClaw (Docker containers per session)
- **tool restrictions** enforced at the agent level

Concierge also **auto-prunes stale sandboxes** (default: every hour) to keep the host clean.

## Prerequisites

- macOS or Linux
- **wacli** by steipete  
  https://github.com/steipete/wacli
- **OpenClaw** (gateway + CLI, formerly Clawdbot/Moltbot)  
  https://openclaw.ai/  
  Concierge auto-detects `openclaw` or `clawdbot` (compat alias).
- Elixir 1.14+
- SQLite
- Docker (required for OpenClaw sandboxes)

## Install (Homebrew)

```
brew tap arvorco/tap
brew install concierge --HEAD
```

## Install (manual)

```
git clone https://github.com/arvorco/concierge
cd concierge
mix deps.get
```

Create config:

```
cp config.example.json config.json
```


Create prompt template (optional):

```
cp CONCIERGE_TEMPLATE.md CONCIERGE.md
```

Edit `CONCIERGE.md` with your organization’s messaging and business details.

Workspaces will symlink their `SOUL.md` to `CONCIERGE.md`.

Note: `CONCIERGE.md` is gitignored by default so you can keep private business content local.

Edit `config.json` for:
- `paths.home_dir` (optional): runtime home directory (equivalent to `CONCIERGE_HOME`)
- notification number
- safety keywords
- filters
- model settings

Config tips:
- `filters.ignore_jids`: list of numbers/JIDs to ignore (admin or test users)
- `notifications.notify_admin_number`: admin phone for alerts

Set a home directory (optional):

By default, Concierge uses the process working directory as its home.

```
export CONCIERGE_HOME="/path/to/your/concierge-home"
```

You can also set `paths.home_dir` inside `config.json`.

Config file location:

By default, Concierge reads `config.json` from the current working directory. If you want to keep config elsewhere (common on servers), set:

```
export CONCIERGE_CONFIG="/path/to/config.json"
```

## Run

```
bin/concierged
```

Or run in dev:

```
mix run --no-halt
```

## LaunchAgent (macOS)

Install via the CLI (recommended):

```
bin/concierge install-launchd
```

This renders the `launchd/co.arvor.concierged.plist` template with your local path and loads it.

To uninstall:

```
bin/concierge uninstall-launchd
```


## Linux / Cloud (systemd)


### wacli install (macOS/Linux)

```
brew install steipete/tap/wacli
```

Or build from source (Go required). The wacli docs recommend building with the `sqlite_fts5` tag for fast search.

Concierge runs well on common cloud images like Amazon Linux 2023, Oracle Linux, or Ubuntu LTS.  
Use the systemd template and adjust paths/users for your host:

```
sudo cp systemd/concierged.service /etc/systemd/system/concierged.service
sudo systemctl daemon-reload
sudo systemctl enable --now concierged
```

Before enabling the service:
- Install Docker, wacli, OpenClaw, Elixir, and SQLite
- Update `User`, `Group`, `WorkingDirectory`, `ExecStart`, and `CONCIERGE_HOME`
- Build a release if you want a fully self-contained binary: `MIX_ENV=prod mix release`

## CLI

```
bin/concierge reprocess <jid>
bin/concierge reprocess-all
bin/concierge reset <jid>
bin/concierge reset-all
```

## Configuration highlights

- `human_takeover.auto_pause_hours`  
  auto-pause after a manual reply

- `monitor.backlog_*`  
  catch-up rules and window

- `sandbox_cleanup.*`  
  Docker cleanup cadence and max age

## Notes on wacli integration

Concierge improves reliability around wacli by:
- serializing writes (single-writer sync controller)
- deduping by `msg_id`
- safe backlog reconciliation

Long-term, we’d like to integrate deeper with wacli for:
- native event streaming (no polling)
- direct send API (no sync stop/start)
- better message metadata (sender identity + group hints)

---

**Concierge** is the orchestration layer that makes WhatsApp agent experiences reliable, secure, and scalable.

## License

MIT (see `LICENSE`).
