defmodule BeamWatch.LogFeed.CLI do
  @moduledoc false

  alias BeamWatch.LogFeed.Profiles
  alias BeamWatch.LogFeed.Runner

  def main(args) do
    case run(args) do
      :ok -> :ok
      {:error, message} -> abort(message)
    end
  end

  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          profile: :string,
          target: :string,
          speed: :float,
          loop: :boolean,
          quiet: :boolean
        ]
      )

    if invalid != [] do
      {:error, "Invalid options: #{inspect(invalid)}"}
    else
      profile = Keyword.get(opts, :profile, "sample")
      target = Keyword.get(opts, :target, "priv/logs")
      speed = Keyword.get(opts, :speed, 1.0)
      loop? = Keyword.get(opts, :loop, false)
      quiet? = Keyword.get(opts, :quiet, false)

      case Profiles.get(profile) do
        entries when is_list(entries) -> Runner.run(entries, target, speed, loop?, quiet: quiet?)
        {:error, {:unknown_profile, name}} -> {:error, "Profile not found: #{name}"}
      end
    end
  end

  defp abort(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end
