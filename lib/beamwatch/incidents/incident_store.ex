defmodule BeamWatch.Incidents.IncidentStore do
  @moduledoc false

  use GenServer

  alias BeamWatch.Incidents.StoreState
  alias BeamWatch.Ingestion.ParsedLine
  alias BeamWatch.SourceHealth

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

  @spec get_state(GenServer.server()) :: StoreState.t()
  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  @spec acknowledge(GenServer.server(), String.t()) :: :ok
  def acknowledge(server \\ __MODULE__, id) do
    GenServer.call(server, {:acknowledge, id})
  end

  @spec silence(GenServer.server(), String.t(), :incident | :type) :: :ok
  def silence(server \\ __MODULE__, id, scope) do
    GenServer.call(server, {:silence, id, scope})
  end

  @spec resolve(GenServer.server(), String.t()) :: :ok
  def resolve(server \\ __MODULE__, id) do
    GenServer.call(server, {:resolve, id})
  end

  @spec clear_silence(GenServer.server(), String.t()) :: :ok
  def clear_silence(server \\ __MODULE__, id) do
    GenServer.call(server, {:clear_silence, id})
  end

  @spec clear_type_silence(GenServer.server(), atom()) :: :ok
  def clear_type_silence(server \\ __MODULE__, type) do
    GenServer.call(server, {:clear_type_silence, type})
  end

  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(%{pubsub: pubsub}) do
    {:ok, %{pubsub: pubsub, data: StoreState.new()}}
  end

  @impl true
  def handle_cast({:ingest_line, %ParsedLine{} = line}, state) do
    {:noreply, mutate(state, StoreState.ingest_line(state.data, line))}
  end

  @impl true
  def handle_cast({:ingest_malformed, source}, state) do
    {:noreply, mutate(state, StoreState.ingest_malformed(state.data, source))}
  end

  @impl true
  def handle_cast({:update_source_health, %SourceHealth{} = health}, state) do
    {:noreply, mutate(state, StoreState.update_source_health(state.data, health))}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.data, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, mutate(state, StoreState.reset(state.data))}
  end

  @impl true
  def handle_call({:acknowledge, id}, _from, state) do
    {:reply, :ok, mutate(state, StoreState.acknowledge(state.data, id))}
  end

  @impl true
  def handle_call({:silence, id, :type}, _from, state) do
    {:reply, :ok, mutate(state, StoreState.silence_type(state.data, id))}
  end

  @impl true
  def handle_call({:silence, id, :incident}, _from, state) do
    {:reply, :ok, mutate(state, StoreState.silence_incident(state.data, id))}
  end

  @impl true
  def handle_call({:resolve, id}, _from, state) do
    {:reply, :ok, mutate(state, StoreState.resolve(state.data, id))}
  end

  @impl true
  def handle_call({:clear_silence, id}, _from, state) do
    {:reply, :ok, mutate(state, StoreState.clear_silence(state.data, id))}
  end

  @impl true
  def handle_call({:clear_type_silence, type}, _from, state) do
    {:reply, :ok, mutate(state, StoreState.clear_type_silence(state.data, type))}
  end

  # --- Private helpers ---

  defp mutate(state, new_data) do
    Phoenix.PubSub.broadcast(state.pubsub, "beamwatch:dashboard", {:dashboard_updated, new_data})
    %{state | data: new_data}
  end
end
