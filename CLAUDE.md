# Concierge — Project Instructions

> WhatsApp orchestration daemon built on Elixir/OTP.
> These instructions apply to Claude Code sessions **and** OpenClaw agents via the `AGENTS.md` symlink.

---

## Project Overview

Concierge is a production-grade WhatsApp orchestration daemon that bridges **wacli** (WhatsApp DB sync) and **OpenClaw** (AI agent sandbox) to deliver isolated, per-user AI sessions on WhatsApp.

- **Language:** Elixir 1.14+ / OTP
- **Version:** 2.0.0
- **License:** MIT
- **Repo:** `github.com/arvorco/concierge`

---

## Architecture

### Supervision Tree

Concierge runs a flat `one_for_one` supervisor (`Concierge.Supervisor`) with 9 children started in order:

| # | Child | Module | Pattern |
|---|-------|--------|---------|
| 1 | `ChatRegistry` | `Registry` (OTP) | Built-in unique registry |
| 2 | `ConfigServer` | `Concierge.ConfigServer` | GenServer — hot-reload config |
| 3 | `WacliDB` | `Concierge.WacliDB` | GenServer — read-only wacli.db access |
| 4 | `Store` | `Concierge.Store` | GenServer — single-writer SQLite (tracking.db) |
| 5 | `AgentManager` | `Concierge.AgentManager` | GenServer — workspace provisioning |
| 6 | `SyncController` | `Concierge.SyncController` | GenServer — serializes wacli send ops |
| 7 | `SandboxCleaner` | `Concierge.SandboxCleaner` | GenServer — Docker container cleanup |
| 8 | `ChatSupervisor` | `DynamicSupervisor` (OTP) | one_for_one, max 100 restarts |
| 9 | `Monitor` | `Concierge.Monitor` | GenServer — polls wacli DB every 5s |

### Data Flow

```
WhatsApp → wacli sync → wacli.db → Monitor (poll) → ChatHandler (per JID) → OpenClaw Agent → wacli send → WhatsApp
```

---

## Module Guide

| Module | Lines | Role | Pattern |
|--------|------:|------|---------|
| `Concierge` | 50 | Root module, version helper | Stateless |
| `Concierge.Application` | 55 | OTP application, supervision tree | Application |
| `Concierge.ConfigServer` | 205 | Hot-reload config.json, file watcher | GenServer |
| `Concierge.WacliDB` | 309 | Read-only access to wacli SQLite DB | GenServer |
| `Concierge.Store` | 667 | Tracking DB (SQLite), chat state persistence | GenServer |
| `Concierge.Monitor` | 446 | Poll wacli DB, dispatch to ChatHandlers, backlog | GenServer |
| `Concierge.ChatHandler` | 453 | Per-JID conversation handler, message coalescing | GenServer (transient) |
| `Concierge.ChatPool` | 58 | Registry wrapper, get-or-create ChatHandlers | Stateless |
| `Concierge.AgentManager` | 384 | Workspace provisioning, tool allowlists | GenServer |
| `Concierge.SyncController` | 145 | Serialize wacli sync stop/send/start | GenServer |
| `Concierge.SandboxCleaner` | 162 | Docker container pruning by age | GenServer |
| `Concierge.AIClient` | 330 | OpenClaw/Clawdbot CLI integration | Stateless |
| `Concierge.Sender` | 118 | Send via wacli or clawdbot | Stateless |
| `Concierge.Notifier` | 94 | Admin notifications via OpenClaw | Stateless |
| `Concierge.OpenClaw` | 120 | OpenClaw CLI detection + config read | Stateless |
| `Concierge.Reprocessor` | 89 | Re-queue missed messages for a JID | Stateless |
| `Concierge.Paths` | 50 | Resolve paths relative to CONCIERGE_HOME | Stateless |
| `Concierge.Jid` | 17 | JID normalization helpers | Stateless |
| `Concierge.CLI` | 56 | CLI command dispatch (reprocess, reset, etc.) | Stateless |

**Total:** ~3,800 lines across 19 modules.

---

## Code Conventions

### Elixir / OTP

- **GenServer single-writer pattern:** All mutable state lives inside a GenServer. External callers go through the client API (public functions that call `GenServer.call/cast`).
- **`@impl true`** on every callback (`init`, `handle_call`, `handle_cast`, `handle_info`).
- **`defstruct`** for GenServer state (see `ChatHandler`, `Store`).
- **Aliases** grouped at the top: `alias Concierge.{Foo, Bar}`.
- **Module docs:** Every module has `@moduledoc`. Public functions have `@doc`.
- **No bare `Process.sleep`** in production paths — use `Process.send_after` or timers.

### System.cmd / CLI Calls

