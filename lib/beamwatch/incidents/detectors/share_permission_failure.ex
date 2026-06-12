defmodule BeamWatch.Incidents.Detectors.SharePermissionFailure do
  @moduledoc false

  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingestion.ParsedLine

  @relevant_sources ~w[smb.log nfs.log]
  @window_seconds 600

  @spec process(ParsedLine.t(), map(), map()) :: {map(), map()}
  def process(%ParsedLine{source: source} = line, incidents, state)
      when source in @relevant_sources do
    case extract_share(line.payload) do
      nil -> {incidents, state}
      share -> handle_denial(share, line, incidents, state)
    end
  end

  def process(_line, incidents, state), do: {incidents, state}

  defp extract_share(payload) do
    if payload =~ "Permission denied" or payload =~ "permission denied" do
      case Regex.run(~r/share=(\S+)/, payload) do
        [_, share] -> share
        _ -> nil
      end
    end
  end

  defp handle_denial(share, %ParsedLine{at: at} = line, incidents, state) do
    incident_id = "share_permission_failure:#{share}"

    new_incidents =
      case Map.get(incidents, incident_id) do
        nil ->
          inc = %Incident{
            id: incident_id,
            type: :share_permission_failure,
            resource: share,
            severity: :warning,
            status: :active,
            first_seen: at,
            last_seen: at,
            evidence: [evidence_entry(line)],
            silence_scope: nil
          }

          Map.put(incidents, incident_id, inc)

        %Incident{last_seen: last_seen} = inc ->
          if DateTime.diff(at, last_seen, :second) <= @window_seconds do
            updated = %{inc | last_seen: at, evidence: inc.evidence ++ [evidence_entry(line)]}
            Map.put(incidents, incident_id, updated)
          else
            reset = %{inc | first_seen: at, last_seen: at, evidence: [evidence_entry(line)], status: :active}
            Map.put(incidents, incident_id, reset)
          end
      end

    {new_incidents, state}
  end

  defp evidence_entry(%ParsedLine{source: source, raw: raw, at: at}),
    do: %{source: source, line: raw, at: at}
end
