defmodule BeamWatch.Incidents.StoreState do
  @moduledoc false

  alias BeamWatch.Incidents.Detectors.ContainerRestartLoop
  alias BeamWatch.Incidents.Detectors.DiskSmartWarning
  alias BeamWatch.Incidents.Detectors.SharePermissionFailure
  alias BeamWatch.Incidents.Detectors.VmBootFailure
  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingestion.ParsedLine
  alias BeamWatch.SourceHealth

  @detectors [
    {:container_restart_loop, ContainerRestartLoop},
    {:disk_smart_warning, DiskSmartWarning},
    {:share_permission_failure, SharePermissionFailure},
    {:vm_boot_failure, VmBootFailure}
  ]

  @max_activity 50

  @type t :: %__MODULE__{
          incidents: %{String.t() => Incident.t()},
          source_health: %{String.t() => SourceHealth.t()},
          recent_activity: [map()],
          silenced_types: MapSet.t(),
          detector_states: %{atom() => map()}
        }

  defstruct incidents: %{},
            source_health: %{},
            recent_activity: [],
            silenced_types: MapSet.new(),
            detector_states: %{}

  @spec new() :: t()
  def new do
    %__MODULE__{
      silenced_types: MapSet.new(),
      detector_states: Map.new(@detectors, fn {key, _mod} -> {key, %{}} end)
    }
  end

  @spec ingest_line(t(), ParsedLine.t()) :: t()
  def ingest_line(%__MODULE__{} = state, %ParsedLine{} = line) do
    activity = %{source: line.source, line: line.raw, at: line.at}
    recent = [activity | state.recent_activity] |> Enum.take(@max_activity)

    {incidents, detector_states} = run_detectors(line, state.incidents, state.detector_states)
    incidents = apply_type_silencing(incidents, state.silenced_types)

    %{state | incidents: incidents, recent_activity: recent, detector_states: detector_states}
  end

  @spec ingest_malformed(t(), String.t()) :: t()
  def ingest_malformed(%__MODULE__{} = state, source) do
    new_health =
      Map.update(
        state.source_health,
        source,
        %SourceHealth{file: source, parse_failures: 1},
        fn h -> %{h | parse_failures: h.parse_failures + 1} end
      )

    %{state | source_health: new_health}
  end

  @spec update_source_health(t(), SourceHealth.t()) :: t()
  def update_source_health(%__MODULE__{} = state, %SourceHealth{} = health) do
    current = Map.get(state.source_health, health.file, %SourceHealth{file: health.file})
    merged = %{health | parse_failures: current.parse_failures}
    %{state | source_health: Map.put(state.source_health, health.file, merged)}
  end

  @spec acknowledge(t(), String.t()) :: t()
  def acknowledge(%__MODULE__{} = state, id) do
    update_incident(state, id, &%{&1 | status: :acknowledged})
  end

  @spec silence_incident(t(), String.t()) :: t()
  def silence_incident(%__MODULE__{} = state, id) do
    update_incident(state, id, &%{&1 | status: :silenced, silence_scope: :incident})
  end

  @spec silence_type(t(), String.t()) :: t()
  def silence_type(%__MODULE__{} = state, id) do
    type = resolve_type(state.incidents, id)
    silenced_types = MapSet.put(state.silenced_types, type)
    incidents = Map.new(state.incidents, &silence_if_matching_type(&1, type))
    %{state | silenced_types: silenced_types, incidents: incidents}
  end

  @spec resolve(t(), String.t()) :: t()
  def resolve(%__MODULE__{} = state, id) do
    update_incident(state, id, &%{&1 | status: :resolved})
  end

  @spec clear_silence(t(), String.t()) :: t()
  def clear_silence(%__MODULE__{} = state, id) do
    case Map.get(state.incidents, id) do
      %Incident{silence_scope: :type, type: type} -> unsilence_type(state, type)
      _ -> update_incident(state, id, &%{&1 | status: :active, silence_scope: nil})
    end
  end

  @spec clear_type_silence(t(), atom()) :: t()
  def clear_type_silence(%__MODULE__{} = state, type) do
    unsilence_type(state, type)
  end

  @spec reset(t()) :: t()
  def reset(%__MODULE__{}) do
    new()
  end

  # --- Private helpers ---

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
      Map.new(incidents, &maybe_silence_by_type(&1, silenced_types))
    end
  end

  defp maybe_silence_by_type({k, inc}, silenced_types) do
    if MapSet.member?(silenced_types, inc.type) and inc.status == :active do
      {k, %{inc | status: :silenced, silence_scope: :type}}
    else
      {k, inc}
    end
  end

  defp silence_if_matching_type({k, inc}, type) do
    if inc.type == type and inc.status in [:active, :acknowledged] do
      {k, %{inc | status: :silenced, silence_scope: :type}}
    else
      {k, inc}
    end
  end

  defp resolve_type(incidents, id) do
    case Map.get(incidents, id) do
      %Incident{type: type} -> type
      nil -> id |> String.split(":") |> hd() |> String.to_existing_atom()
    end
  end

  defp update_incident(state, id, fun) do
    case Map.get(state.incidents, id) do
      nil -> state
      inc -> %{state | incidents: Map.put(state.incidents, id, fun.(inc))}
    end
  end

  defp unsilence_type(state, type) do
    incidents =
      Map.new(state.incidents, fn {k, inc} ->
        if inc.type == type and inc.silence_scope == :type do
          {k, %{inc | status: :active, silence_scope: nil}}
        else
          {k, inc}
        end
      end)

    %{state | silenced_types: MapSet.delete(state.silenced_types, type), incidents: incidents}
  end
end
