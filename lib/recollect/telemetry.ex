defmodule Recollect.Telemetry do
  @moduledoc """
  Telemetry events emitted by Recollect.

  ## Events

  ### Knowledge Operations
  - `[:recollect, :remember, :start]` — Entry creation started
  - `[:recollect, :remember, :stop]` — Entry created successfully
  - `[:recollect, :remember, :exception]` — Entry creation failed

  ### Search
  - `[:recollect, :search, :start]` — Search started
  - `[:recollect, :search, :stop]` — Search completed (candidates, injected, tokens, truncated)
  - `[:recollect, :search, :exception]` — Search failed

  ### Vector Search
  - `[:recollect, :search, :vector, :stop]` — Vector search completed

  ### Brief
  - `[:recollect, :brief, :build]` — Brief built (used_tokens, items, cache_hit)

  ### Dream
  - `[:recollect, :dream, :stage]` — Dream stage completed (stage, items, duration, budget)

  ### Pipeline
  - `[:recollect, :pipeline, :start]` — Pipeline started
  - `[:recollect, :pipeline, :stop]` — Pipeline completed
  - `[:recollect, :pipeline, :exception]` — Pipeline failed

  ### Embedding
  - `[:recollect, :embed, :stop]` — Embedding completed

  ### Extraction
  - `[:recollect, :extract, :stop]` — Entity extraction completed

  ### Consolidation
  - `[:recollect, :consolidation, :pass]` — Consolidation pass completed (pass, count, duration)
  - `[:recollect, :decay, :stop]` — Decay pass completed

  ### Recall
  - `[:recollect, :recall, :hit]` — Recall anchor hit (anchor_type, items)

  ### Learning
  - `[:recollect, :learning, :start]` — Learning pipeline started
  - `[:recollect, :learning, :stop]` — Learning pipeline completed
  - `[:recollect, :learn, :source, :stop]` — Single learner completed

  ### Context
  - `[:recollect, :context, :detect, :stop]` — Context detection completed

  ### Invalidation
  - `[:recollect, :invalidation, :start]` — Invalidation started
  - `[:recollect, :invalidation, :stop]` — Invalidation completed
  - `[:recollect, :invalidate, :stop]` — Single pattern invalidation completed

  ### Handoffs
  - `[:recollect, :handoff, :create, :stop]` — Handoff created
  - `[:recollect, :handoff, :get, :stop]` — Handoff retrieved
  - `[:recollect, :handoff, :load, :stop]` — Handoff loaded into working memory

  ### Mipmaps
  - `[:recollect, :mipmap, :generate, :stop]` — Mipmap generation completed

  All `:stop` events include `%{duration: native_time}` in measurements.
  All events include relevant metadata (scope_id, owner_id, tier, etc.).
  """

  @doc """
  Execute a function within a telemetry span.

  Emits `event_prefix ++ [:start]` before and `event_prefix ++ [:stop]` after.
  On exception, emits `event_prefix ++ [:exception]` and re-raises.

  The function result is passed through `extract_measurements/1` to pull
  counts and status into the stop measurements.
  """
  def span(event_prefix, metadata, fun) when is_list(event_prefix) and is_function(fun, 0) do
    start_time = System.monotonic_time()
    :telemetry.execute(event_prefix ++ [:start], %{system_time: System.system_time()}, metadata)

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time

      {measurements, result_metadata} = extract_measurements(result)

      :telemetry.execute(
        event_prefix ++ [:stop],
        Map.merge(%{duration: duration}, measurements),
        Map.merge(metadata, result_metadata)
      )

      result
    rescue
      e ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          event_prefix ++ [:exception],
          %{duration: duration},
          Map.merge(metadata, %{kind: :error, reason: e, stacktrace: __STACKTRACE__})
        )

        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          event_prefix ++ [:exception],
          %{duration: duration},
          Map.merge(metadata, %{kind: kind, reason: reason})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp extract_measurements({:ok, %{entries: entries, chunks: chunks, entities: entities}}) do
    {%{
       result_count: length(entries || []) + length(chunks || []),
       entries_count: length(entries || []),
       chunks_count: length(chunks || []),
       entities_count: length(entities || [])
     }, %{status: :ok}}
  end

  defp extract_measurements({:ok, %{items: items, candidates_considered: candidates}}) do
    {%{
       result_count: length(items || []),
       candidates_considered: candidates
     }, %{status: :ok}}
  end

  defp extract_measurements({:ok, %Recollect.Schema.Entry{}}), do: {%{}, %{status: :ok}}

  defp extract_measurements({:ok, count}) when is_integer(count), do: {%{count: count}, %{status: :ok}}

  defp extract_measurements({:ok, _}), do: {%{}, %{status: :ok}}
  defp extract_measurements({:error, _}), do: {%{}, %{status: :error}}
  defp extract_measurements(_), do: {%{}, %{}}

  @doc "Emit a simple event (no span, just measurements + metadata)."
  def event(name, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(name, measurements, metadata)
  end
end
