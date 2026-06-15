defmodule BeamWatch.Ingestion.WatcherState do
  @moduledoc false

  @type file_entry :: %{offset: non_neg_integer(), buffer: String.t()}

  @type t :: %__MODULE__{
          files: %{String.t() => file_entry()}
        }

  defstruct files: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec get(t(), String.t()) :: file_entry()
  def get(%__MODULE__{files: files}, filename) do
    Map.get(files, filename, %{offset: 0, buffer: ""})
  end

  @spec put(t(), String.t(), non_neg_integer(), String.t()) :: t()
  def put(%__MODULE__{files: files} = state, filename, offset, buffer) do
    %{state | files: Map.put(files, filename, %{offset: offset, buffer: buffer})}
  end

  @spec remove(t(), String.t()) :: t()
  def remove(%__MODULE__{files: files} = state, filename) do
    %{state | files: Map.delete(files, filename)}
  end

  @spec rotated?(non_neg_integer(), non_neg_integer()) :: boolean()
  def rotated?(current_size, tracked_offset), do: current_size < tracked_offset

  @spec split_lines(String.t()) :: {[String.t()], String.t()}
  def split_lines(content) do
    parts = String.split(content, "\n")
    {last, rest} = List.pop_at(parts, -1)
    complete = Enum.reject(rest, &(String.trim(&1) == ""))
    {complete, last || ""}
  end
end
