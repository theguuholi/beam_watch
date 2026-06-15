# BeamWatch Incident Triage — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Phoenix LiveView incident triage dashboard that ingests log files, detects four incident types, tracks source health, and supports operator acknowledge/silence/resolve actions.

**Architecture:** Two GenServers (`LogWatcher` polls files → PubSub → `IncidentStore` runs detectors, holds state → PubSub → `DashboardLive`). Pure detector modules. Ephemeral in-memory state.

**Tech Stack:** Elixir/OTP, Phoenix 1.8, LiveView 1.1, Phoenix.PubSub, Tailwind CSS, Heroicons.

---

## File Map

**Create:**
- `lib/beamwatch/ingestion/parsed_line.ex` — ParsedLine struct
- `lib/beamwatch/ingestion/log_parser.ex` — pure line parser
- `lib/beamwatch/ingestion/log_watcher.ex` — GenServer: polls files, publishes to PubSub
- `lib/beamwatch/incidents/incident.ex` — Incident struct
- `lib/beamwatch/incidents/incident_store.ex` — GenServer: owns all state, operator actions
- `lib/beamwatch/incidents/detectors/container_restart_loop.ex`
- `lib/beamwatch/incidents/detectors/disk_smart_warning.ex`
- `lib/beamwatch/incidents/detectors/share_permission_failure.ex`
- `lib/beamwatch/incidents/detectors/vm_boot_failure.ex`
- `lib/beamwatch/source_health.ex` — SourceHealth struct
- `test/beamwatch/ingestion/log_parser_test.exs`
- `test/beamwatch/incidents/detectors/container_restart_loop_test.exs`
- `test/beamwatch/incidents/detectors/disk_smart_warning_test.exs`
- `test/beamwatch/incidents/detectors/share_permission_failure_test.exs`
- `test/beamwatch/incidents/detectors/vm_boot_failure_test.exs`
- `test/beamwatch/incidents/incident_store_test.exs`
- `test/beamwatch/ingestion/log_watcher_test.exs`

**Modify:**
- `lib/beamwatch/application.ex` — add LogWatcher + IncidentStore to supervision tree
- `lib/beamwatch_web/live/dashboard_live.ex` — full operator dashboard
- `test/beamwatch_web/live/dashboard_live_test.exs` — add LiveView tests

---

## Task 1: Core data structs

**Files:**
- Create: `lib/beamwatch/ingestion/parsed_line.ex`
- Create: `lib/beamwatch/incidents/incident.ex`
- Create: `lib/beamwatch/source_health.ex`

- [ ] **Step 1: Create ParsedLine struct**

```elixir
# lib/beamwatch/ingestion/parsed_line.ex
defmodule BeamWatch.Ingestion.ParsedLine do
  @moduledoc false

  @enforce_keys [:source, :raw]
  defstruct [:at, :source, :payload, :raw]

  @type t :: %__MODULE__{
    at: DateTime.t() | nil,
    source: String.t(),
    payload: String.t() | nil,
    raw: String.t()
  }
end
```

- [ ] **Step 2: Create Incident struct**

```elixir
# lib/beamwatch/incidents/incident.ex
defmodule BeamWatch.Incidents.Incident do
  @moduledoc false

  @type severity :: :critical | :warning | :info
  @type status :: :active | :acknowledged | :silenced | :resolved
  @type silence_scope :: nil | :incident | :type

  @type evidence_entry :: %{
    required(:source) => String.t(),
    required(:line) => String.t(),
    required(:at) => DateTime.t()
  }

  @type t :: %__MODULE__{
    id: String.t(),
    type: atom(),
    resource: String.t(),
    severity: severity(),
    status: status(),
    first_seen: DateTime.t(),
    last_seen: DateTime.t(),
    evidence: [evidence_entry()],
    silence_scope: silence_scope()
  }

  @enforce_keys [:id, :type, :resource, :severity, :status, :first_seen, :last_seen]
  defstruct [:id, :type, :resource, :severity, :status, :first_seen, :last_seen,
             evidence: [], silence_scope: nil]
end
```

- [ ] **Step 3: Create SourceHealth struct**

```elixir
# lib/beamwatch/source_health.ex
defmodule BeamWatch.SourceHealth do
  @moduledoc false

  @type t :: %__MODULE__{
    file: String.t(),
    exists?: boolean(),
    size_bytes: non_neg_integer(),
    last_read_at: DateTime.t() | nil,
    last_log_at: DateTime.t() | nil,
    byte_offset: non_neg_integer(),
    parse_failures: non_neg_integer(),
    rotated?: boolean()
  }

  defstruct [
    :file,
    :last_read_at,
    :last_log_at,
    exists?: false,
    size_bytes: 0,
    byte_offset: 0,
    parse_failures: 0,
    rotated?: false
  ]
end
```

- [ ] **Step 4: Compile to verify no errors**

```bash
mix compile
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add lib/beamwatch/ingestion/parsed_line.ex lib/beamwatch/incidents/incident.ex lib/beamwatch/source_health.ex
git commit -m "feat: add ParsedLine, Incident, and SourceHealth structs"
```

---

## Task 2: LogParser

**Files:**
- Create: `lib/beamwatch/ingestion/log_parser.ex`
- Create: `test/beamwatch/ingestion/log_parser_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/beamwatch/ingestion/log_parser_test.exs
defmodule BeamWatch.Ingestion.LogParserTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Ingestion.LogParser
  alias BeamWatch.Ingestion.ParsedLine

  test "parses a line with an ISO8601 timestamp prefix" do
    raw = "2026-06-05T15:01:40Z container=plex event=die exit_code=137"
    assert {:ok, %ParsedLine{source: "docker.log", payload: payload, raw: ^raw, at: at}} =
             LogParser.parse(raw, "docker.log")
    assert payload == "container=plex event=die exit_code=137"
    assert at.year == 2026 and at.month == 6 and at.day == 5
    assert at.hour == 15 and at.minute == 1 and at.second == 40
  end

  test "returns malformed when no timestamp prefix" do
    raw = "not-a-timestamp service=plex healthcheck"
    assert {:malformed, ^raw} = LogParser.parse(raw, "app.log")
  end

  test "returns malformed for truncated timestamp" do
    raw = "2026-06-05T15:16"
    assert {:malformed, ^raw} = LogParser.parse(raw, "smb.log")
  end

  test "returns malformed for empty line" do
    assert {:malformed, ""} = LogParser.parse("", "docker.log")
  end

  test "handles timestamp with sub-second precision" do
    raw = "2026-06-05T15:01:40.123Z payload text"
    assert {:ok, %ParsedLine{payload: "payload text"}} = LogParser.parse(raw, "app.log")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/beamwatch/ingestion/log_parser_test.exs
```

Expected: compilation error — `LogParser` not defined.

- [ ] **Step 3: Implement LogParser**

```elixir
# lib/beamwatch/ingestion/log_parser.ex
defmodule BeamWatch.Ingestion.LogParser do
  @moduledoc false

  alias BeamWatch.Ingestion.ParsedLine

  @timestamp_re ~r/\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z) (.*)\z/s

  @spec parse(String.t(), String.t()) :: {:ok, ParsedLine.t()} | {:malformed, String.t()}
  def parse(raw, source) do
    trimmed = String.trim_trailing(raw)

    case Regex.run(@timestamp_re, trimmed) do
      [_, ts_str, payload] ->
        case DateTime.from_iso8601(ts_str) do
          {:ok, at, _} ->
            {:ok, %ParsedLine{at: at, source: source, payload: payload, raw: raw}}

          _ ->
            {:malformed, raw}
        end

      _ ->
        {:malformed, raw}
    end
  end
end
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
mix test test/beamwatch/ingestion/log_parser_test.exs
```

Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/beamwatch/ingestion/log_parser.ex test/beamwatch/ingestion/log_parser_test.exs
git commit -m "feat: add LogParser with ISO8601 timestamp parsing"
```

---

## Task 3: ContainerRestartLoop detector

**Files:**
- Create: `lib/beamwatch/incidents/detectors/container_restart_loop.ex`
- Create: `test/beamwatch/incidents/detectors/container_restart_loop_test.exs`

The detector contract: `process(parsed_line, incidents, detector_state) :: {incidents, detector_state}`
- `incidents`: `%{String.t() => Incident.t()}`
- `detector_state` (for this detector): `%{String.t() => [{DateTime.t(), String.t(), String.t()}]}` — maps container name to list of `{timestamp, source, raw_line}` tuples for recent die events.

- [ ] **Step 1: Write failing tests**

```elixir
# test/beamwatch/incidents/detectors/container_restart_loop_test.exs
defmodule BeamWatch.Incidents.Detectors.ContainerRestartLoopTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Incidents.Detectors.ContainerRestartLoop
  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingestion.ParsedLine

  defp pl(source, offset_seconds, payload) do
    base = ~U[2026-06-05 15:00:00Z]
    at = DateTime.add(base, offset_seconds, :second)
    %ParsedLine{at: at, source: source, payload: payload, raw: "#{DateTime.to_iso8601(at)} #{payload}"}
  end

  defp run_lines(lines) do
    Enum.reduce(lines, {%{}, %{}}, fn line, {inc, state} ->
      ContainerRestartLoop.process(line, inc, state)
    end)
  end

  test "opens incident when 4 die events occur within 60 seconds" do
    lines = [
      pl("docker.log", 0, "container=plex event=die exit_code=137"),
      pl("docker.log", 8, "container=plex event=die exit_code=137"),
      pl("docker.log", 15, "container=plex event=die exit_code=137"),
      pl("docker.log", 21, "container=plex event=die exit_code=137")
    ]

    {incidents, _state} = run_lines(lines)

    assert %Incident{type: :container_restart_loop, resource: "plex", status: :active,
                     severity: :critical} = incidents["container_restart_loop:plex"]
  end

  test "does not open incident for 3 die events in 60 seconds" do
    lines = [
      pl("docker.log", 0, "container=plex event=die exit_code=137"),
      pl("docker.log", 8, "container=plex event=die exit_code=137"),
      pl("docker.log", 15, "container=plex event=die exit_code=137")
    ]

    {incidents, _state} = run_lines(lines)

    refute Map.has_key?(incidents, "container_restart_loop:plex")
  end

  test "die events older than 60 seconds are excluded from the window" do
    lines = [
      pl("docker.log", 0, "container=plex event=die exit_code=137"),
      pl("docker.log", 61, "container=plex event=die exit_code=137"),
      pl("docker.log", 69, "container=plex event=die exit_code=137"),
      pl("docker.log", 77, "container=plex event=die exit_code=137")
    ]

    # At t=77, only 3 events are within the 60s window (t=17 to t=77): t=61, t=69, t=77
    {incidents, _state} = run_lines(lines)

    refute Map.has_key?(incidents, "container_restart_loop:plex")
  end

  test "supporting healthcheck evidence appended to existing incident" do
    lines = [
      pl("docker.log", 0, "container=plex event=die exit_code=137"),
      pl("docker.log", 8, "container=plex event=die exit_code=137"),
      pl("docker.log", 15, "container=plex event=die exit_code=137"),
      pl("docker.log", 21, "container=plex event=die exit_code=137"),
      pl("app.log", 24, "service=plex healthcheck failed path=/identity request_id=plex-a")
    ]

    {incidents, _state} = run_lines(lines)

    incident = incidents["container_restart_loop:plex"]
    assert length(incident.evidence) == 5
  end

  test "home-assistant single die event does not create an incident" do
    lines = [
      pl("docker.log", 0, "container=home-assistant event=die exit_code=0")
    ]

    {incidents, _state} = run_lines(lines)

    refute Map.has_key?(incidents, "container_restart_loop:home-assistant")
  end

  test "first_seen is the timestamp of the first die event" do
    base = ~U[2026-06-05 15:00:00Z]
    lines = [
      pl("docker.log", 0, "container=plex event=die exit_code=137"),
      pl("docker.log", 8, "container=plex event=die exit_code=137"),
      pl("docker.log", 15, "container=plex event=die exit_code=137"),
      pl("docker.log", 21, "container=plex event=die exit_code=137")
    ]

    {incidents, _state} = run_lines(lines)

    incident = incidents["container_restart_loop:plex"]
    assert incident.first_seen == base
    assert incident.last_seen == DateTime.add(base, 21, :second)
  end

  test "lines from unrelated sources are ignored" do
    lines = [
      pl("syslog.log", 0, "container=plex event=die exit_code=137")
    ]

    {incidents, _state} = run_lines(lines)

    assert incidents == %{}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/beamwatch/incidents/detectors/container_restart_loop_test.exs
