defmodule BeamWatch.LogFeed.Entry do
  @moduledoc false

  defstruct [:source, :delay_ms, :line]
end
