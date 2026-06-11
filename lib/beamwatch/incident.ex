defmodule BeamWatch.Incident do
  @moduledoc false

  @type type ::
          :container_restart_loop
          | :disk_smart_warning
          | :share_permission_failure
          | :vm_boot_failure

  @type status :: :active | :acknowledged | :silenced | :resolved

  @type severity :: :critical | :warning

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          status: status(),
          severity: severity(),
          resource: String.t(),
          first_seen: DateTime.t(),
          last_seen: DateTime.t(),
          evidence: [String.t()],
          resolved_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :type,
    :status,
    :severity,
    :resource,
    :first_seen,
    :last_seen,
    :resolved_at,
    evidence: []
  ]
end