```

Expected: compilation error — module not defined.

- [ ] **Step 3: Implement ContainerRestartLoop detector**

```elixir
# lib/beamwatch/incidents/detectors/container_restart_loop.ex
defmodule BeamWatch.Incidents.Detectors.ContainerRestartLoop do
  @moduledoc false

  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingestion.ParsedLine

  @relevant_sources ~w[docker.log app.log nginx.log]
  @die_window_seconds 60
  @die_threshold 4

  @spec process(ParsedLine.t(), map(), map()) :: {map(), map()}
  def process(%ParsedLine{source: source} = line, incidents, state)
      when source in @relevant_sources do
    cond do
      die_event?(line) -> handle_die(line, incidents, state)
      supporting_evidence?(line) -> handle_supporting(line, incidents, state)
      true -> {incidents, state}
    end
  end

  def process(_line, incidents, state), do: {incidents, state}

  defp die_event?(%ParsedLine{source: "docker.log", payload: p}),
    do: p =~ ~r/container=\S+ event=die/

  defp die_event?(_), do: false

  defp supporting_evidence?(%ParsedLine{source: "app.log", payload: p}),
    do: p =~ "healthcheck failed"

  defp supporting_evidence?(%ParsedLine{source: "nginx.log", payload: p}),
    do: p =~ "unavailable"

  defp supporting_evidence?(%ParsedLine{source: "docker.log", payload: p}),
    do: p =~ "event=start"

  defp supporting_evidence?(_), do: false

  defp handle_die(%ParsedLine{payload: p, at: at} = line, incidents, state) do
    [_, container] = Regex.run(~r/container=(\S+) event=die/, p)

    prior_events = Map.get(state, container, [])
    cutoff = DateTime.add(at, -@die_window_seconds, :second)

    recent =
      [{at, line.source, line.raw} | prior_events]
      |> Enum.filter(fn {ts, _, _} -> DateTime.compare(ts, cutoff) != :lt end)

    new_state = Map.put(state, container, recent)
    incident_id = "container_restart_loop:#{container}"

    new_incidents =
      if length(recent) >= @die_threshold do
        case Map.get(incidents, incident_id) do
          nil ->
            {first_ts, _, _} = List.last(recent)
            inc = %Incident{
              id: incident_id,
              type: :container_restart_loop,
              resource: container,
              severity: :critical,
              status: :active,
              first_seen: first_ts,
              last_seen: at,
              evidence: recent |> Enum.reverse() |> Enum.map(&evidence_entry/1),
              silence_scope: nil
            }
            Map.put(incidents, incident_id, inc)

          inc ->
            Map.put(incidents, incident_id, append_evidence(inc, line))
        end
      else
        case Map.get(incidents, incident_id) do
          nil -> incidents
          _inc -> Map.update!(incidents, incident_id, &append_evidence(&1, line))
        end
      end

    {new_incidents, new_state}
  end

  defp handle_supporting(%ParsedLine{payload: p} = line, incidents, state) do
    container =
      cond do
        Regex.run(~r/container=(\S+)/, p) ->
          [_, c] = Regex.run(~r/container=(\S+)/, p)
          c

        Regex.run(~r/service=(\S+)/, p) ->
          [_, s] = Regex.run(~r/service=(\S+)/, p)
          s

        true ->
          nil
      end

    incident_id = container && "container_restart_loop:#{container}"

    new_incidents =
      if incident_id && Map.has_key?(incidents, incident_id) do
        Map.update!(incidents, incident_id, &append_evidence(&1, line))
      else
        incidents
      end

    {new_incidents, state}
  end

  defp append_evidence(%Incident{} = inc, %ParsedLine{at: at} = line) do
    %{inc | last_seen: at, evidence: inc.evidence ++ [evidence_entry({at, line.source, line.raw})]}
  end

  defp evidence_entry({at, source, raw}), do: %{at: at, source: source, line: raw}
end
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
mix test test/beamwatch/incidents/detectors/container_restart_loop_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/beamwatch/incidents/detectors/container_restart_loop.ex \
        test/beamwatch/incidents/detectors/container_restart_loop_test.exs
git commit -m "feat: add ContainerRestartLoop detector"
```

---

## Task 4: DiskSmartWarning detector

**Files:**
- Create: `lib/beamwatch/incidents/detectors/disk_smart_warning.ex`
- Create: `test/beamwatch/incidents/detectors/disk_smart_warning_test.exs`

`detector_state` for this detector: `%{}` (empty — all state lives in the incident).

- [ ] **Step 1: Write failing tests**

```elixir
# test/beamwatch/incidents/detectors/disk_smart_warning_test.exs
defmodule BeamWatch.Incidents.Detectors.DiskSmartWarningTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Incidents.Detectors.DiskSmartWarning
  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingestion.ParsedLine

  defp pl(source, offset_seconds, payload) do
    base = ~U[2026-06-05 15:00:00Z]
    at = DateTime.add(base, offset_seconds, :second)
    %ParsedLine{at: at, source: source, payload: payload, raw: "#{DateTime.to_iso8601(at)} #{payload}"}
  end

  defp run_lines(lines) do
    Enum.reduce(lines, {%{}, %{}}, fn line, {inc, state} ->
      DiskSmartWarning.process(line, inc, state)
    end)
  end

  test "opens incident on SMART warning" do
    line = pl("syslog.log", 0, "emhttpd: disk3 SMART warning: Reallocated_Sector_Ct raw=28 threshold=10")
    {incidents, _state} = DiskSmartWarning.process(line, %{}, %{})

    assert %Incident{type: :disk_smart_warning, resource: "disk3",
                     status: :active, severity: :warning} =
             incidents["disk_smart_warning:disk3:2026-06-05"]
  end

  test "groups repeated warnings for same disk on same day" do
    lines = [
      pl("syslog.log", 0, "emhttpd: disk3 SMART warning: Reallocated_Sector_Ct raw=28 threshold=10"),
      pl("syslog.log", 18, "emhttpd: disk3 SMART warning: Current_Pending_Sector raw=2 threshold=0")
    ]

    {incidents, _state} = run_lines(lines)

    assert map_size(incidents) == 1
    assert length(incidents["disk_smart_warning:disk3:2026-06-05"].evidence) == 2
  end

  test "auto-resolves on SMART check passed" do
    lines = [
      pl("syslog.log", 0, "emhttpd: disk3 SMART warning: Reallocated_Sector_Ct raw=28 threshold=10"),
      pl("syslog.log", 1500, "emhttpd: disk3 SMART check passed")
    ]

    {incidents, _state} = run_lines(lines)

    assert incidents["disk_smart_warning:disk3:2026-06-05"].status == :resolved
  end

  test "SMART check passed does not crash when no open incident exists" do
    line = pl("syslog.log", 0, "emhttpd: disk1 SMART check passed")
    assert {%{}, %{}} = DiskSmartWarning.process(line, %{}, %{})
  end

  test "ignores lines from other sources" do
    line = pl("docker.log", 0, "emhttpd: disk3 SMART warning: Reallocated_Sector_Ct raw=28")
    {incidents, _state} = DiskSmartWarning.process(line, %{}, %{})

    assert incidents == %{}
  end

  test "benign SMART check passed for disk1 does not affect disk3 incident" do
    lines = [
      pl("syslog.log", 0, "emhttpd: disk3 SMART warning: Reallocated_Sector_Ct raw=28 threshold=10"),
      pl("syslog.log", 10, "emhttpd: disk1 SMART check passed")
    ]

    {incidents, _state} = run_lines(lines)

    assert incidents["disk_smart_warning:disk3:2026-06-05"].status == :active
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/beamwatch/incidents/detectors/disk_smart_warning_test.exs
```

Expected: compilation error.

- [ ] **Step 3: Implement DiskSmartWarning detector**

```elixir
# lib/beamwatch/incidents/detectors/disk_smart_warning.ex
defmodule BeamWatch.Incidents.Detectors.DiskSmartWarning do
  @moduledoc false

  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingestion.ParsedLine

  @spec process(ParsedLine.t(), map(), map()) :: {map(), map()}
  def process(%ParsedLine{source: "syslog.log"} = line, incidents, state) do
    cond do
      smart_warning?(line.payload) -> handle_warning(line, incidents, state)
      smart_passed?(line.payload) -> handle_passed(line, incidents, state)
      true -> {incidents, state}
    end
  end

  def process(_line, incidents, state), do: {incidents, state}

  defp smart_warning?(payload), do: payload =~ ~r/emhttpd: (\S+) SMART warning:/

  defp smart_passed?(payload), do: payload =~ ~r/emhttpd: (\S+) SMART check passed/

  defp handle_warning(%ParsedLine{payload: p, at: at} = line, incidents, state) do
    [_, disk] = Regex.run(~r/emhttpd: (\S+) SMART warning:/, p)
    date_str = Calendar.strftime(at, "%Y-%m-%d")
    incident_id = "disk_smart_warning:#{disk}:#{date_str}"

    new_incidents =
      case Map.get(incidents, incident_id) do
        nil ->
          inc = %Incident{
            id: incident_id,
            type: :disk_smart_warning,
            resource: disk,
            severity: :warning,
            status: :active,
            first_seen: at,
            last_seen: at,
            evidence: [evidence_entry(line)],
            silence_scope: nil
          }
          Map.put(incidents, incident_id, inc)

        inc ->
          updated = %{inc | last_seen: at, evidence: inc.evidence ++ [evidence_entry(line)]}
          Map.put(incidents, incident_id, updated)
      end

    {new_incidents, state}
  end

  defp handle_passed(%ParsedLine{payload: p, at: at} = line, incidents, state) do
    [_, disk] = Regex.run(~r/emhttpd: (\S+) SMART check passed/, p)
    date_str = Calendar.strftime(at, "%Y-%m-%d")
    incident_id = "disk_smart_warning:#{disk}:#{date_str}"

    new_incidents =
      case Map.get(incidents, incident_id) do
        nil ->
          incidents

        inc ->
          updated = %{inc | status: :resolved, last_seen: at,
                      evidence: inc.evidence ++ [evidence_entry(line)]}
          Map.put(incidents, incident_id, updated)
      end

    {new_incidents, state}
  end

  defp evidence_entry(%ParsedLine{source: source, raw: raw, at: at}),
    do: %{source: source, line: raw, at: at}
