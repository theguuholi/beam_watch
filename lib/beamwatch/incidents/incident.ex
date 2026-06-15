defmodule BeamWatch.Incidents.Incident do
  @moduledoc false

  @type severity :: :critical | :warning | :info
  @type status :: :active | :acknowledged | :silenced | :resolved
  @type silence_scope :: nil | :incident | :type

  @type evidence_entry :: %{
          required(:source) => String.t(),
          required(:line) => String.t(),
          required(:at) => DateTime.t()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          type: atom(),
          resource: String.t(),
          severity: severity(),
          status: status(),
          first_seen: DateTime.t(),
          last_seen: DateTime.t(),
          evidence: [evidence_entry()],
          silence_scope: silence_scope()
        }

  @enforce_keys [:id, :type, :resource, :severity, :status, :first_seen, :last_seen]
  defstruct [
    :id,
    :type,
    :resource,
    :severity,
    :status,
    :first_seen,
    :last_seen,
    evidence: [],
    silence_scope: nil
  ]
end
