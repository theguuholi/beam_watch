defmodule BeamWatch.LogFeed.Profiles do
  @moduledoc false

  alias BeamWatch.LogFeed.Fixtures
  alias BeamWatch.LogFeed.Interleaver

  def get(name, opts \\ [])

  def get("sample", _opts) do
    Fixtures.sample_streams()
    |> Enum.flat_map(fn {_name, entries} -> entries end)
  end

  def get("validation", _opts) do
    Fixtures.validation_streams()
    |> Interleaver.interleave()
  end

  def get(name, _opts), do: {:error, {:unknown_profile, name}}
end