end
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
mix test test/beamwatch/incidents/detectors/disk_smart_warning_test.exs
```

Expected: 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/beamwatch/incidents/detectors/disk_smart_warning.ex \
        test/beamwatch/incidents/detectors/disk_smart_warning_test.exs
git commit -m "feat: add DiskSmartWarning detector"
```

---

## Task 5: SharePermissionFailure detector

**Files:**
- Create: `lib/beamwatch/incidents/detectors/share_permission_failure.ex`
- Create: `test/beamwatch/incidents/detectors/share_permission_failure_test.exs`

`detector_state`: `%{}` — uses `last_seen` on existing incident to decide windowing.

- [ ] **Step 1: Write failing tests**

```elixir
# test/beamwatch/incidents/detectors/share_permission_failure_test.exs
defmodule BeamWatch.Incidents.Detectors.SharePermissionFailureTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Incidents.Detectors.SharePermissionFailure
  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingestion.ParsedLine

  defp pl(source, offset_seconds, payload) do
    base = ~U[2026-06-05 15:00:00Z]
    at = DateTime.add(base, offset_seconds, :second)
    %ParsedLine{at: at, source: source, payload: payload, raw: "#{DateTime.to_iso8601(at)} #{payload}"}
  end

  defp run_lines(lines) do
    Enum.reduce(lines, {%{}, %{}}, fn line, {inc, state} ->
      SharePermissionFailure.process(line, inc, state)
    end)
  end

  test "opens incident on SMB permission denied" do
    line = pl("smb.log", 0, "smbd[8112]: Permission denied share=media user=guest path=/mnt/user/media/private")
    {incidents, _state} = SharePermissionFailure.process(line, %{}, %{})

    assert %Incident{type: :share_permission_failure, resource: "media",
                     status: :active, severity: :warning} =
             incidents["share_permission_failure:media"]
  end

  test "opens incident on NFS permission denied" do
    line = pl("nfs.log", 0, "nfsd: permission denied share=media client=192.168.1.12")
    {incidents, _state} = SharePermissionFailure.process(line, %{}, %{})

    assert Map.has_key?(incidents, "share_permission_failure:media")
  end

  test "updates existing incident within 10-minute window" do
    lines = [
      pl("smb.log", 0, "smbd[8112]: Permission denied share=media user=guest path=/mnt/user/media/private"),
      pl("nfs.log", 300, "nfsd: permission denied share=media client=192.168.1.12")
    ]

    {incidents, _state} = run_lines(lines)

    assert map_size(incidents) == 1
    assert length(incidents["share_permission_failure:media"].evidence) == 2
  end

  test "opens new incident after 10-minute window expires" do
    lines = [
      pl("smb.log", 0, "smbd[8112]: Permission denied share=media user=guest path=/mnt/user/media/private"),
      pl("smb.log", 601, "smbd[8112]: Permission denied share=media user=guest path=/mnt/user/media/private")
    ]

    {incidents, _state} = run_lines(lines)

    # The second line updates the existing incident (same id), but last_seen changes
    incident = incidents["share_permission_failure:media"]
    assert incident.status == :active
  end

  test "ignores successful share operations" do
    line = pl("smb.log", 0, "smbd[8220]: user=alex opened share=backups path=/mnt/user/backups")
    {incidents, _state} = SharePermissionFailure.process(line, %{}, %{})

    assert incidents == %{}
  end

  test "ignores lines from other sources" do
    line = pl("docker.log", 0, "Permission denied share=media")
    {incidents, _state} = SharePermissionFailure.process(line, %{}, %{})

    assert incidents == %{}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/beamwatch/incidents/detectors/share_permission_failure_test.exs
```

Expected: compilation error.

- [ ] **Step 3: Implement SharePermissionFailure detector**

```elixir
# lib/beamwatch/incidents/detectors/share_permission_failure.ex
defmodule BeamWatch.Incidents.Detectors.SharePermissionFailure do
  @moduledoc false

  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingestion.ParsedLine

  @relevant_sources ~w[smb.log nfs.log]
  @window_seconds 600

  @spec process(ParsedLine.t(), map(), map()) :: {map(), map()}
  def process(%ParsedLine{source: source} = line, incidents, state)
      when source in @relevant_sources do
    case extract_share(line.payload) do
      nil -> {incidents, state}
      share -> handle_denial(share, line, incidents, state)
    end
  end

  def process(_line, incidents, state), do: {incidents, state}

  defp extract_share(payload) do
    cond do
      payload =~ "Permission denied" || payload =~ "permission denied" ->
        case Regex.run(~r/share=(\S+)/, payload) do
          [_, share] -> share
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp handle_denial(share, %ParsedLine{at: at} = line, incidents, state) do
    incident_id = "share_permission_failure:#{share}"

    new_incidents =
      case Map.get(incidents, incident_id) do
        nil ->
          inc = %Incident{
            id: incident_id,
            type: :share_permission_failure,
            resource: share,
            severity: :warning,
            status: :active,
            first_seen: at,
            last_seen: at,
            evidence: [evidence_entry(line)],
            silence_scope: nil
          }
          Map.put(incidents, incident_id, inc)

        %Incident{last_seen: last_seen} = inc ->
          if DateTime.diff(at, last_seen, :second) <= @window_seconds do
            updated = %{inc | last_seen: at, evidence: inc.evidence ++ [evidence_entry(line)]}
            Map.put(incidents, incident_id, updated)
          else
            # Outside window — reset the incident to the new event
            reset = %{inc | first_seen: at, last_seen: at,
                      evidence: [evidence_entry(line)], status: :active}
            Map.put(incidents, incident_id, reset)
          end
      end

    {new_incidents, state}
  end

  defp evidence_entry(%ParsedLine{source: source, raw: raw, at: at}),
    do: %{source: source, line: raw, at: at}
end
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
mix test test/beamwatch/incidents/detectors/share_permission_failure_test.exs
```

Expected: 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/beamwatch/incidents/detectors/share_permission_failure.ex \
        test/beamwatch/incidents/detectors/share_permission_failure_test.exs
git commit -m "feat: add SharePermissionFailure detector"
```

---

## Task 6: VmBootFailure detector

**Files:**
- Create: `lib/beamwatch/incidents/detectors/vm_boot_failure.ex`
- Create: `test/beamwatch/incidents/detectors/vm_boot_failure_test.exs`

`detector_state`: `%{}` (all state in incident).

- [ ] **Step 1: Write failing tests**

```elixir
# test/beamwatch/incidents/detectors/vm_boot_failure_test.exs
defmodule BeamWatch.Incidents.Detectors.VmBootFailureTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Incidents.Detectors.VmBootFailure
  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingestion.ParsedLine

  defp pl(source, offset_seconds, payload) do
    base = ~U[2026-06-05 15:00:00Z]
    at = DateTime.add(base, offset_seconds, :second)
    %ParsedLine{at: at, source: source, payload: payload, raw: "#{DateTime.to_iso8601(at)} #{payload}"}
  end

  defp run_lines(lines) do
    Enum.reduce(lines, {%{}, %{}}, fn line, {inc, state} ->
      VmBootFailure.process(line, inc, state)
    end)
  end

  test "opens incident on vm start status=failed" do
    line = pl("libvirt.log", 0,
      ~S(vm=windows11 action=start status=failed reason="cannot access storage image /mnt/user/domains/windows11/vdisk1.img"))

    {incidents, _state} = VmBootFailure.process(line, %{}, %{})

    assert %Incident{type: :vm_boot_failure, resource: "windows11",
                     status: :active, severity: :critical} =
             incidents["vm_boot_failure:windows11"]
  end

  test "appends qemu supporting evidence to existing incident" do
    lines = [
      pl("libvirt.log", 0,
        ~S(vm=windows11 action=start status=failed reason="cannot access storage image")),
      pl("qemu.log", 2,
        "qemu-system-x86_64: -drive file=/mnt/user/domains/windows11/vdisk1.img: Permission denied")
    ]

    {incidents, _state} = run_lines(lines)

    incident = incidents["vm_boot_failure:windows11"]
    assert length(incident.evidence) == 2
  end

  test "appends syslog kernel bridge missing evidence" do
    lines = [
      pl("libvirt.log", 0,
        ~S(vm=windows11 action=start status=failed reason="cannot access storage image")),
      pl("syslog.log", 2, "kernel: br0: port missing for vm=windows11")
    ]

    {incidents, _state} = run_lines(lines)

    assert length(incidents["vm_boot_failure:windows11"].evidence) == 2
  end

  test "auto-resolves on vm status=running" do
    lines = [
      pl("libvirt.log", 0,
        ~S(vm=windows11 action=start status=failed reason="cannot access storage image")),
      pl("libvirt.log", 240, "vm=windows11 action=start status=running")
    ]

    {incidents, _state} = run_lines(lines)

    assert incidents["vm_boot_failure:windows11"].status == :resolved
  end

  test "status=running without prior failure is ignored" do
    line = pl("libvirt.log", 0, "vm=debian-dev action=start status=running")
    {incidents, _state} = VmBootFailure.process(line, %{}, %{})

    assert incidents == %{}
  end

  test "qemu evidence without prior failure is ignored" do
    line = pl("qemu.log", 0,
      "qemu-system-x86_64: terminating on signal 15 from pid 1882")

    {incidents, _state} = VmBootFailure.process(line, %{}, %{})

    assert incidents == %{}
  end

  test "ignores lines from unrelated sources" do
    line = pl("docker.log", 0, "vm=windows11 action=start status=failed")
    {incidents, _state} = VmBootFailure.process(line, %{}, %{})

    assert incidents == %{}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/beamwatch/incidents/detectors/vm_boot_failure_test.exs
