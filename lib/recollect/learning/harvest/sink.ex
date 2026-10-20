defmodule Recollect.Learner.Harvest.Sink do
  @moduledoc """
  Behaviour for harvest sinks — where extracted records go after a run.

  Implementations shipped here are DB-less transports:

    * `Recollect.Learner.Harvest.Sink.Jsonl` — append records to a transport
      file for server-side import
    * `Recollect.Learner.Harvest.Sink.Mcp` — push records to a memory
      server's `stage_memory` MCP tool

  Store sinks live in the host apps that own a memory store (ops_center:
  stage+sleep; home: distill+remember).
  """

  @doc "Consume the extracted records of one harvest run."
  @callback push(records :: [Recollect.Learner.Harvest.record()], opts :: keyword()) ::
              :ok | {:ok, map()} | {:error, term()}
end
