defmodule BeamWatchWeb.DashboardLive.Index do
  use BeamWatchWeb, :live_view

  import BeamWatchWeb.DashboardLive.Components

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
    type
    |> String.to_existing_atom()
    |> IncidentStore.clear_type_silence()

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
      :ok = IncidentStore.reset()
      {:noreply, put_flash(socket, :info, "Cleared #{socket.assigns.log_feed_target}.")}
    else
      {:noreply, socket}
    end
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

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_bytes(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{bytes} B"

  defp health_badge_class(%{exists?: false}), do: "bg-red-100 text-red-700"
  defp health_badge_class(%{rotated?: true}), do: "bg-amber-100 text-amber-700"
  defp health_badge_class(%{parse_failures: f}) when f > 0, do: "bg-amber-100 text-amber-700"
  defp health_badge_class(_), do: "bg-green-100 text-green-700"

  defp health_label(%{exists?: false}), do: "missing"
  defp health_label(%{rotated?: true}), do: "rotated"
  defp health_label(%{parse_failures: f}) when f > 0, do: "warnings"
  defp health_label(_), do: "ok"
end