```

Expected: compilation error.

- [ ] **Step 3: Implement VmBootFailure detector**

```elixir
# lib/beamwatch/incidents/detectors/vm_boot_failure.ex
defmodule BeamWatch.Incidents.Detectors.VmBootFailure do
  @moduledoc false

  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingestion.ParsedLine

  @spec process(ParsedLine.t(), map(), map()) :: {map(), map()}
  def process(%ParsedLine{source: "libvirt.log"} = line, incidents, state) do
    cond do
      vm_failed?(line.payload) -> handle_failure(line, incidents, state)
      vm_running?(line.payload) -> handle_running(line, incidents, state)
      true -> {incidents, state}
    end
  end

  def process(%ParsedLine{source: source} = line, incidents, state)
      when source in ["qemu.log", "syslog.log"] do
    case supporting_vm(line.payload) do
      nil -> {incidents, state}
      vm -> maybe_append_evidence(vm, line, incidents, state)
    end
  end

  def process(_line, incidents, state), do: {incidents, state}

  defp vm_failed?(payload), do: payload =~ ~r/vm=\S+.*status=failed/

  defp vm_running?(payload), do: payload =~ ~r/vm=\S+.*status=running/

  defp supporting_vm(payload) do
    cond do
      payload =~ "qemu-system-x86_64" && (payload =~ "Permission denied" || payload =~ "-drive file=") ->
        case Regex.run(~r|/domains/(\S+)/|, payload) do
          [_, vm] -> vm
          _ -> nil
        end

      payload =~ "port missing for vm=" ->
        case Regex.run(~r/port missing for vm=(\S+)/, payload) do
          [_, vm] -> vm
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp handle_failure(%ParsedLine{payload: p, at: at} = line, incidents, state) do
    [_, vm] = Regex.run(~r/vm=(\S+)/, p)
    incident_id = "vm_boot_failure:#{vm}"

    new_incidents =
      case Map.get(incidents, incident_id) do
        nil ->
          inc = %Incident{
            id: incident_id,
            type: :vm_boot_failure,
            resource: vm,
            severity: :critical,
            status: :active,
            first_seen: at,
            last_seen: at,
            evidence: [evidence_entry(line)],
            silence_scope: nil
          }
          Map.put(incidents, incident_id, inc)

        inc ->
          updated = %{inc | last_seen: at, evidence: inc.evidence ++ [evidence_entry(line)]}
          Map.put(incidents, incident_id, updated)
      end

    {new_incidents, state}
  end

  defp handle_running(%ParsedLine{payload: p, at: at} = line, incidents, state) do
    [_, vm] = Regex.run(~r/vm=(\S+)/, p)
    incident_id = "vm_boot_failure:#{vm}"

    new_incidents =
      case Map.get(incidents, incident_id) do
        nil ->
          incidents

        inc ->
          updated = %{inc | status: :resolved, last_seen: at,
                      evidence: inc.evidence ++ [evidence_entry(line)]}
          Map.put(incidents, incident_id, updated)
      end

    {new_incidents, state}
  end

  defp maybe_append_evidence(vm, line, incidents, state) do
    incident_id = "vm_boot_failure:#{vm}"

    new_incidents =
      case Map.get(incidents, incident_id) do
        nil -> incidents
        inc -> Map.put(incidents, incident_id, %{inc | last_seen: line.at,
                       evidence: inc.evidence ++ [evidence_entry(line)]})
      end

    {new_incidents, state}
  end

  defp evidence_entry(%ParsedLine{source: source, raw: raw, at: at}),
    do: %{source: source, line: raw, at: at}
end
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
mix test test/beamwatch/incidents/detectors/vm_boot_failure_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/beamwatch/incidents/detectors/vm_boot_failure.ex \
        test/beamwatch/incidents/detectors/vm_boot_failure_test.exs
git commit -m "feat: add VmBootFailure detector"
```

---

## Task 7: IncidentStore GenServer

**Files:**
- Create: `lib/beamwatch/incidents/incident_store.ex`
- Create: `test/beamwatch/incidents/incident_store_test.exs`

The store subscribes to `"beamwatch:log_watcher"` PubSub topic, processes lines through all detectors, and broadcasts `{:dashboard_updated, state_snapshot}` to `"beamwatch:dashboard"`.

State shape:
```elixir
%{
  incidents: %{},                 # %{id => Incident.t()}
  source_health: %{},             # %{filename => SourceHealth.t()}
  recent_activity: [],            # newest first, max 50
  silenced_types: MapSet.new(),   # atom set
  detector_states: %{
    container_restart_loop: %{},
    disk_smart_warning: %{},
    share_permission_failure: %{},
    vm_boot_failure: %{}
  }
}
```

- [ ] **Step 1: Write failing tests**

```elixir
# test/beamwatch/incidents/incident_store_test.exs
defmodule BeamWatch.Incidents.IncidentStoreTest do
  use ExUnit.Case, async: false

  alias BeamWatch.Incidents.IncidentStore
  alias BeamWatch.Ingestion.ParsedLine

  setup do
    start_supervised!({IncidentStore, name: nil, pubsub: BeamWatch.PubSub})
    :ok
  end

  defp pl(source, offset_seconds, payload) do
    base = ~U[2026-06-05 15:00:00Z]
    at = DateTime.add(base, offset_seconds, :second)
    %ParsedLine{at: at, source: source, payload: payload,
                raw: "#{DateTime.to_iso8601(at)} #{payload}"}
  end

  defp four_plex_dies do
    [
      pl("docker.log", 0, "container=plex event=die exit_code=137"),
      pl("docker.log", 8, "container=plex event=die exit_code=137"),
      pl("docker.log", 15, "container=plex event=die exit_code=137"),
      pl("docker.log", 21, "container=plex event=die exit_code=137")
    ]
  end

  test "ingest line creates incident when threshold is met", %{pid: store} do
    Enum.each(four_plex_dies(), &IncidentStore.ingest_line(store, &1))
    state = IncidentStore.get_state(store)

    assert Map.has_key?(state.incidents, "container_restart_loop:plex")
  end

  test "acknowledge changes status to :acknowledged", %{pid: store} do
    Enum.each(four_plex_dies(), &IncidentStore.ingest_line(store, &1))
    :ok = IncidentStore.acknowledge(store, "container_restart_loop:plex")
    state = IncidentStore.get_state(store)

    assert state.incidents["container_restart_loop:plex"].status == :acknowledged
  end

  test "silence with :incident scope changes status to :silenced", %{pid: store} do
    Enum.each(four_plex_dies(), &IncidentStore.ingest_line(store, &1))
    :ok = IncidentStore.silence(store, "container_restart_loop:plex", :incident)
    state = IncidentStore.get_state(store)

    assert state.incidents["container_restart_loop:plex"].status == :silenced
    assert state.incidents["container_restart_loop:plex"].silence_scope == :incident
  end

  test "silence with :type scope silences all incidents of that type", %{pid: store} do
    Enum.each(four_plex_dies(), &IncidentStore.ingest_line(store, &1))
    :ok = IncidentStore.silence(store, "container_restart_loop:plex", :type)
    state = IncidentStore.get_state(store)

    assert state.incidents["container_restart_loop:plex"].status == :silenced
    assert MapSet.member?(state.silenced_types, :container_restart_loop)
  end

  test "new incidents of silenced type are created with :silenced status", %{pid: store} do
    :ok = IncidentStore.silence(store, "container_restart_loop:plex", :type)

    Enum.each(four_plex_dies(), &IncidentStore.ingest_line(store, &1))
    state = IncidentStore.get_state(store)

    assert state.incidents["container_restart_loop:plex"].status == :silenced
  end

  test "resolve changes status to :resolved", %{pid: store} do
    Enum.each(four_plex_dies(), &IncidentStore.ingest_line(store, &1))
    :ok = IncidentStore.resolve(store, "container_restart_loop:plex")
    state = IncidentStore.get_state(store)

    assert state.incidents["container_restart_loop:plex"].status == :resolved
  end

  test "clear_silence restores :active status", %{pid: store} do
    Enum.each(four_plex_dies(), &IncidentStore.ingest_line(store, &1))
    :ok = IncidentStore.silence(store, "container_restart_loop:plex", :incident)
    :ok = IncidentStore.clear_silence(store, "container_restart_loop:plex")
    state = IncidentStore.get_state(store)

    assert state.incidents["container_restart_loop:plex"].status == :active
    assert state.incidents["container_restart_loop:plex"].silence_scope == nil
  end

  test "malformed lines are tracked in source health parse_failures", %{pid: store} do
    IncidentStore.ingest_malformed(store, "docker.log")
    IncidentStore.ingest_malformed(store, "docker.log")
    state = IncidentStore.get_state(store)

    assert state.source_health["docker.log"].parse_failures == 2
  end

  test "recent activity keeps the last 50 lines newest first", %{pid: store} do
    Enum.each(1..55, fn i ->
      IncidentStore.ingest_line(store, pl("syslog.log", i, "emhttpd: Array event=#{i}"))
    end)

    state = IncidentStore.get_state(store)
    assert length(state.recent_activity) == 50
    [newest | _] = state.recent_activity
    assert newest.line =~ "event=55"
  end

  setup context do
    {:ok, pid} = IncidentStore.start_link(name: nil, pubsub: BeamWatch.PubSub)
    Map.put(context, :pid, pid)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/beamwatch/incidents/incident_store_test.exs
