<p align="center">
  <a href="https://arvorco.github.io/concierge">
    <img src="Concierge_small.png" alt="Concierge logo" width="220" />
  </a>
</p>

<h1 align="center">Concierge</h1>

<p align="center">
  Production-grade WhatsApp orchestration daemon for <a href="https://openclaw.ai">OpenClaw</a> agent workflows.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" /></a>
  <img src="https://img.shields.io/badge/elixir-1.14%2B-purple.svg" alt="Elixir 1.14+" />
  <img src="https://img.shields.io/badge/version-2.0.0-green.svg" alt="v2.0.0" />
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey.svg" alt="macOS | Linux" />
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> &middot;
  <a href="#features">Features</a> &middot;
  <a href="#architecture">Architecture</a> &middot;
  <a href="#configuration">Configuration</a> &middot;
  <a href="https://arvorco.github.io/concierge">Docs</a> &middot;
  <a href="https://github.com/arvorco/concierge/issues">Issues</a>
</p>

---

## Table of Contents

- [Why Concierge](#why-concierge)
- [Quick Start](#quick-start)
- [Features](#features)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Running](#running)
- [CLI Reference](#cli-reference)
- [Deployment](#deployment)
- [OpenClaw Sandbox Config](#openclaw-sandbox-config)
- [Security Model](#security-model)
- [wacli Integration](#wacli-integration)
- [Contributing](#contributing)
- [License](#license)

---

## Why Concierge

If you want to:

- Deliver AI support or sales on WhatsApp
- Run advanced agents per user or per group
- Enforce isolation between sessions
- Keep the system resilient under load

Concierge is the missing layer. It sits on top of [wacli](https://github.com/steipete/wacli) (WhatsApp DB sync by *steipete*) and [OpenClaw](https://openclaw.ai) (formerly Clawdbot/Moltbot) to create **isolated, per-user sessions** with strong sandboxing, smart queueing, and reliable delivery.

---

## Quick Start

1. **Install** via Homebrew:
   ```
   brew tap arvorco/tap
   brew install concierge --HEAD
   ```
2. **Copy config:**
   ```
   cp config.example.json config.json
   ```
3. **Edit** `config.json` with your admin number and preferences.
4. **Create prompt** (optional):
   ```
   cp CONCIERGE_TEMPLATE.md CONCIERGE.md
   ```
5. **Run:**
   ```
   bin/concierged
   ```

---

## Features

| Feature | Description |
|---------|-------------|
| **Per-JID isolated workspaces** | Each WhatsApp contact gets its own IDENTITY, SOUL, TOOLS, and config |
| **Sandboxed sessions** | OpenClaw Docker-backed sandboxes per session |
| **Per-workspace tool allowlists** | Default: no tools; configurable per JID |
| **Human takeover detection** | Auto-pause after a manual reply (configurable hours) |
| **Message coalescing** | Multiple quick texts merged into a single response |
| **Backlog catch-up** | Responds to missed messages on startup or schedule |
| **Single-writer sync controller** | Prevents wacli DB lock issues |
| **Auto sandbox cleanup** | Hourly Docker container pruning (configurable) |
| **CLI commands** | Reprocess, reset, pause, resume per JID or all |
| **Hot-reload config** | Change `config.json` without restarting |
| **Business hours** | Optional schedule with timezone support |
| **Rate limiting** | Per-chat-per-hour rate caps |
| **Safety keywords** | Forbidden words, escalation triggers, approval gates |
| **Admin notifications** | Alerts via OpenClaw for errors, takeovers, new messages |

---

## Architecture

### High-Level Flow

```
WhatsApp
   |
wacli sync  -->  ~/.wacli/wacli.db
   |
Concierge Monitor (poll every 5s + backlog)
   |
ChatHandler (one per JID, isolated process)
   |
OpenClaw Agent (sandboxed Docker session)
   |
wacli send  -->  WhatsApp
```

Notifications to the operator are sent via OpenClaw.

### Supervision Tree

Concierge runs a flat `one_for_one` supervisor with 9 children:

```
Concierge.Supervisor
 ├── ChatRegistry          (Registry — name→pid mapping)
 ├── ConfigServer          (GenServer — hot-reload config.json)
 ├── WacliDB               (GenServer — read-only wacli.db)
 ├── Store                 (GenServer — tracking.db, single-writer SQLite)
 ├── AgentManager          (GenServer — workspace provisioning)
 ├── SyncController        (GenServer — serializes wacli send ops)
 ├── SandboxCleaner        (GenServer — Docker cleanup)
 ├── ChatSupervisor        (DynamicSupervisor — one ChatHandler per JID)
 └── Monitor               (GenServer — polls wacli DB, dispatches messages)
```

---

## Prerequisites

- **macOS** or **Linux**
- [**Elixir**](https://elixir-lang.org/install.html) 1.14+
- [**SQLite**](https://sqlite.org/download.html)
- [**Docker**](https://docs.docker.com/get-docker/) (required for OpenClaw sandboxes)
- [**wacli**](https://github.com/steipete/wacli) by steipete
- [**OpenClaw**](https://openclaw.ai/) (gateway + CLI, formerly Clawdbot/Moltbot) — Concierge auto-detects `openclaw` or `clawdbot` (compat alias)

---

## Installation

### Homebrew (recommended)

```
brew tap arvorco/tap
brew install concierge --HEAD
```

### Manual

```bash
git clone https://github.com/arvorco/concierge
cd concierge
mix deps.get
```

Then copy the config and optionally the prompt template:

```bash
cp config.example.json config.json
cp CONCIERGE_TEMPLATE.md CONCIERGE.md   # optional
```

Edit `CONCIERGE.md` with your organization's messaging and business details. Workspaces will symlink their `SOUL.md` to `CONCIERGE.md`.

> **Note:** `CONCIERGE.md` is gitignored by default so you can keep private business content local.

---

## Configuration

### Config File Location

By default, Concierge reads `config.json` from the current working directory.

```bash
# Override config path
export CONCIERGE_CONFIG="/path/to/config.json"
```

### Home Directory

By default, Concierge uses the process working directory as its home.

```bash
# Override home directory
export CONCIERGE_HOME="/path/to/your/concierge-home"
```

You can also set `paths.home_dir` inside `config.json`.

### Key Settings

| Key | Purpose |
|-----|---------|
| `enabled` | Global on/off switch |
| `hours.*` | Business hours, timezone, weekdays-only |
| `filters.only_dms` | Only respond to direct messages |
| `filters.ignore_jids` | List of JIDs to ignore (admin, test users) |
| `filters.max_response_length` | Max characters per response |
| `monitor.backlog_*` | Catch-up rules and window |
| `safety.rate_limit_per_chat_per_hour` | Rate cap per conversation |
| `safety.forbidden_words` | Block messages containing these |
| `safety.escalate_to_human_keywords` | Trigger human escalation |
| `human_takeover.auto_pause_hours` | Pause duration after manual reply |
| `sandbox_cleanup.*` | Docker cleanup cadence and max age |
| `model.primary` | AI model identifier |
| `notifications.notify_admin_number` | Admin phone for alerts |

<details>
<summary><strong>Full config.json reference</strong></summary>

```json
{
  "enabled": true,
  "name": "Concierge",
  "version": "1.0.0",
  "hours": {
    "enabled": false,
    "start": 8,
    "end": 20,
    "timezone": "America/Sao_Paulo",
    "weekdays_only": false
  },
  "filters": {
    "only_dms": true,
    "ignore_groups": true,
    "ignore_broadcast": true,
    "ignore_jids": [],
    "max_response_length": 500,
    "min_wait_seconds": 3,
    "max_wait_seconds": 3
  },
  "monitor": {
    "backlog_enabled": true,
    "backlog_interval_seconds": 60,
    "backlog_window_seconds": 0,
    "backlog_retry_seconds": 300,
    "backlog_catch_all_on_start": true,
    "backlog_ignore_hours": true
  },
  "safety": {
    "rate_limit_per_chat_per_hour": 10,
    "processing_timeout_seconds": 180,
    "forbidden_words": ["delete", "exec", "rm -rf", "sudo", "eval", "system"],
    "require_human_approval_keywords": [],
    "escalate_to_human_keywords": []
  },
  "human_takeover": {
    "auto_pause_hours": 3,
    "cooldown_after_human_message": true
  },
  "sandbox_cleanup": {
    "enabled": true,
    "interval_seconds": 3600,
    "max_age_seconds": 3600,
    "name_prefix": "clawdbot-sbx-",
    "remove_running": true,
    "dry_run": false
  },
  "whitelist": {
    "mode": "all",
    "numbers": []
  },
  "blocklist": {
    "enabled": true,
    "numbers": []
  },
  "model": {
    "primary": "anthropic/claude-sonnet-4-5",
    "max_tokens": 800,
    "temperature": 0.9,
    "thinking": "off"
  },
  "sender": {
    "provider": "wacli",
    "clawdbot_target": "jid",
    "clawdbot_timeout_ms": 20000
  },
  "notifications": {
    "notify_admin_number": "+15550000000",
    "notify_on_new_message": true,
    "notify_on_bot_response": true,
    "notify_on_human_takeover": true,
    "notify_on_escalation": true,
    "notify_on_error": true,
    "provider": "clawdbot"
  },
  "logging": {
    "enabled": true,
    "log_dir": "logs",
    "retention_days": 30,
    "log_full_json_on_error": true
  },
  "paths": {
    "home_dir": null
  }
}
```

</details>

---

## Running

### Daemon

```
bin/concierged
```

### Dev Mode

```
mix run --no-halt
```

### Interactive

```
iex -S mix
```

---

## CLI Reference

| Command | Description |
|---------|-------------|
| `bin/concierge reprocess <jid>` | Re-queue and process missed messages for a JID |
| `bin/concierge reprocess-all` | Re-queue all pending messages |
| `bin/concierge reset <jid>` | Reset chat state for a JID |
| `bin/concierge reset-all` | Reset all chat states |
| `bin/concierge install-launchd` | Install macOS LaunchAgent |
| `bin/concierge uninstall-launchd` | Uninstall macOS LaunchAgent |

---

## Deployment

### macOS (launchd)

Install via the CLI (recommended):

```
bin/concierge install-launchd
```

This renders the `launchd/co.arvor.concierged.plist` template with your local path and loads it.

To uninstall:

```
bin/concierge uninstall-launchd
```

### Linux / Cloud (systemd)

Concierge runs well on common cloud images like Amazon Linux 2023, Oracle Linux, or Ubuntu LTS.

**wacli install:**

```
brew install steipete/tap/wacli
```

Or build from source (Go required). The wacli docs recommend building with the `sqlite_fts5` tag for fast search.

**systemd setup:**

```bash
sudo cp systemd/concierged.service /etc/systemd/system/concierged.service
sudo systemctl daemon-reload
sudo systemctl enable --now concierged
```

Before enabling the service:

- Install Docker, wacli, OpenClaw, Elixir, and SQLite
- Update `User`, `Group`, `WorkingDirectory`, `ExecStart`, and `CONCIERGE_HOME` in the service file
- Optionally build a release: `MIX_ENV=prod mix release`

---

## OpenClaw Sandbox Config

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

For background on sandboxing and why session isolation matters, see the [OpenClaw docs](https://docs.openclaw.ai/).

---

## Security Model

Each WhatsApp JID gets:

- Its **own workspace** (`agents/<jid>/`) with a dedicated prompt, identity, and config
- **Sandboxed execution** in OpenClaw (Docker containers per session)
- **Tool restrictions** enforced at the agent level (default: no tools)

Concierge also **auto-prunes stale sandboxes** (default: every hour) to keep the host clean.

---

## wacli Integration

Concierge improves reliability around wacli by:

- Serializing writes (single-writer sync controller)
- Deduping by `msg_id`
- Safe backlog reconciliation

Long-term, we'd like to integrate deeper with wacli for:

- Native event streaming (no polling)
- Direct send API (no sync stop/start)
- Better message metadata (sender identity + group hints)

---

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Ensure code passes lint:
   ```bash
   mix format
   mix credo --strict
   ```
4. Commit and push
5. Open a Pull Request

Please follow the project's 0-lint policy — `mix format` + `mix credo --strict` must pass with zero warnings.

---

## License

MIT — see [`LICENSE`](LICENSE).

---

<p align="center">
  <a href="https://arvorco.github.io/concierge">Docs</a> &middot;
  <a href="https://github.com/arvorco/concierge">GitHub</a> &middot;
  <a href="https://github.com/arvorco/concierge/issues">Issues</a>
</p>

<p align="center">
  <strong>Concierge</strong> is the orchestration layer that makes WhatsApp agent experiences reliable, secure, and scalable.
</p>
