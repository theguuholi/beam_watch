defmodule BeamWatch.Ingestion.ParsedLine do
  @moduledoc false

  @enforce_keys [:source, :raw]
  defstruct [:at, :source, :payload, :raw]

  @type t :: %__MODULE__{
          at: DateTime.t() | nil,
          source: String.t(),
          payload: String.t() | nil,
          raw: String.t()
        }
end