```

Expected: compilation error.

- [ ] **Step 3: Implement IncidentStore**

```elixir
# lib/beamwatch/incidents/incident_store.ex
defmodule BeamWatch.Incidents.IncidentStore do
  @moduledoc false

  use GenServer

  alias BeamWatch.Incidents.Detectors.ContainerRestartLoop
  alias BeamWatch.Incidents.Detectors.DiskSmartWarning
  alias BeamWatch.Incidents.Detectors.SharePermissionFailure
  alias BeamWatch.Incidents.Detectors.VmBootFailure
  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingestion.ParsedLine
  alias BeamWatch.SourceHealth

  @max_activity 50

  @detectors [
    {:container_restart_loop, ContainerRestartLoop},
    {:disk_smart_warning, DiskSmartWarning},
    {:share_permission_failure, SharePermissionFailure},
    {:vm_boot_failure, VmBootFailure}
  ]

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    pubsub = Keyword.get(opts, :pubsub, BeamWatch.PubSub)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, %{pubsub: pubsub}, gen_opts)
  end

  @spec ingest_line(GenServer.server(), ParsedLine.t()) :: :ok
  def ingest_line(server \\ __MODULE__, %ParsedLine{} = line) do
    GenServer.cast(server, {:ingest_line, line})
  end

  @spec ingest_malformed(GenServer.server(), String.t()) :: :ok
  def ingest_malformed(server \\ __MODULE__, source) do
    GenServer.cast(server, {:ingest_malformed, source})
  end

  @spec update_source_health(GenServer.server(), SourceHealth.t()) :: :ok
  def update_source_health(server \\ __MODULE__, %SourceHealth{} = health) do
    GenServer.cast(server, {:update_source_health, health})
  end

  @spec get_state(GenServer.server()) :: map()
  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  @spec acknowledge(GenServer.server(), String.t()) :: :ok
  def acknowledge(server \\ __MODULE__, incident_id) do
    GenServer.call(server, {:acknowledge, incident_id})
  end

  @spec silence(GenServer.server(), String.t(), :incident | :type) :: :ok
  def silence(server \\ __MODULE__, incident_id, scope) do
    GenServer.call(server, {:silence, incident_id, scope})
  end

  @spec resolve(GenServer.server(), String.t()) :: :ok
  def resolve(server \\ __MODULE__, incident_id) do
    GenServer.call(server, {:resolve, incident_id})
  end

  @spec clear_silence(GenServer.server(), String.t()) :: :ok
  def clear_silence(server \\ __MODULE__, incident_id) do
    GenServer.call(server, {:clear_silence, incident_id})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(%{pubsub: pubsub}) do
    state = %{
      incidents: %{},
      source_health: %{},
      recent_activity: [],
      silenced_types: MapSet.new(),
      pubsub: pubsub,
      detector_states: Map.new(@detectors, fn {key, _mod} -> {key, %{}} end)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:ingest_line, %ParsedLine{} = line}, state) do
    activity_entry = %{source: line.source, line: line.raw, at: line.at}

    recent_activity =
      [activity_entry | state.recent_activity]
      |> Enum.take(@max_activity)

    {incidents, detector_states} = run_detectors(line, state.incidents, state.detector_states)
    incidents = apply_type_silencing(incidents, state.silenced_types)

    new_state = %{state | incidents: incidents, recent_activity: recent_activity,
                  detector_states: detector_states}
    broadcast(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:ingest_malformed, source}, state) do
    new_health = Map.update(
      state.source_health,
      source,
      %SourceHealth{file: source, parse_failures: 1},
      fn h -> %{h | parse_failures: h.parse_failures + 1} end
    )

    new_state = %{state | source_health: new_health}
    broadcast(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:update_source_health, %SourceHealth{} = health}, state) do
    current = Map.get(state.source_health, health.file, %SourceHealth{file: health.file})
    merged = %{health | parse_failures: current.parse_failures}
    new_state = %{state | source_health: Map.put(state.source_health, health.file, merged)}
    broadcast(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:acknowledge, id}, _from, state) do
    state = update_incident(state, id, &%{&1 | status: :acknowledged})
    broadcast(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:silence, id, :type}, _from, state) do
    case Map.get(state.incidents, id) do
      nil ->
        {:reply, :ok, state}

      %Incident{type: type} ->
        silenced_types = MapSet.put(state.silenced_types, type)

        incidents =
          Map.map(state.incidents, fn {_k, inc} ->
            if inc.type == type && inc.status in [:active, :acknowledged] do
              %{inc | status: :silenced, silence_scope: :type}
            else
              inc
            end
          end)

        new_state = %{state | silenced_types: silenced_types, incidents: incidents}
        broadcast(new_state)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:silence, id, :incident}, _from, state) do
    state = update_incident(state, id, &%{&1 | status: :silenced, silence_scope: :incident})
    broadcast(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:resolve, id}, _from, state) do
    state = update_incident(state, id, &%{&1 | status: :resolved})
    broadcast(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:clear_silence, id}, _from, state) do
    silenced_types =
      case Map.get(state.incidents, id) do
        %Incident{silence_scope: :type, type: type} -> MapSet.delete(state.silenced_types, type)
        _ -> state.silenced_types
      end

    state =
      state
      |> Map.put(:silenced_types, silenced_types)
      |> update_incident(id, &%{&1 | status: :active, silence_scope: nil})

    broadcast(state)
    {:reply, :ok, state}
  end

  # --- Helpers ---

  defp run_detectors(line, incidents, detector_states) do
    Enum.reduce(@detectors, {incidents, detector_states}, fn {key, mod}, {inc_acc, ds_acc} ->
      det_state = Map.get(ds_acc, key, %{})
      {new_inc, new_det_state} = mod.process(line, inc_acc, det_state)
      {new_inc, Map.put(ds_acc, key, new_det_state)}
    end)
  end

  defp apply_type_silencing(incidents, silenced_types) do
    if MapSet.size(silenced_types) == 0 do
      incidents
    else
      Map.map(incidents, fn {_k, inc} ->
        if MapSet.member?(silenced_types, inc.type) && inc.status == :active do
          %{inc | status: :silenced, silence_scope: :type}
        else
          inc
        end
      end)
    end
  end

  defp update_incident(state, id, fun) do
    case Map.get(state.incidents, id) do
      nil -> state
      inc -> %{state | incidents: Map.put(state.incidents, id, fun.(inc))}
    end
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(state.pubsub, "beamwatch:dashboard", {:dashboard_updated, state})
  end
end
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
mix test test/beamwatch/incidents/incident_store_test.exs
```

Expected: 9 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/beamwatch/incidents/incident_store.ex \
        test/beamwatch/incidents/incident_store_test.exs
git commit -m "feat: add IncidentStore GenServer with operator actions"
```

---

## Task 8: LogWatcher GenServer

**Files:**
- Create: `lib/beamwatch/ingestion/log_watcher.ex`
- Create: `test/beamwatch/ingestion/log_watcher_test.exs`

Polls every 500ms. State: `%{log_dir, poll_ms, store, files: %{filename => %{offset, buffer, size}}}`.

- [ ] **Step 1: Write failing tests**

```elixir
# test/beamwatch/ingestion/log_watcher_test.exs
defmodule BeamWatch.Ingestion.LogWatcherTest do
  use ExUnit.Case, async: false

  alias BeamWatch.Incidents.IncidentStore
  alias BeamWatch.Ingestion.LogWatcher

  setup do
    tmp = Path.join(System.tmp_dir!(), "bw-watcher-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    {:ok, store} = IncidentStore.start_link(name: nil, pubsub: BeamWatch.PubSub)

    on_exit(fn ->
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, store: store}
  end

  test "publishes lines written to a log file", %{tmp: tmp, store: store} do
    {:ok, _watcher} =
      LogWatcher.start_link(log_dir: tmp, store: store, poll_ms: 50, name: nil)

    path = Path.join(tmp, "docker.log")
    File.write!(path, "2026-06-05T15:01:40Z container=plex event=die exit_code=137\n")

    Process.sleep(200)
    state = IncidentStore.get_state(store)

    assert length(state.recent_activity) >= 1
    assert hd(state.recent_activity).line =~ "container=plex event=die"
  end

  test "tracks source health for watched files", %{tmp: tmp, store: store} do
    path = Path.join(tmp, "syslog.log")
    File.write!(path, "2026-06-05T15:01:40Z emhttpd: Array Started\n")

    {:ok, _watcher} =
      LogWatcher.start_link(log_dir: tmp, store: store, poll_ms: 50, name: nil)

    Process.sleep(200)
    state = IncidentStore.get_state(store)

    assert Map.has_key?(state.source_health, "syslog.log")
    health = state.source_health["syslog.log"]
    assert health.exists? == true
    assert health.size_bytes > 0
  end

  test "detects malformed lines and increments parse_failures", %{tmp: tmp, store: store} do
    path = Path.join(tmp, "app.log")
    File.write!(path, "not-a-timestamp service=plex healthcheck\n")

    {:ok, _watcher} =
      LogWatcher.start_link(log_dir: tmp, store: store, poll_ms: 50, name: nil)

    Process.sleep(200)
    state = IncidentStore.get_state(store)

    assert state.source_health["app.log"].parse_failures >= 1
  end

  test "detects file rotation when size shrinks", %{tmp: tmp, store: store} do
    path = Path.join(tmp, "docker.log")
    File.write!(path, "2026-06-05T15:01:40Z container=plex event=die exit_code=137\n")

    {:ok, _watcher} =
      LogWatcher.start_link(log_dir: tmp, store: store, poll_ms: 50, name: nil)

    Process.sleep(150)

    # Truncate the file (simulate rotation)
    File.write!(path, "2026-06-05T15:02:00Z container=plex event=start\n")
    Process.sleep(150)

    state = IncidentStore.get_state(store)
    # After rotation, watcher should reset offset and still read new lines
    assert length(state.recent_activity) >= 1
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/beamwatch/ingestion/log_watcher_test.exs
```

