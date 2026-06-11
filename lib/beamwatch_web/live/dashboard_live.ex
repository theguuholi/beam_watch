defmodule BeamWatchWeb.DashboardLive do
  use BeamWatchWeb, :live_view

  alias BeamWatch.LogFeed.DevControls

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       dev_log_controls_enabled?: DevControls.enabled?(),
       log_feed_target: Path.relative_to_cwd(DevControls.target_dir())
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="mx-auto max-w-6xl space-y-8 p-6">
        <div class="space-y-2">
          <p class="text-sm font-semibold uppercase tracking-wide text-zinc-500">
            BeamWatch
          </p>
          <h1 class="text-3xl font-semibold tracking-tight text-zinc-950">
            Incident triage
          </h1>
          <p class="max-w-3xl text-sm leading-6 text-zinc-600">
            Build this dashboard into an operator console for identifying active incidents,
            explaining evidence, and handling noisy system logs.
          </p>
        </div>

        <div class="grid gap-4 md:grid-cols-3">
          <.panel title="Active incidents" value="0" />
          <.panel title="Source health" value="Not wired" />
          <.panel title="Recent activity" value="No events" />
        </div>

        <div class="rounded-lg border border-dashed border-zinc-300 bg-white p-6">
          <h2 class="text-base font-semibold text-zinc-950">Starter shell</h2>
          <p class="mt-2 text-sm leading-6 text-zinc-600">
            The Phoenix app is intentionally thin. Use the README and fixtures to decide
            how logs should be read, normalized, reduced into incidents, and presented.
          </p>
        </div>

        <div
          :if={@dev_log_controls_enabled?}
          class="rounded-lg border border-zinc-200 bg-zinc-50 p-6"
        >
          <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="text-base font-semibold text-zinc-950">Dev log controls</h2>
              <p class="mt-2 text-sm leading-6 text-zinc-600">
                Target:
                <code class="rounded bg-white px-1.5 py-0.5 text-zinc-800">{@log_feed_target}</code>
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <button
                type="button"
                phx-click="dev-add-validation-logs"
                class="rounded-md bg-zinc-950 px-3 py-2 text-sm font-semibold text-white hover:bg-zinc-800"
              >
                Add validation logs
              </button>
              <button
                type="button"
                phx-click="dev-clear-log-dir"
                class="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm font-semibold text-zinc-900 hover:bg-zinc-100"
              >
                Clear log dir
              </button>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("dev-add-validation-logs", _params, socket) do
    if socket.assigns.dev_log_controls_enabled? do
      :ok = DevControls.add_validation_logs()

      {:noreply,
       put_flash(
         socket,
         :info,
         "Added validation logs to #{socket.assigns.log_feed_target}."
       )}
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

  defp panel(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 bg-white p-5">
      <p class="text-sm text-zinc-500">{@title}</p>
      <p class="mt-3 text-2xl font-semibold text-zinc-950">{@value}</p>
    </div>
    """
  end
end
