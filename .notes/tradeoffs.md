# Tradeoffs and Technical Notes

## Architecture: Why GenServers Instead of Postgres

The short answer is that this problem does not need a database — and adding one would cost complexity without proportional benefit for a single-operator home-server monitoring tool within the scope of this exercise.

### What the state actually is

Incidents are **derived data**. They are computed views of log lines, not source-of-truth records. If the app restarts and the log files still exist, replaying them would reconstruct the same incidents. This is fundamentally different from, say, user accounts or financial transactions, where the database record is the truth.

### Specific reasons GenServer fits here

| Concern | GenServer answer |
|---|---|
| **Operational simplicity** | Zero infrastructure. No database to provision, migrate, or keep running alongside the Phoenix app. A monitoring tool that itself needs a database to start is a liability. |
| **Latency** | State lives in the BEAM process heap. Reads are sub-microsecond — no network hop, no query plan, no connection pool. The dashboard updates on every 500 ms poll tick; that budget is spent on I/O, not state access. |
| **PubSub integration** | `IncidentStore` broadcasts via `Phoenix.PubSub` immediately after every mutation. LiveViews get pushed updates with no polling. Wiring a Postgres-backed store into the same push model would require CDC or periodic polling, adding latency and complexity. |
| **Concurrent access model** | A single `GenServer` serialises all writes (ingestion, operator actions) without locks. Elixir's message-passing model gives us safe concurrent access for free. |
| **State shape** | The incident map, silenced-type set, and detector states fit naturally as Elixir data structures. There is no relational structure to benefit from SQL. |

### What a Postgres version would gain

- Durability across restarts (incidents survive a crash or deploy)
- Multi-node support (multiple app instances sharing state)
- Historical querying (e.g. "show me all incidents from last week")
- Audit trail that survives process death

None of those were required by the spec. A production evolution of this tool would likely introduce **Postgres for historical records** while keeping the **GenServer as a read-optimised in-memory cache** for the live dashboard — essentially the same pattern Phoenix uses with `Presence`.

---

## Testing Plan

### Philosophy

Tests are split by whether they cross a process boundary. Pure functions run `async: true` with no shared state. Anything touching a live process (`IncidentStore`, `LogWatcher`) runs `async: false` and uses the process-injection pattern so each test gets its own isolated GenServer.

### Layer 1 — Pure unit tests (`async: true`)

**`LogParser`** (`test/beamwatch/ingestion/log_parser_test.exs`)
- Valid lines parse to `%ParsedLine{}` with correct fields
- Lines with malformed timestamps produce `{:malformed, raw}`
- Truncated / empty lines handled without crash

**Detectors** (`test/beamwatch/incidents/detectors/`)
- Each detector receives a sequence of `%ParsedLine{}` values and returns `{:open, attrs}`, `{:update, id, attrs}`, `{:resolve, id}`, or `:ignore`
- Threshold boundary cases: exactly 4 die events in 60 s opens the incident; 3 does not
- SMART check-passed line resolves the disk incident
- VM `status=running` line resolves the boot-failure incident
- Events outside the time window do not contribute to the same incident

### Layer 2 — Integration tests (`async: false`)

**`IncidentStore`** (`test/beamwatch/incidents/incident_store_test.exs`)
- Ingest parsed lines via `IncidentStore.ingest_line/1` and assert resulting incident state
- Operator actions: acknowledge, silence (incident scope), silence (type scope), resolve, clear silence
- Type silence: future ingested incidents of the silenced type are auto-silenced
- `update_source_health/1` populates `store_state.source_health`
- `reset/0` clears all state

**`LogWatcher`** (`test/beamwatch/ingestion/log_watcher_test.exs`)
- Write lines to a tmp directory; assert PubSub messages received from the watcher
- Byte-offset tracking: only new bytes are processed on subsequent polls
- Rotation detection: current file size < previous offset triggers `rotated?: true` in source health
- Missing file: `exists?: false` reported in source health

### Layer 3 — LiveView integration tests (`async: false`)

**`DashboardLive.Index`** (`test/beamwatch_web/live/dashboard_live/index_test.exs`)

*Mount behaviour*
- Empty `store_state` and `expanded_ids` on first load
- `dev_log_controls_enabled?` reflects application config

*`handle_info/2` — `:dashboard_updated`*
- Pushed `StoreState` replaces assigns
- Incidents and source health propagate to the view

*`handle_event/3` — operator actions*
- `toggle-evidence`: adds/removes id from `expanded_ids`; toggling one id does not affect others
- `acknowledge`, `silence-incident`, `silence-type`, `resolve`, `clear-silence`, `clear-type-silence`: each verified against `IncidentStore.get_state()` after the click

*Rendering — source health panel*
- `ok` / `missing` / `rotated` / `warnings` badge labels render for corresponding `SourceHealth` states
- `format_bytes` renders MB / KB / B correctly

*Rendering — evidence section*
- Toggle button appears only when `incident.evidence` is non-empty
- Button text cycles between "Show N evidence line(s)" and "Hide evidence"
- Evidence entries (timestamp, source, line) render when expanded

*Dev controls*
- `dev-add-validation-logs` writes expected fixture content to the target directory
- `dev-clear-log-dir` empties the directory and resets the incident store

**`Components`** (tested inline in `index_test.exs`)
- `format_type/1`: known atoms return exact strings; unknown atoms fall back to capitalised underscore-split
- `format_dt/1`: nil returns em dash; DateTime formats as `MM-DD HH:MM:SS`
- `severity_border/1`, `severity_dot/1`: known severities return expected classes; fallback case returns zinc
- `status_badge_class/1`: all four statuses return correct colour classes

### Running tests

```bash
mix test                        # full suite
mix test --failed               # only previously failing tests
mix test test/beamwatch_web/    # LiveView layer only
mix test --cover                # with coverage report
```

---

## Known Gaps and Incomplete Work

### What is solid

- All four incident types detect, open, update, and (where applicable) auto-resolve
- Operator lifecycle: acknowledge → silence (incident or type) → clear silence → resolve
- Source health tracks existence, size, offsets, parse failures, and rotation
- Evidence expandable inline per incident
- Dev controls for fast iteration without the feeder CLI
- Test coverage across all three layers for the implemented behaviour

### What is incomplete or would change next

**No persistence.** Incidents are lost when the BEAM process stops. The first production step would be writing resolved and active incidents to Postgres (or ETS + DETS for a DB-free option) so the dashboard survives a deploy or crash.

**No distributed support.** `IncidentStore` is a named local `GenServer`. A multi-node deployment would diverge state. Fixing this requires either a distributed registry (Horde) or moving state to Postgres and making the GenServer a cache.

**Evidence is unbounded per incident.** Each new matching log line prepends to `incident.evidence`. A long-running incident with noisy logs would grow the list indefinitely. A cap (e.g. last 100 entries) should be enforced.

**No silence expiration.** The spec does not require it, but a production tool would want time-based or rule-based silence expiry.

**No authentication.** Any browser that can reach port 4000 can resolve or silence incidents. For a home-server tool running on a LAN this is probably acceptable, but it should be noted.

**Detector states are not durable.** The die-event counts and time windows tracked inside `StoreState.detector_states` are lost on crash. After a restart, a container that had already accumulated 3 die events would need 4 more before an incident opens.

**Test coverage of `LogWatcher` and `IncidentStore` integration tests is described but not yet fully implemented.** The test files listed in Layer 2 cover the shape of what is needed; the implementation was deprioritised to focus on the LiveView and pure-function layers within the time box.
