defmodule BeamWatch.SourceHealth do
  @moduledoc false

  @type t :: %__MODULE__{
          file: String.t(),
          exists?: boolean(),
          size_bytes: non_neg_integer(),
          last_read_at: DateTime.t() | nil,
          last_log_at: DateTime.t() | nil,
          byte_offset: non_neg_integer(),
          parse_failures: non_neg_integer(),
          rotated?: boolean()
        }

  defstruct [
    :file,
    :last_read_at,
    :last_log_at,
    exists?: false,
    size_bytes: 0,
    byte_offset: 0,
    parse_failures: 0,
    rotated?: false
  ]
end