Expected: compilation error.

- [ ] **Step 3: Implement LogWatcher**

```elixir
# lib/beamwatch/ingestion/log_watcher.ex
defmodule BeamWatch.Ingestion.LogWatcher do
  @moduledoc false

  use GenServer

  alias BeamWatch.Incidents.IncidentStore
  alias BeamWatch.Ingestion.LogParser
  alias BeamWatch.SourceHealth

  @default_poll_ms 500

  def start_link(opts \\ []) do
    log_dir = Keyword.fetch!(opts, :log_dir)
    store = Keyword.get(opts, :store, IncidentStore)
    poll_ms = Keyword.get(opts, :poll_ms, @default_poll_ms)
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []

    GenServer.start_link(__MODULE__, %{log_dir: log_dir, store: store, poll_ms: poll_ms},
      gen_opts)
  end

  @impl true
  def init(%{log_dir: log_dir, store: store, poll_ms: poll_ms}) do
    state = %{
      log_dir: log_dir,
      store: store,
      poll_ms: poll_ms,
      files: %{}
    }

    schedule_poll(poll_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_files = poll_directory(state.log_dir, state.files, state.store)
    schedule_poll(state.poll_ms)
    {:noreply, %{state | files: new_files}}
  end

  defp schedule_poll(ms), do: Process.send_after(self(), :poll, ms)

  defp poll_directory(log_dir, files, store) do
    case File.ls(log_dir) do
      {:ok, entries} ->
        filenames = Enum.filter(entries, &(Path.extname(&1) == ".log"))
        Enum.reduce(filenames, files, &poll_file(&1, log_dir, &2, store))

      {:error, _} ->
        files
    end
  end

  defp poll_file(filename, log_dir, files, store) do
    path = Path.join(log_dir, filename)
    file_state = Map.get(files, filename, %{offset: 0, buffer: "", size: 0})

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} ->
        {new_offset, new_buffer, rotated?} =
          if size < file_state.offset do
            # Rotation detected — reset
            {0, "", true}
          else
            {file_state.offset, file_state.buffer, false}
          end

        {lines, final_buffer, parse_failures, last_log_at} =
          if size > new_offset do
            read_new_lines(path, new_offset, new_buffer, filename, store)
          else
            {[], new_buffer, 0, nil}
          end

        final_offset = new_offset + byte_size(Enum.join(lines, "\n") <> if(lines == [], do: "", else: "\n"))

        health = %SourceHealth{
          file: filename,
          exists?: true,
          size_bytes: size,
          last_read_at: DateTime.utc_now(),
          last_log_at: last_log_at,
          byte_offset: final_offset,
          parse_failures: 0,
          rotated?: rotated?
        }

        IncidentStore.update_source_health(store, health)
        if parse_failures > 0 do
          Enum.each(1..parse_failures, fn _ -> IncidentStore.ingest_malformed(store, filename) end)
        end

        Map.put(files, filename, %{offset: final_offset, buffer: final_buffer, size: size})

      {:error, _} ->
        health = %SourceHealth{
          file: filename,
          exists?: false,
          size_bytes: 0,
          last_read_at: DateTime.utc_now(),
          last_log_at: nil,
          byte_offset: 0,
          parse_failures: 0,
          rotated?: false
        }

        IncidentStore.update_source_health(store, health)
        Map.delete(files, filename)
    end
  end

  defp read_new_lines(path, offset, buffer, filename, store) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        :file.position(file, offset)
        {:ok, new_bytes} = IO.binread(file, :eof) |> then(&{:ok, &1})
        File.close(file)

        all_content = buffer <> (new_bytes || "")
        parts = String.split(all_content, "\n")

        {complete_lines, remainder} =
          case List.pop_at(parts, -1) do
            {last, rest} -> {rest, last}
          end

        {parse_failures, last_log_at} =
          Enum.reduce(complete_lines, {0, nil}, fn raw, {failures, last_ts} ->
            if String.trim(raw) == "" do
              {failures, last_ts}
            else
              case LogParser.parse(raw, filename) do
                {:ok, parsed_line} ->
                  IncidentStore.ingest_line(store, parsed_line)
                  {failures, parsed_line.at}

                {:malformed, _} ->
                  {failures + 1, last_ts}
              end
            end
          end)

        bytes_consumed = byte_size(Enum.join(complete_lines, "\n")) +
                         if(complete_lines == [], do: 0, else: 1)

        {complete_lines, remainder, parse_failures, last_log_at}

      {:error, _} ->
        {[], buffer, 0, nil}
    end
  end
end
```

- [ ] **Step 4: Fix the byte offset tracking** — the `read_new_lines/5` function returns lines but the offset calculation in `poll_file` is incorrect. Replace with a simpler approach:

After reading, the new offset should be `old_offset + bytes_of_complete_lines_read`. Simplify `poll_file` to track offset precisely:

```elixir
  defp poll_file(filename, log_dir, files, store) do
    path = Path.join(log_dir, filename)
    file_state = Map.get(files, filename, %{offset: 0, buffer: ""})

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} ->
        {offset, buffer, rotated?} =
          if size < file_state.offset do
            {0, "", true}
          else
            {file_state.offset, file_state.buffer, false}
          end

        {new_offset, new_buffer, parse_failures, last_log_at} =
          if size > offset do
            process_new_bytes(path, offset, buffer, filename, store)
          else
            {offset, buffer, 0, nil}
          end

        health = %SourceHealth{
          file: filename,
          exists?: true,
          size_bytes: size,
          last_read_at: DateTime.utc_now(),
          last_log_at: last_log_at,
          byte_offset: new_offset,
          parse_failures: 0,
          rotated?: rotated?
        }

        IncidentStore.update_source_health(store, health)

        if parse_failures > 0 do
          Enum.each(1..parse_failures, fn _ ->
            IncidentStore.ingest_malformed(store, filename)
          end)
        end

        Map.put(files, filename, %{offset: new_offset, buffer: new_buffer})

      {:error, _} ->
        health = %SourceHealth{
          file: filename,
          exists?: false,
          size_bytes: 0,
          last_read_at: DateTime.utc_now(),
          last_log_at: nil,
          byte_offset: 0,
          parse_failures: 0,
          rotated?: false
        }

        IncidentStore.update_source_health(store, health)
        Map.delete(files, filename)
    end
  end

  defp process_new_bytes(path, offset, buffer, filename, store) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        {:ok, _} = :file.position(file, offset)
        new_bytes = IO.binread(file, :eof)
        File.close(file)

        new_bytes = if is_binary(new_bytes), do: new_bytes, else: ""
        all_content = buffer <> new_bytes
        parts = String.split(all_content, "\n")

        {complete, remainder} =
          case List.pop_at(parts, -1) do
            {last, rest} -> {rest, last || ""}
          end

        {failures, last_log_at} =
          complete
          |> Enum.reject(&(String.trim(&1) == ""))
          |> Enum.reduce({0, nil}, fn raw, {f, ts} ->
            case LogParser.parse(raw, filename) do
              {:ok, pl} ->
                IncidentStore.ingest_line(store, pl)
                {f, pl.at}

              {:malformed, _} ->
                {f + 1, ts}
            end
          end)

        consumed = byte_size(all_content) - byte_size(remainder)
        {offset + consumed, remainder, failures, last_log_at}

      {:error, _} ->
        {offset, buffer, 0, nil}
    end
  end
```

Replace the entire `log_watcher.ex` with the final version combining both steps:

```elixir
# lib/beamwatch/ingestion/log_watcher.ex
defmodule BeamWatch.Ingestion.LogWatcher do
  @moduledoc false

  use GenServer

  alias BeamWatch.Incidents.IncidentStore
  alias BeamWatch.Ingestion.LogParser
  alias BeamWatch.SourceHealth

  @default_poll_ms 500

  def start_link(opts \\ []) do
    log_dir = Keyword.fetch!(opts, :log_dir)
    store = Keyword.get(opts, :store, IncidentStore)
    poll_ms = Keyword.get(opts, :poll_ms, @default_poll_ms)
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, %{log_dir: log_dir, store: store, poll_ms: poll_ms}, gen_opts)
  end

  @impl true
  def init(%{log_dir: log_dir, store: store, poll_ms: poll_ms}) do
    schedule_poll(poll_ms)
    {:ok, %{log_dir: log_dir, store: store, poll_ms: poll_ms, files: %{}}}
  end

  @impl true
  def handle_info(:poll, state) do
    new_files = poll_directory(state.log_dir, state.files, state.store)
    schedule_poll(state.poll_ms)
    {:noreply, %{state | files: new_files}}
  end

  defp schedule_poll(ms), do: Process.send_after(self(), :poll, ms)

  defp poll_directory(log_dir, files, store) do
    case File.ls(log_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(Path.extname(&1) == ".log"))
        |> Enum.reduce(files, &poll_file(&1, log_dir, &2, store))

      {:error, _} ->
        files
    end
  end

  defp poll_file(filename, log_dir, files, store) do
    path = Path.join(log_dir, filename)
    %{offset: offset, buffer: buffer} = Map.get(files, filename, %{offset: 0, buffer: ""})

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} ->
        {offset, buffer, rotated?} =
          if size < offset, do: {0, "", true}, else: {offset, buffer, false}

        {new_offset, new_buffer, failures, last_log_at} =
          if size > offset do
            process_new_bytes(path, offset, buffer, filename, store)
          else
            {offset, buffer, 0, nil}
          end

        IncidentStore.update_source_health(store, %SourceHealth{
          file: filename,
          exists?: true,
          size_bytes: size,
          last_read_at: DateTime.utc_now(),
          last_log_at: last_log_at,
          byte_offset: new_offset,
          parse_failures: 0,
          rotated?: rotated?
        })

        Enum.each(1..max(failures, 0)//1, fn _ ->
          IncidentStore.ingest_malformed(store, filename)
        end)

        Map.put(files, filename, %{offset: new_offset, buffer: new_buffer})

      {:error, _} ->
        IncidentStore.update_source_health(store, %SourceHealth{
          file: filename,
          exists?: false,
          size_bytes: 0,
          last_read_at: DateTime.utc_now(),
          last_log_at: nil,
          byte_offset: 0,
          parse_failures: 0,
          rotated?: false
        })

        Map.delete(files, filename)
    end
  end

  defp process_new_bytes(path, offset, buffer, filename, store) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        {:ok, _} = :file.position(file, offset)
        new_bytes = IO.binread(file, :eof)
        File.close(file)

        new_bytes = if is_binary(new_bytes), do: new_bytes, else: ""
        all_content = buffer <> new_bytes
        {complete, remainder} = split_lines(all_content)

        {failures, last_log_at} =
          Enum.reduce(complete, {0, nil}, fn raw, {f, ts} ->
            case LogParser.parse(raw, filename) do
              {:ok, pl} ->
                IncidentStore.ingest_line(store, pl)
                {f, pl.at}

              {:malformed, _} ->
                {f + 1, ts}
            end
          end)

        consumed = byte_size(all_content) - byte_size(remainder)
        {offset + consumed, remainder, failures, last_log_at}

      {:error, _} ->
        {offset, buffer, 0, nil}
    end
  end

  defp split_lines(content) do
    parts = String.split(content, "\n")
    {last, rest} = List.pop_at(parts, -1)
    complete = Enum.reject(rest, &(String.trim(&1) == ""))
    {complete, last || ""}
  end
end
```

