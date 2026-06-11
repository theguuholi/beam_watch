defmodule BeamWatch.LogEvent do
  @moduledoc false

  @type t :: %__MODULE__{
          timestamp: DateTime.t() | nil,
          source: String.t(),
          raw: String.t(),
          fields: %{String.t() => String.t()}
        }

  defstruct [:timestamp, :source, :raw, fields: %{}]
end
