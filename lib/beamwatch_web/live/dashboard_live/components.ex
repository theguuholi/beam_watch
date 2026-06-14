defmodule BeamWatchWeb.DashboardLive.Components do
  use Phoenix.Component

  def incident_card(assigns) do
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
          <div :for={ev <- Enum.reverse(@incident.evidence)} class="flex gap-2 leading-6">
            <span class="shrink-0 text-zinc-500">{format_dt(ev.at)}</span>
            <span class="shrink-0 text-zinc-400">[{ev.source}]</span>
            <span class="text-zinc-200">{ev.line}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def action_buttons(assigns) do
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

  def stat_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 bg-white p-4">
      <p class="text-xs text-zinc-500">{@label}</p>
      <p class="mt-1 text-2xl font-bold text-zinc-950">{@value}</p>
    </div>
    """
  end

  def format_type(:container_restart_loop), do: "Container Restart Loop"
  def format_type(:disk_smart_warning), do: "Disk SMART Warning"
  def format_type(:share_permission_failure), do: "Share Permission Failure"
  def format_type(:vm_boot_failure), do: "VM Boot Failure"

  def format_type(type),
    do: type |> to_string() |> String.replace("_", " ") |> String.capitalize()

  def format_dt(nil), do: "—"

  def format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%m-%d %H:%M:%S")
  end

  def severity_border(:critical), do: "border-red-300"
  def severity_border(:warning), do: "border-amber-300"
  def severity_border(_), do: "border-zinc-200"

  def severity_dot(:critical), do: "bg-red-500"
  def severity_dot(:warning), do: "bg-amber-400"
  def severity_dot(_), do: "bg-zinc-400"

  def status_badge_class(:active), do: "bg-red-100 text-red-700"
  def status_badge_class(:acknowledged), do: "bg-amber-100 text-amber-700"
  def status_badge_class(:silenced), do: "bg-zinc-100 text-zinc-600"
  def status_badge_class(:resolved), do: "bg-green-100 text-green-700"
end
