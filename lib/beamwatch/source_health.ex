defmodule BeamWatch.SourceHealth do
  @moduledoc false

  @type t :: %__MODULE__{
          filename: String.t(),
          exists?: boolean(),
          file_size: non_neg_integer(),
          byte_offset: non_neg_integer(),
          last_read_at: DateTime.t() | nil,
          latest_log_timestamp: DateTime.t() | nil,
          parse_failures: non_neg_integer(),
          skipped_lines: non_neg_integer(),
          rotation_detected: boolean()
        }

  defstruct [
    :filename,
    :last_read_at,
    :latest_log_timestamp,
    exists?: false,
    file_size: 0,
    byte_offset: 0,
    parse_failures: 0,
    skipped_lines: 0,
    rotation_detected: false
  ]
end