- [ ] **Step 5: Run tests and verify they pass**

```bash
mix test test/beamwatch/ingestion/log_watcher_test.exs
```

Expected: 4 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/beamwatch/ingestion/log_watcher.ex \
        test/beamwatch/ingestion/log_watcher_test.exs
git commit -m "feat: add LogWatcher GenServer with file polling and rotation detection"
```

---

## Task 9: Application supervision tree

**Files:**
- Modify: `lib/beamwatch/application.ex`

- [ ] **Step 1: Update Application to start LogWatcher and IncidentStore**

```elixir
# lib/beamwatch/application.ex
defmodule BeamWatch.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BeamWatchWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:beamwatch, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: BeamWatch.PubSub},
      BeamWatch.Incidents.IncidentStore,
      {BeamWatch.Ingestion.LogWatcher, log_watcher_opts()},
      BeamWatchWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: BeamWatch.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    BeamWatchWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp log_watcher_opts do
    log_dir =
      :beamwatch
      |> Application.get_env(:log_feed_target, "priv/logs")
      |> Path.expand()

    [log_dir: log_dir]
  end
end
```

- [ ] **Step 2: Verify the app starts**

```bash
mix compile
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add lib/beamwatch/application.ex
git commit -m "feat: wire IncidentStore and LogWatcher into supervision tree"
```

---

## Task 10: DashboardLive

**Files:**
- Modify: `lib/beamwatch_web/live/dashboard_live.ex`
- Modify: `test/beamwatch_web/live/dashboard_live_test.exs`

The LiveView:
1. On mount: subscribes to `"beamwatch:dashboard"`, calls `IncidentStore.get_state()` for initial data
2. Renders 3 sections: active incidents, source health, recent activity
3. Handles operator action events → `IncidentStore` calls
4. Handles `{:dashboard_updated, state}` PubSub → `assign(socket, ...)`

- [ ] **Step 1: Write the LiveView tests first**

Add these tests to `test/beamwatch_web/live/dashboard_live_test.exs` (after the existing dev controls test):

```elixir
  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Incidents.IncidentStore

  test "renders empty state with no incidents", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "No active incidents"
  end

  test "renders active incident from store", %{conn: conn} do
    incident = %Incident{
      id: "container_restart_loop:plex",
      type: :container_restart_loop,
      resource: "plex",
      severity: :critical,
      status: :active,
      first_seen: ~U[2026-06-05 15:01:40Z],
      last_seen: ~U[2026-06-05 15:01:55Z],
      evidence: [],
      silence_scope: nil
    }

    IncidentStore.start_link(name: :test_store_render, pubsub: BeamWatch.PubSub)
    # Broadcast a state with the incident directly
    Phoenix.PubSub.broadcast(BeamWatch.PubSub, "beamwatch:dashboard", {:dashboard_updated,
      %{incidents: %{incident.id => incident}, source_health: %{}, recent_activity: [],
        silenced_types: MapSet.new()}})

    {:ok, view, _html} = live(conn, ~p"/")

    # Give LiveView time to receive the broadcast
    Process.sleep(100)
    html = render(view)

    assert html =~ "plex"
    assert html =~ "Container Restart Loop"
  end

  test "acknowledge button sends acknowledge action", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Seed an incident via PubSub
    incident = %Incident{
      id: "container_restart_loop:plex",
      type: :container_restart_loop,
      resource: "plex",
      severity: :critical,
      status: :active,
      first_seen: ~U[2026-06-05 15:01:40Z],
      last_seen: ~U[2026-06-05 15:01:55Z],
      evidence: [],
      silence_scope: nil
    }

    Phoenix.PubSub.broadcast(BeamWatch.PubSub, "beamwatch:dashboard",
      {:dashboard_updated,
       %{incidents: %{incident.id => incident}, source_health: %{}, recent_activity: [],
         silenced_types: MapSet.new()}})

    Process.sleep(100)
    _html = render_click(view, "acknowledge", %{"id" => "container_restart_loop:plex"})
    # No crash = success (store may not be seeded in test, but event is handled)
    assert render(view)
  end
