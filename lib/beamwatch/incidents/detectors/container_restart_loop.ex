defmodule BeamWatch.Incidents.Detectors.ContainerRestartLoop do
  @moduledoc false

  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingestion.ParsedLine

  @relevant_sources ~w[docker.log app.log nginx.log]
  @die_window_seconds 60
  @die_threshold 4

  @spec process(ParsedLine.t(), map(), map()) :: {map(), map()}
  def process(%ParsedLine{source: source} = line, incidents, state)
      when source in @relevant_sources do
    cond do
      die_event?(line) -> handle_die(line, incidents, state)
      supporting_evidence?(line) -> handle_supporting(line, incidents, state)
      true -> {incidents, state}
    end
  end

  def process(_line, incidents, state), do: {incidents, state}

  defp die_event?(%ParsedLine{source: "docker.log", payload: p}),
    do: p =~ ~r/container=\S+ event=die/

  defp die_event?(_), do: false

  defp supporting_evidence?(%ParsedLine{source: "app.log", payload: p}),
    do: p =~ "healthcheck failed"

  defp supporting_evidence?(%ParsedLine{source: "nginx.log", payload: p}), do: p =~ "unavailable"

  defp supporting_evidence?(%ParsedLine{source: "docker.log", payload: p}), do: p =~ "event=start"

  defp supporting_evidence?(_), do: false

  @doc false
  def new_incident(container, [{last_seen, _, _} | _] = recent) do
    {first_seen, _, _} = List.last(recent)

    %Incident{
      id: "container_restart_loop:#{container}",
      type: :container_restart_loop,
      resource: container,
      severity: :critical,
      status: :active,
      first_seen: first_seen,
      last_seen: last_seen,
      evidence: recent |> Enum.reverse() |> Enum.map(&evidence_entry/1),
      silence_scope: nil
    }
  end

  defp handle_die(%ParsedLine{payload: p, at: at} = line, incidents, state) do
    [_, container] = Regex.run(~r/container=(\S+) event=die/, p)

    cutoff = DateTime.add(at, -@die_window_seconds, :second)

    recent =
      [{at, line.source, line.raw} | Map.get(state, container, [])]
      |> Enum.filter(fn {ts, _, _} -> DateTime.compare(ts, cutoff) != :lt end)

    incident_id = "container_restart_loop:#{container}"
    new_state = Map.put(state, container, recent)
    new_incidents = apply_die_event(incidents, incident_id, container, recent, line)

    {new_incidents, new_state}
  end

  defp apply_die_event(incidents, incident_id, container, recent, line) do
    threshold_reached = length(recent) >= @die_threshold
    existing = Map.get(incidents, incident_id)

    case {threshold_reached, existing} do
      {true, nil} -> Map.put(incidents, incident_id, new_incident(container, recent))
      {true, inc} -> Map.put(incidents, incident_id, append_evidence(inc, line))
      {false, nil} -> incidents
      {false, _inc} -> Map.update!(incidents, incident_id, &append_evidence(&1, line))
    end
  end

  defp handle_supporting(%ParsedLine{payload: p} = line, incidents, state) do
    container =
      cond do
        Regex.run(~r/container=(\S+)/, p) ->
          [_, c] = Regex.run(~r/container=(\S+)/, p)
          c

        Regex.run(~r/service=(\S+)/, p) ->
          [_, s] = Regex.run(~r/service=(\S+)/, p)
          s

        true ->
          nil
      end

    incident_id = container && "container_restart_loop:#{container}"

    new_incidents =
      if incident_id && Map.has_key?(incidents, incident_id) do
        Map.update!(incidents, incident_id, &append_evidence(&1, line))
      else
        incidents
      end

    {new_incidents, state}
  end

  defp append_evidence(%Incident{} = inc, %ParsedLine{at: at} = line) do
    %{
      inc
      | last_seen: at,
        evidence: [evidence_entry({at, line.source, line.raw}) | inc.evidence]
    }
  end

  defp evidence_entry({at, source, raw}), do: %{at: at, source: source, line: raw}
end
