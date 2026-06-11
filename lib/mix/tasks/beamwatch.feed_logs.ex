defmodule Mix.Tasks.Beamwatch.FeedLogs do
  use Mix.Task

  @shortdoc "Writes sample BeamWatch logs to a local directory"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    BeamWatch.LogFeed.CLI.main(args)
  end
end
