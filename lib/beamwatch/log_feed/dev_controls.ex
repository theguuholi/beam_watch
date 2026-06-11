defmodule BeamWatch.LogFeed.DevControls do
  @moduledoc false

  alias BeamWatch.LogFeed.CLI

  @default_target "priv/logs"

  def enabled? do
    Application.get_env(:beamwatch, :dev_log_controls, false)
  end

  def target_dir do
    :beamwatch
    |> Application.get_env(:log_feed_target, @default_target)
    |> Path.expand()
  end

  def add_validation_logs(target \\ target_dir()) do
    CLI.run([
      "--profile",
      "validation",
      "--target",
      target,
      "--speed",
      "1000000",
      "--quiet"
    ])
  end

  def clear_log_dir(target \\ target_dir()) do
    File.rm_rf!(target)
    File.mkdir_p!(target)

    :ok
  end
end
