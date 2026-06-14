defmodule BeamWatchWeb.DashboardLive.Index do
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

    {:ok,
     assign(socket,
       store_state: IncidentStore.get_state(),
       expanded_ids: MapSet.new(),
       dev_log_controls_enabled?: DevControls.enabled?(),
       log_feed_target: Path.relative_to_cwd(DevControls.target_dir())
     )}
  end

  @impl true
  def handle_info({:dashboard_updated, store_state}, socket) do
    {:noreply, assign(socket, store_state: store_state)}
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

  def handle_event("clear-type-silence", %{"type" => type}, socket) do
    IncidentStore.clear_type_silence(String.to_existing_atom(type))
    {:noreply, socket}
  end

  def handle_event("dev-add-validation-logs", _params, socket) do
    if socket.assigns.dev_log_controls_enabled? do
      :ok = DevControls.add_validation_logs()

      {:noreply,
       put_flash(socket, :info, "Added validation logs to #{socket.assigns.log_feed_target}.")}
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

  # --- Components ---

  defp incident_card(assigns) do
    ~H"""
    <div class={["rounded-lg border bg-white p-4 shadow-sm", severity_border(@incident.severity)]}>
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="flex items-center gap-3">
          <span class={["h-2.5 w-2.5 shrink-0 rounded-full", severity_dot(@incident.severity)]}>
          </span>
          <div>
            <p class="font-semibold text-zinc-950">
              {format_type(@incident.type)} — {@incident.resource}
            </p>
            <p class="text-xs text-zinc-500">
              First: {format_dt(@incident.first_seen)} · Last: {format_dt(@incident.last_seen)}
            </p>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <span class={[
            "rounded-full px-2 py-0.5 text-xs font-semibold",
            status_badge_class(@incident.status)
          ]}>
            {@incident.status}
          </span>
          <.action_buttons incident={@incident} />
        </div>
      </div>

      <div :if={length(@incident.evidence) > 0} class="mt-3">
        <button
          phx-click="toggle-evidence"
          phx-value-id={@incident.id}
          class="text-xs text-zinc-500 underline hover:text-zinc-700"
        >
          {if @expanded,
            do: "Hide evidence",
            else: "Show #{length(@incident.evidence)} evidence line(s)"}
        </button>
        <div
          :if={@expanded}
          class="mt-2 max-h-48 overflow-auto rounded bg-zinc-950 p-3 font-mono text-xs text-zinc-300"
        >
          <%= for ev <- Enum.reverse(@incident.evidence) do %>
            <div class="flex gap-2 leading-6">
              <span class="shrink-0 text-zinc-500">{format_dt(ev.at)}</span>
              <span class="shrink-0 text-zinc-400">[{ev.source}]</span>
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
    <div class="flex flex-wrap gap-1">
      <%= if @incident.status in [:active, :acknowledged] do %>
        <button
          :if={@incident.status == :active}
          phx-click="acknowledge"
          phx-value-id={@incident.id}
          class="rounded border border-zinc-300 bg-white px-2 py-1 text-xs hover:bg-zinc-50"
        >
          Ack
        </button>
        <button
          phx-click="silence-incident"
          phx-value-id={@incident.id}
          class="rounded border border-zinc-300 bg-white px-2 py-1 text-xs hover:bg-zinc-50"
        >
          Silence
        </button>
        <button
          phx-click="silence-type"
          phx-value-id={@incident.id}
          title={"Silence all #{@incident.type} incidents"}
          class="rounded border border-zinc-300 bg-white px-2 py-1 text-xs hover:bg-zinc-50"
        >
          Silence type
        </button>
        <button
          phx-click="resolve"
          phx-value-id={@incident.id}
          class="rounded border border-green-300 bg-green-50 px-2 py-1 text-xs text-green-700 hover:bg-green-100"
        >
          Resolve
        </button>
      <% end %>
      <%= if @incident.status == :silenced do %>
        <span class="text-xs italic text-zinc-400">
          {if @incident.silence_scope == :type, do: "Type silenced", else: "Silenced"}
        </span>
        <button
          phx-click="clear-silence"
          phx-value-id={@incident.id}
          class="rounded border border-zinc-300 bg-white px-2 py-1 text-xs hover:bg-zinc-50"
        >
          Clear silence
        </button>
        <button
          phx-click="resolve"
          phx-value-id={@incident.id}
          class="rounded border border-green-300 bg-green-50 px-2 py-1 text-xs text-green-700 hover:bg-green-100"
        >
          Resolve
        </button>
      <% end %>
      <%= if @incident.status == :resolved do %>
        <span class="text-xs italic text-zinc-400">Resolved</span>
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

  defp format_type(type),
    do: type |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp format_dt(nil), do: "—"

  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%m-%d %H:%M:%S")
  end

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
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