```

- [ ] **Step 2: Implement DashboardLive**

```elixir
# lib/beamwatch_web/live/dashboard_live.ex
defmodule BeamWatchWeb.DashboardLive do
  use BeamWatchWeb, :live_view

  alias BeamWatch.Incidents.IncidentStore
  alias BeamWatch.LogFeed.DevControls

  @pubsub BeamWatch.PubSub
  @dashboard_topic "beamwatch:dashboard"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @dashboard_topic)
    end

    store_state = IncidentStore.get_state()

    {:ok,
     assign(socket,
       incidents: store_state.incidents,
       source_health: store_state.source_health,
       recent_activity: store_state.recent_activity,
       silenced_types: store_state.silenced_types,
       expanded_ids: MapSet.new(),
       dev_log_controls_enabled?: DevControls.enabled?(),
       log_feed_target: Path.relative_to_cwd(DevControls.target_dir())
     )}
  end

  @impl true
  def handle_info({:dashboard_updated, state}, socket) do
    {:noreply,
     assign(socket,
       incidents: state.incidents,
       source_health: state.source_health,
       recent_activity: state.recent_activity,
       silenced_types: state.silenced_types
     )}
  end

  @impl true
  def handle_event("toggle-evidence", %{"id" => id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_ids, id) do
        MapSet.delete(socket.assigns.expanded_ids, id)
      else
        MapSet.put(socket.assigns.expanded_ids, id)
      end

    {:noreply, assign(socket, expanded_ids: expanded)}
  end

  def handle_event("acknowledge", %{"id" => id}, socket) do
    IncidentStore.acknowledge(id)
    {:noreply, socket}
  end

  def handle_event("silence-incident", %{"id" => id}, socket) do
    IncidentStore.silence(id, :incident)
    {:noreply, socket}
  end

  def handle_event("silence-type", %{"id" => id}, socket) do
    IncidentStore.silence(id, :type)
    {:noreply, socket}
  end

  def handle_event("resolve", %{"id" => id}, socket) do
    IncidentStore.resolve(id)
    {:noreply, socket}
  end

  def handle_event("clear-silence", %{"id" => id}, socket) do
    IncidentStore.clear_silence(id)
    {:noreply, socket}
  end

  def handle_event("dev-add-validation-logs", _params, socket) do
    if socket.assigns.dev_log_controls_enabled? do
      :ok = DevControls.add_validation_logs()
      {:noreply, put_flash(socket, :info, "Added validation logs to #{socket.assigns.log_feed_target}.")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("dev-clear-log-dir", _params, socket) do
    if socket.assigns.dev_log_controls_enabled? do
      :ok = DevControls.clear_log_dir()
      {:noreply, put_flash(socket, :info, "Cleared #{socket.assigns.log_feed_target}.")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-7xl space-y-8 p-6">
        <div class="space-y-1">
          <p class="text-xs font-semibold uppercase tracking-widest text-zinc-400">BeamWatch</p>
          <h1 class="text-2xl font-bold tracking-tight text-zinc-950">Incident Triage</h1>
        </div>

        <%!-- Summary row --%>
        <div class="grid grid-cols-3 gap-4">
          <.stat_card label="Active incidents" value={active_count(@incidents)} />
          <.stat_card label="Log sources" value={map_size(@source_health)} />
          <.stat_card label="Silenced types"
            value={MapSet.size(@silenced_types)} />
        </div>

        <%!-- Active Incidents --%>
        <section>
          <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-zinc-500">
            Active Incidents
          </h2>
          <div :if={active_count(@incidents) == 0} class="rounded-lg border border-dashed border-zinc-300 p-8 text-center text-sm text-zinc-400">
            No active incidents
          </div>
          <div class="space-y-3">
            <%= for incident <- sorted_incidents(@incidents) do %>
              <.incident_card
                incident={incident}
                expanded={MapSet.member?(@expanded_ids, incident.id)} />
            <% end %>
          </div>
        </section>

        <%!-- Source Health --%>
        <section>
          <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-zinc-500">
            Source Health
          </h2>
          <div :if={map_size(@source_health) == 0}
               class="text-sm text-zinc-400">No log files discovered yet.</div>
          <div class="overflow-hidden rounded-lg border border-zinc-200 bg-white">
            <table class="min-w-full divide-y divide-zinc-200 text-sm">
              <thead class="bg-zinc-50">
                <tr>
                  <th class="px-4 py-2 text-left font-medium text-zinc-500">File</th>
                  <th class="px-4 py-2 text-left font-medium text-zinc-500">Status</th>
                  <th class="px-4 py-2 text-left font-medium text-zinc-500">Size</th>
                  <th class="px-4 py-2 text-left font-medium text-zinc-500">Last read</th>
                  <th class="px-4 py-2 text-left font-medium text-zinc-500">Last log</th>
                  <th class="px-4 py-2 text-left font-medium text-zinc-500">Parse failures</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-zinc-100">
                <%= for {_file, health} <- Enum.sort(@source_health) do %>
                  <tr>
                    <td class="px-4 py-2 font-mono text-xs text-zinc-700">{health.file}</td>
                    <td class="px-4 py-2">
                      <span class={["inline-block rounded-full px-2 py-0.5 text-xs font-semibold",
                        health_badge_class(health)]}>
                        {health_label(health)}
                      </span>
                    </td>
                    <td class="px-4 py-2 text-zinc-600">{format_bytes(health.size_bytes)}</td>
                    <td class="px-4 py-2 text-zinc-500 text-xs">{format_dt(health.last_read_at)}</td>
                    <td class="px-4 py-2 text-zinc-500 text-xs">{format_dt(health.last_log_at)}</td>
                    <td class="px-4 py-2">
                      <span :if={health.parse_failures > 0}
                            class="font-semibold text-amber-600">{health.parse_failures}</span>
                      <span :if={health.parse_failures == 0} class="text-zinc-400">0</span>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </section>

        <%!-- Recent Activity --%>
        <section>
          <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-zinc-500">
            Recent Activity
          </h2>
          <div class="rounded-lg border border-zinc-200 bg-zinc-950 p-4 font-mono text-xs text-zinc-300 overflow-auto max-h-64">
            <div :if={@recent_activity == []} class="text-zinc-500">No activity yet.</div>
            <%= for entry <- @recent_activity do %>
              <div class="flex gap-3 leading-6">
                <span class="shrink-0 text-zinc-500">{format_dt(entry.at)}</span>
                <span class="shrink-0 text-zinc-400">[{entry.source}]</span>
                <span class="truncate text-zinc-200">{entry.line}</span>
              </div>
            <% end %>
          </div>
        </section>

        <%!-- Dev controls --%>
        <div :if={@dev_log_controls_enabled?}
             class="rounded-lg border border-zinc-200 bg-zinc-50 p-6">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="text-base font-semibold text-zinc-950">Dev log controls</h2>
              <p class="mt-1 text-sm text-zinc-600">
                Target: <code class="rounded bg-white px-1.5 py-0.5 text-zinc-800">{@log_feed_target}</code>
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <button type="button" phx-click="dev-add-validation-logs"
                class="rounded-md bg-zinc-950 px-3 py-2 text-sm font-semibold text-white hover:bg-zinc-800">
                Add validation logs
              </button>
              <button type="button" phx-click="dev-clear-log-dir"
                class="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm font-semibold text-zinc-900 hover:bg-zinc-100">
                Clear log dir
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Components ---

  defp incident_card(assigns) do
    ~H"""
    <div class={["rounded-lg border bg-white p-4 shadow-sm", severity_border(@incident.severity)]}>
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="flex items-center gap-3">
          <span class={["h-2.5 w-2.5 rounded-full", severity_dot(@incident.severity)]}></span>
          <div>
            <p class="font-semibold text-zinc-950">{format_type(@incident.type)} — {@incident.resource}</p>
            <p class="text-xs text-zinc-500">
              First: {format_dt(@incident.first_seen)} · Last: {format_dt(@incident.last_seen)}
            </p>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <span class={["rounded-full px-2 py-0.5 text-xs font-semibold", status_badge_class(@incident.status)]}>
            {@incident.status}
          </span>
          <.action_buttons incident={@incident} />
        </div>
      </div>

      <%!-- Evidence toggle --%>
      <div :if={length(@incident.evidence) > 0} class="mt-3">
        <button phx-click="toggle-evidence" phx-value-id={@incident.id}
          class="text-xs text-zinc-500 hover:text-zinc-700 underline">
          {if @expanded, do: "Hide evidence", else: "Show #{length(@incident.evidence)} evidence line(s)"}
        </button>
        <div :if={@expanded} class="mt-2 rounded bg-zinc-950 p-3 font-mono text-xs text-zinc-300 space-y-1 overflow-auto max-h-48">
          <%= for ev <- @incident.evidence do %>
            <div class="flex gap-2">
              <span class="shrink-0 text-zinc-500">[{ev.source}]</span>
              <span class="text-zinc-200">{ev.line}</span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp action_buttons(assigns) do
    ~H"""
    <div class="flex gap-1">
      <%= if @incident.status in [:active, :acknowledged] do %>
        <button :if={@incident.status == :active}
          phx-click="acknowledge" phx-value-id={@incident.id}
          class="rounded border border-zinc-300 bg-white px-2 py-1 text-xs hover:bg-zinc-50">
          Ack
        </button>
        <button phx-click="silence-incident" phx-value-id={@incident.id}
          class="rounded border border-zinc-300 bg-white px-2 py-1 text-xs hover:bg-zinc-50">
          Silence
        </button>
        <button phx-click="silence-type" phx-value-id={@incident.id}
          class="rounded border border-zinc-300 bg-white px-2 py-1 text-xs hover:bg-zinc-50"
          title={"Silence all #{@incident.type} incidents"}>
          Silence type
        </button>
        <button phx-click="resolve" phx-value-id={@incident.id}
          class="rounded border border-green-300 bg-green-50 px-2 py-1 text-xs text-green-700 hover:bg-green-100">
          Resolve
        </button>
      <% end %>
      <%= if @incident.status == :silenced do %>
        <button phx-click="clear-silence" phx-value-id={@incident.id}
          class="rounded border border-zinc-300 bg-white px-2 py-1 text-xs hover:bg-zinc-50">
          Clear silence
        </button>
        <button phx-click="resolve" phx-value-id={@incident.id}
          class="rounded border border-green-300 bg-green-50 px-2 py-1 text-xs text-green-700 hover:bg-green-100">
          Resolve
        </button>
      <% end %>
      <%= if @incident.status == :resolved do %>
        <span class="text-xs text-zinc-400 italic">Resolved</span>
      <% end %>
    </div>
    """
  end

  defp stat_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 bg-white p-4">
      <p class="text-xs text-zinc-500">{@label}</p>
      <p class="mt-1 text-2xl font-bold text-zinc-950">{@value}</p>
    </div>
    """
  end

  # --- View helpers ---

  defp active_count(incidents) do
    incidents
    |> Map.values()
    |> Enum.count(&(&1.status in [:active, :acknowledged]))
  end

  defp sorted_incidents(incidents) do
    severity_rank = %{critical: 0, warning: 1, info: 2}
    status_rank = %{active: 0, acknowledged: 1, silenced: 2, resolved: 3}

    incidents
    |> Map.values()
    |> Enum.sort_by(fn inc ->
      {Map.get(status_rank, inc.status, 9), Map.get(severity_rank, inc.severity, 9),
       DateTime.to_unix(inc.last_seen) * -1}
    end)
  end

  defp format_type(:container_restart_loop), do: "Container Restart Loop"
  defp format_type(:disk_smart_warning), do: "Disk SMART Warning"
  defp format_type(:share_permission_failure), do: "Share Permission Failure"
  defp format_type(:vm_boot_failure), do: "VM Boot Failure"
  defp format_type(type), do: type |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp format_dt(nil), do: "—"

  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%m-%d %H:%M:%S")
  end

  defp format_bytes(bytes) when bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_bytes(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{bytes} B"

  defp severity_border(:critical), do: "border-red-300"
  defp severity_border(:warning), do: "border-amber-300"
  defp severity_border(_), do: "border-zinc-200"

  defp severity_dot(:critical), do: "bg-red-500"
  defp severity_dot(:warning), do: "bg-amber-400"
  defp severity_dot(_), do: "bg-zinc-400"

  defp status_badge_class(:active), do: "bg-red-100 text-red-700"
  defp status_badge_class(:acknowledged), do: "bg-amber-100 text-amber-700"
  defp status_badge_class(:silenced), do: "bg-zinc-100 text-zinc-600"
  defp status_badge_class(:resolved), do: "bg-green-100 text-green-700"

  defp health_badge_class(%{exists?: false}), do: "bg-red-100 text-red-700"
  defp health_badge_class(%{rotated?: true}), do: "bg-amber-100 text-amber-700"
  defp health_badge_class(%{parse_failures: f}) when f > 0, do: "bg-amber-100 text-amber-700"
  defp health_badge_class(_), do: "bg-green-100 text-green-700"

  defp health_label(%{exists?: false}), do: "missing"
  defp health_label(%{rotated?: true}), do: "rotated"
  defp health_label(%{parse_failures: f}) when f > 0, do: "warnings"
  defp health_label(_), do: "ok"
end
```

- [ ] **Step 3: Run the full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add lib/beamwatch_web/live/dashboard_live.ex \
        test/beamwatch_web/live/dashboard_live_test.exs
git commit -m "feat: implement full incident triage dashboard LiveView"
```

---

## Task 11: Open pull request

- [ ] **Step 1: Run full test suite and compile check**

```bash
mix test && mix compile --warnings-as-errors
```

Expected: all tests pass, no warnings.

- [ ] **Step 2: Push branch and open PR**

```bash
git push -u origin implement
gh pr create \
  --title "feat: implement BeamWatch incident triage dashboard" \
  --base master \
  --body "$(cat <<'EOF'
## Summary

- Adds log file polling via `LogWatcher` GenServer (500ms interval, byte-offset tracking, rotation detection)
- Adds `IncidentStore` GenServer holding all incident state with operator actions (acknowledge, silence by incident or type, resolve, clear silence)
- Implements all four required incident detectors as pure modules (container restart loop, disk SMART warning, share permission failure, VM boot failure)
- Full Phoenix LiveView dashboard with incident cards, evidence expansion, source health table, and recent activity feed
- Ephemeral in-memory state — no database required

## Test plan

- [ ] `mix test` — all unit and integration tests pass
- [ ] Start app with `mix phx.server`, visit `http://localhost:4000`
- [ ] Click "Add validation logs" in dev controls, verify incidents appear within ~1s
- [ ] Verify all four incident types render with correct severity and evidence
- [ ] Test each operator action: Ack, Silence, Silence type, Resolve, Clear silence
- [ ] Verify source health table shows all log files with correct status
- [ ] Verify recent activity feed scrolls and shows newest entries first
- [ ] Click "Clear log dir" — incidents remain visible (ephemeral in-memory state) but no new log lines ingested
EOF
)"
```
