defmodule BeamWatch.Incidents.Detectors.VmBootFailure do
  @moduledoc false

  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingestion.ParsedLine

  @spec process(ParsedLine.t(), map(), map()) :: {map(), map()}
  def process(%ParsedLine{source: "libvirt.log"} = line, incidents, state) do
    cond do
      vm_failed?(line.payload) -> handle_failure(line, incidents, state)
      vm_running?(line.payload) -> handle_running(line, incidents, state)
      true -> {incidents, state}
    end
  end

  def process(%ParsedLine{source: source} = line, incidents, state)
      when source in ["qemu.log", "syslog.log"] do
    case supporting_vm(line.payload) do
      nil -> {incidents, state}
      vm -> maybe_append_evidence(vm, line, incidents, state)
    end
  end

  def process(_line, incidents, state), do: {incidents, state}

  defp vm_failed?(payload), do: payload =~ ~r/vm=\S+.*status=failed/
  defp vm_running?(payload), do: payload =~ ~r/vm=\S+.*status=running/

  defp supporting_vm(payload), do: extract_qemu_vm(payload) || extract_port_missing_vm(payload)

  defp extract_qemu_vm(payload) do
    if payload =~ "qemu-system-x86_64" and
         (payload =~ "Permission denied" or payload =~ "-drive file=") do
      case Regex.run(~r|/domains/([^/]+)/|, payload) do
        [_, vm] -> vm
        _ -> nil
      end
    end
  end

  defp extract_port_missing_vm(payload) do
    if payload =~ "port missing for vm=" do
      case Regex.run(~r/port missing for vm=(\S+)/, payload) do
        [_, vm] -> vm
        _ -> nil
      end
    end
  end

  defp handle_failure(%ParsedLine{payload: p, at: at} = line, incidents, state) do
    [_, vm] = Regex.run(~r/vm=(\S+)/, p)
    incident_id = "vm_boot_failure:#{vm}"

    new_incidents =
      case Map.get(incidents, incident_id) do
        nil ->
          inc = %Incident{
            id: incident_id,
            type: :vm_boot_failure,
            resource: vm,
            severity: :critical,
            status: :active,
            first_seen: at,
            last_seen: at,
            evidence: [evidence_entry(line)],
            silence_scope: nil
          }

          Map.put(incidents, incident_id, inc)

        inc ->
          updated = %{inc | last_seen: at, evidence: [evidence_entry(line) | inc.evidence]}
          Map.put(incidents, incident_id, updated)
      end

    {new_incidents, state}
  end

  defp handle_running(%ParsedLine{payload: p, at: at} = line, incidents, state) do
    [_, vm] = Regex.run(~r/vm=(\S+)/, p)
    incident_id = "vm_boot_failure:#{vm}"

    new_incidents =
      case Map.get(incidents, incident_id) do
        nil ->
          incidents

        inc ->
          updated = %{
            inc
            | status: :resolved,
              last_seen: at,
              evidence: [evidence_entry(line) | inc.evidence]
          }

          Map.put(incidents, incident_id, updated)
      end

    {new_incidents, state}
  end

  defp maybe_append_evidence(vm, line, incidents, state) do
    incident_id = "vm_boot_failure:#{vm}"

    new_incidents =
      case Map.get(incidents, incident_id) do
        nil ->
          incidents

        inc ->
          Map.put(incidents, incident_id, %{
            inc
            | last_seen: line.at,
              evidence: [evidence_entry(line) | inc.evidence]
          })
      end

    {new_incidents, state}
  end

  defp evidence_entry(%ParsedLine{source: source, raw: raw, at: at}),
    do: %{source: source, line: raw, at: at}
end
