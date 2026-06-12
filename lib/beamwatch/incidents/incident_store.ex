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

  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
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

    new_state = %{
      state
      | incidents: incidents,
        recent_activity: recent_activity,
        detector_states: detector_states
    }

    broadcast(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:ingest_malformed, source}, state) do
    new_health =
      Map.update(
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
  def handle_call(:reset, _from, state) do
    clean = %{
      state
      | incidents: %{},
        source_health: %{},
        recent_activity: [],
        silenced_types: MapSet.new(),
        detector_states: Map.new(@detectors, fn {key, _mod} -> {key, %{}} end)
    }

    broadcast(clean)
    {:reply, :ok, clean}
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
        # Silence the type even without an existing incident
        type = id |> String.split(":") |> hd() |> String.to_existing_atom()
        silenced_types = MapSet.put(state.silenced_types, type)
        new_state = %{state | silenced_types: silenced_types}
        broadcast(new_state)
        {:reply, :ok, new_state}

      %Incident{type: type} ->
        silenced_types = MapSet.put(state.silenced_types, type)

        incidents =
          Map.new(state.incidents, fn {k, inc} ->
            if inc.type == type and inc.status in [:active, :acknowledged] do
              {k, %{inc | status: :silenced, silence_scope: :type}}
            else
              {k, inc}
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
      Map.new(incidents, fn {k, inc} ->
        if MapSet.member?(silenced_types, inc.type) and inc.status == :active do
          {k, %{inc | status: :silenced, silence_scope: :type}}
        else
          {k, inc}
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
