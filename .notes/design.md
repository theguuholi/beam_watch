# BeamWatch — Incident Triage Dashboard Design

**Date:** 2026-06-12
**Branch:** implement

## Decisions

- **State:** Ephemeral in-memory (no database). Incidents are lost on restart.
- **File watching:** Timer-based polling (500ms). No external dep (`file_system` not added).
- **Architecture:** Option B — separate Watcher + Store with pure detector functions.

---

## Module Map

```
lib/beamwatch/
  ingestion/
    log_watcher.ex        # GenServer: polls priv/logs/, tracks byte offsets, PubSubs raw lines
    log_parser.ex         # Pure: parses a raw line → %ParsedLine{} or {:malformed, raw}
  incidents/
    incident_store.ex     # GenServer: subscribes to raw lines, owns all state, PubSubs updates
    incident.ex           # Struct: %Incident{}
    detectors/
      container_restart_loop.ex
      disk_smart_warning.ex
      share_permission_failure.ex
      vm_boot_failure.ex
  source_health/
    source_health.ex      # Struct: %SourceHealth{}

lib/beamwatch_web/live/
  dashboard_live.ex       # Subscribes to PubSub, renders incidents + source health + activity
```

---

## Data Flow

```
priv/logs/*.log
    ↓  (500ms poll, byte offset tracking)
LogWatcher  →  PubSub "log:lines"  →  IncidentStore
                                           ↓  (detection + state mutation)
                                       PubSub "dashboard:update"
                                           ↓
                                       DashboardLive
```

`IncidentStore` is the single source of truth. Operator actions are `GenServer.call/2` routed from LiveView `phx-click` events.

---

## Data Structures

### Incident

```elixir
%Incident{
  id: binary(),           # deterministic key: "type:resource"
  type: atom(),           # :container_restart_loop | :disk_smart_warning | ...
  resource: binary(),     # "plex", "disk3", "media", "windows11"
  severity: :critical | :warning | :info,
  status: :active | :acknowledged | :silenced | :resolved,
  first_seen: DateTime.t(),
  last_seen: DateTime.t(),
  evidence: [%{source: binary(), line: binary(), at: DateTime.t()}],
  silence_scope: nil | :incident | :type
}
```

### SourceHealth

```elixir
%SourceHealth{
  file: binary(),
  exists?: boolean(),
  size_bytes: integer(),
  last_read_at: DateTime.t(),
  last_log_at: DateTime.t() | nil,
  byte_offset: integer(),
  parse_failures: integer(),
  rotated?: boolean()
}
```

---

## Incident Types

### Container Restart Loop (`docker.log`, `app.log`, `nginx.log`)
- Open/update when ≥4 `die` events for the same container within 60 seconds.
- Supporting evidence: healthcheck failures, nginx upstream unavailable, start events.
- No auto-resolve — operator must resolve manually.

### Disk SMART Warning (`syslog.log`)
- Open/update on `emhttpd: <disk> SMART warning:` — grouped by disk + calendar date.
- Auto-resolve on `emhttpd: <disk> SMART check passed`.

### Share Permission Failure (`smb.log`, `nfs.log`)
- Open/update on `Permission denied` with `share=<name>`, grouped by share name.
- Window: failures for the same share within 10 minutes update the same incident.
- No auto-resolve — operator action required.

### VM Boot Failure (`libvirt.log`, `qemu.log`, `syslog.log`)
- Open on `vm=<name> ... status=failed`.
- Supporting evidence: qemu permission/image errors, kernel bridge missing.
- Auto-resolve on `vm=<name> ... status=running`.

---

## Operator Actions

| Action | Effect |
|---|---|
| Acknowledge | `status: :acknowledged` |
| Silence (incident) | `status: :silenced, silence_scope: :incident` |
| Silence (type) | All active + future incidents of that type are silenced |
| Resolve | `status: :resolved` — moved to recent activity |
| Clear silence | Resets silence, restores previous status |

---

## Source Health

`LogWatcher` tracks per file on each poll tick:
- File exists, current size, last read timestamp
- Latest log timestamp parsed from lines
- Cumulative parse failure count
- Rotation detected when current size < previous byte offset

---

## Dashboard Sections

1. **Active incidents** — cards sorted by severity then `last_seen` desc, evidence expandable inline.
2. **Source health** — one row per watched file with status indicator.
3. **Recent activity** — ring buffer of last 50 log lines across all sources.

---

## Testing Strategy

**Unit** (pure, fast, async: true):
- `LogParser` — valid lines, malformed, truncated timestamps
- Each detector — feed parsed line sequences, assert `{action, attrs}` output
- Threshold cases: exactly 4 dies in 60s opens, 3 does not; SMART pass resolves; VM running resolves

**Integration** (process boundary, async: false):
- `IncidentStore` — start process, publish raw lines via PubSub, assert incident state
- Operator actions — acknowledge, silence, resolve, clear_silence
- `LogWatcher` — write lines to tmp dir, assert PubSub messages and rotation detection

**LiveView**:
- Empty state renders correctly
- Incidents from seeded store render with correct status badges
- Action buttons trigger correct events and update the view
