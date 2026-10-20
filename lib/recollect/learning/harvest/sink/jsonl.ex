defmodule Recollect.Learner.Harvest.Sink.Jsonl do
  @moduledoc """
  Append extracted records to a JSONL transport file, one JSON object per
  line — the DB-less export path for machines that cannot reach a memory
  store directly. Import the file server-side afterwards.
  """

  @behaviour Recollect.Learner.Harvest.Sink

  @impl true
  def push(records, opts) do
    path = opts[:path] || raise ArgumentError, "Sink.Jsonl requires :path"

    lines = Enum.map_join(records, "", fn record -> Jason.encode!(record) <> "\n" end)
    File.write!(path, lines, [:append])

    {:ok, %{written: length(records), path: path}}
  end
end