- **Always wrap** `System.cmd` calls with `Task.async` + `Task.yield` + `Task.shutdown` to enforce timeouts.
- The `SyncController` serializes all wacli sends (stop sync → send → restart sync).

### Logging

- Use `Logger.info/warning/error` with structured metadata: `Logger.info("Processed", jid: jid)`.
- The `jid:` key is the standard metadata field for tracing.

### Config

- Runtime config lives in `config.json` (gitignored).
- `ConfigServer` watches and hot-reloads on change.
- Access config via `ConfigServer.get/2` — never read the JSON file directly.

---

## Development Workflow

### Format + Lint (mandatory before every commit)

```bash
mix format --check-formatted
mix credo --strict
```

### Static Analysis

```bash
mix dialyzer
```

### Run

```bash
# Foreground
mix run --no-halt

# Daemon
bin/concierged

# Interactive
iex -S mix
```

### Release Build

```bash
MIX_ENV=prod mix release
```

---

## Critical Rules

> These rules are non-negotiable. Violating them causes production incidents.

1. **0-lint policy.** `mix format` + `mix credo --strict` must both pass with zero warnings. Info-level Credo issues count as violations. No `# credo:disable` unless absolutely justified and commented.

2. **Never remove features without explicit approval.** If refactoring touches user-facing behavior, confirm before deleting.

3. **No breaking changes to config.json keys.** Existing keys must remain backward-compatible. Add new keys with sensible defaults.

4. **Single-writer discipline for SQLite.** Only `Concierge.Store` writes to `tracking.db`. Only `Concierge.WacliDB` reads from `wacli.db`. Never open a second connection.

5. **All System.cmd calls must have a timeout.** Use `Task.async` + `Task.yield(task, timeout)` + `Task.shutdown(task, :brutal_kill)`. Never call `System.cmd` directly on the caller's process without a timeout wrapper.

6. **Keep runtime data out of version control.** `tracking.db`, `config.json`, `agents/`, `logs/`, `CONCIERGE.md` are all gitignored.

7. **wacli send protocol:** Always stop sync before sending, then restart. This is handled by `SyncController` — never bypass it.

---

## Config System

### File Location

```
$CONCIERGE_CONFIG  →  (default: ./config.json)
```

### Home Directory

```
$CONCIERGE_HOME    →  (default: process working directory)
config.json → paths.home_dir  (alternative)
```

### Key Sections

| Section | Purpose |
|---------|---------|
| `enabled` | Global on/off switch |
| `hours` | Business hours + timezone |
| `filters` | DM-only, ignore JIDs, response length |
| `monitor` | Backlog catch-up settings |
| `safety` | Rate limits, forbidden words, escalation keywords |
| `human_takeover` | Auto-pause duration after manual reply |
| `sandbox_cleanup` | Docker cleanup cadence + max age |
| `whitelist` / `blocklist` | Number-based access control |
| `model` | AI model, temperature, max tokens |
| `sender` | Send provider (wacli or clawdbot) |
| `notifications` | Admin alerts config |
| `paths` | Home directory override |

---

## External Dependencies

| Dependency | Role |
|------------|------|
| **wacli** | WhatsApp DB sync + message sending CLI |
| **OpenClaw** (or `clawdbot` compat) | AI agent sandbox (Docker-based sessions) |
| **Docker** | Required for OpenClaw sandboxed sessions |
| **SQLite** | Backing store for tracking.db + wacli.db |
| **esqlite** (Hex) | Erlang NIF binding for SQLite |
| **jason** (Hex) | JSON encoding/decoding |
| **tzdata** (Hex) | Timezone data for business hours |
| **credo** (Hex, dev) | Static analysis / linting |
| **dialyxir** (Hex, dev) | Dialyzer integration |

---

## Common Pitfalls

### esqlite Returns Charlists

`esqlite` returns column values as charlists (`'hello'`), not Elixir strings (`"hello"`). Always convert with `to_string/1` or pattern-match accordingly.

### System.cmd Hangs

If `wacli send` or `openclaw` CLI hangs, the calling process blocks forever unless wrapped in a Task with timeout. This has caused production deadlocks. Always use the timeout pattern.

### wacli stop-send-restart Sequence

Sending a message requires: stop sync → send → restart sync. `SyncController` handles this. Never call `wacli send` outside of `SyncController`.

### ANSI / JSON5 Cleanup

OpenClaw CLI output may contain ANSI escape codes or non-standard JSON. Always strip ANSI and normalize before parsing.

### Config Hot-Reload

`ConfigServer` watches `config.json` via `file_system`. Changes are picked up automatically. Do not cache config values in module attributes at compile time — always call `ConfigServer.get/2` at runtime.
