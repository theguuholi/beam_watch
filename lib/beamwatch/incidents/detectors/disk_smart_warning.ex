defmodule BeamWatch.Incidents.Detectors.DiskSmartWarning do
  @moduledoc false

  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingestion.ParsedLine

  @spec process(ParsedLine.t(), map(), map()) :: {map(), map()}
  def process(%ParsedLine{source: "syslog.log"} = line, incidents, state) do
    cond do
      smart_warning?(line.payload) -> handle_warning(line, incidents, state)
      smart_passed?(line.payload) -> handle_passed(line, incidents, state)
      true -> {incidents, state}
    end
  end

  def process(_line, incidents, state), do: {incidents, state}

  defp smart_warning?(payload), do: payload =~ ~r/emhttpd: (\S+) SMART warning:/
  defp smart_passed?(payload), do: payload =~ ~r/emhttpd: (\S+) SMART check passed/

  defp handle_warning(%ParsedLine{payload: p, at: at} = line, incidents, state) do
    [_, disk] = Regex.run(~r/emhttpd: (\S+) SMART warning:/, p)
    date_str = Calendar.strftime(at, "%Y-%m-%d")
    incident_id = "disk_smart_warning:#{disk}:#{date_str}"

    new_incidents =
      case Map.get(incidents, incident_id) do
        nil ->
          inc = %Incident{
            id: incident_id,
            type: :disk_smart_warning,
            resource: disk,
            severity: :warning,
            status: :active,
            first_seen: at,
            last_seen: at,
            evidence: [evidence_entry(line)],
            silence_scope: nil
          }

          Map.put(incidents, incident_id, inc)

        inc ->
          updated = %{inc | last_seen: at, evidence: inc.evidence ++ [evidence_entry(line)]}
          Map.put(incidents, incident_id, updated)
      end

    {new_incidents, state}
  end

  defp handle_passed(%ParsedLine{payload: p, at: at} = line, incidents, state) do
    [_, disk] = Regex.run(~r/emhttpd: (\S+) SMART check passed/, p)
    date_str = Calendar.strftime(at, "%Y-%m-%d")
    incident_id = "disk_smart_warning:#{disk}:#{date_str}"

    new_incidents =
      case Map.get(incidents, incident_id) do
        nil ->
          incidents

        inc ->
          updated = %{
            inc
            | status: :resolved,
              last_seen: at,
              evidence: inc.evidence ++ [evidence_entry(line)]
          }

          Map.put(incidents, incident_id, updated)
      end

    {new_incidents, state}
  end

  defp evidence_entry(%ParsedLine{source: source, raw: raw, at: at}),
    do: %{source: source, line: raw, at: at}
end
