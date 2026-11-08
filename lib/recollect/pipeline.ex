defmodule Recollect.Pipeline do
  @moduledoc """
  Orchestrates the full memory ingestion pipeline.

  Stages: Chunk → Embed Chunks → Extract → Embed Entities → Complete.
  Tracks progress via PipelineRun records.
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Pipeline.Chunker
  alias Recollect.Pipeline.Embedder
  alias Recollect.Pipeline.Extractor
  alias Recollect.Schema.Chunk
  alias Recollect.Schema.Document
  alias Recollect.Schema.PipelineRun

  require Logger

  @summary_prompt """
  You are a concise technical summarizer.

  Summarize the following document in at most 3-4 sentences. Capture what the
  document IS (its gist), the key entities/systems it concerns, and why someone
  would search for it. Plain text only, no headings, no bullet points.
  """

  @doc """
  Run the full pipeline synchronously on a document.
  Returns `{:ok, pipeline_run}` or `{:error, reason}`.

  Quarantined documents are refused immediately with `{:error, :quarantined}`;
  use `retry_quarantined/2` to reset and reprocess them.
  """
  def process(document, opts \\ [])

  def process(%Document{status: "quarantined"}, _opts), do: {:error, :quarantined}

  def process(document, opts) do
    telemetry_metadata = %{document_id: document.id, owner_id: document.owner_id}

    Recollect.Telemetry.span([:recollect, :pipeline], telemetry_metadata, fn ->
      repo = Config.repo()
      owner_id = document.owner_id

      {:ok, run} =
        %PipelineRun{}
        |> PipelineRun.changeset(%{
          document_id: document.id,
          status: "pending",
          owner_id: owner_id,
          scope_id: document.scope_id
        })
        |> repo.insert()

      scope_id = document.scope_id

      pipeline_opts =
        Keyword.merge(opts,
          owner_id: owner_id,
          scope_id: scope_id,
          collection_id: document.collection_id
        )

      result =
        with {:ok, run} <- update_run(run, "chunking", repo),
             {:ok, chunks} <- do_chunk(document, pipeline_opts, repo),
             {:ok, run} <- update_run(run, "embedding", %{chunks_created: length(chunks)}, repo),
             {:ok, chunks} <- do_embed_chunks(chunks),
             embedding_usage = collect_embedding_usage(),
             {:ok, run} <-
               update_run(
                 run,
                 "extracting",
                 %{
                   chunks_embedded: length(chunks),
                   embedding_tokens: embedding_usage[:tokens_used] || 0
                 },
                 repo
               ),
             {:ok, extraction} <- do_extract(chunks, pipeline_opts),
             {:ok, run} <-
               update_run(
                 run,
                 "syncing",
                 %{
                   entities_extracted: length(extraction.entities),
                   relations_extracted: length(extraction.relations)
                 },
                 repo
               ),
             {:ok, _} <- do_embed_entities(extraction.entities),
             :ok <- do_summarize(document),
             final_tokens = embedding_usage[:tokens_used] || 0,
             {:ok, updated_run} <-
               update_run(
                 run,
                 "complete",
                 %{
                   tokens_used: final_tokens
                 },
                 repo
               ) do
          document
          |> Ecto.Changeset.change(%{status: "ready", failed_attempts: 0})
          |> repo.update()

          {:ok, updated_run}
        end

      case result do
        {:ok, _} ->
          result

        {:error, reason} ->
          Logger.error("Recollect.Pipeline: failed for document #{document.id}: #{inspect(reason)}")

          run
          |> PipelineRun.changeset(%{status: "failed", error: inspect(reason)})
          |> repo.update()

          record_failure(document, repo)

          {:error, reason}
      end
    end)
  end

  @doc "Run the pipeline asynchronously."
  def process_async(document, opts \\ []) do
    Task.Supervisor.start_child(
      Config.task_supervisor(),
      fn -> process(document, opts) end,
      restart: :temporary
    )
  end

  @doc """
  Reset a quarantined (or failed) document and reprocess it.

  Accepts a `Document` struct or an id. Clears `failed_attempts`, flips the
  status back to `"pending"`, then runs `process/2`.
  """
  def retry_quarantined(document_or_id, opts \\ []) do
    repo = Config.repo()

    document =
      case document_or_id do
        %Document{} = doc -> doc
        id -> repo.get(Document, id)
      end

    case document do
      nil ->
        {:error, :not_found}

      %Document{} = doc ->
        {:ok, doc} =
          doc
          |> Ecto.Changeset.change(%{status: "pending", failed_attempts: 0})
          |> repo.update()

        process(doc, opts)
    end
  end

  @doc """
  Pipeline health snapshot over the last 24 hours.

  Returns a map with:

    - `:error_rate_24h` — failed / (failed + completed) runs, 0.0 when no runs
    - `:errored_count_24h` — failed runs in the window
    - `:completed_count_24h` — completed runs in the window
    - `:quarantined_count` — documents currently quarantined
    - `:oldest_pending_age_seconds` — age of the oldest pending document, nil if none
    - `:tokens_24h` — embedding tokens consumed in the window
    - `:cost_24h` — USD cost recorded in the window
  """
  def health do
    repo = Config.repo()
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -24 * 3600, :second)

    run_counts =
      from(r in PipelineRun,
        where: r.inserted_at >= ^cutoff,
        group_by: r.status,
        select: {r.status, count(r.id)}
      )
      |> repo.all()
      |> Map.new()

    errored = Map.get(run_counts, "failed", 0)
    completed = Map.get(run_counts, "complete", 0)
    total = errored + completed

    tokens_24h =
      repo.one(
        from(r in PipelineRun,
          where: r.inserted_at >= ^cutoff,
          select: coalesce(sum(r.tokens_used), 0)
        )
      )

    cost_24h =
      repo.one(
        from(r in PipelineRun,
          where: r.inserted_at >= ^cutoff,
          select: coalesce(sum(r.cost_usd), 0.0)
        )
      )

    quarantined_count =
      repo.one(from(d in Document, where: d.status == "quarantined", select: count(d.id)))

    oldest_pending =
      repo.one(
        from(d in Document,
          where: d.status == "pending",
          select: min(d.inserted_at)
        )
      )

    oldest_pending_age_seconds =
      case oldest_pending do
        nil -> nil
        ts -> max(DateTime.diff(now, ts, :second), 0)
      end

    %{
      error_rate_24h: if(total > 0, do: errored / total, else: 0.0),
      errored_count_24h: errored,
      completed_count_24h: completed,
      quarantined_count: quarantined_count,
      oldest_pending_age_seconds: oldest_pending_age_seconds,
      tokens_24h: tokens_24h,
      cost_24h: cost_24h
    }
  end

  # ── Pipeline Steps ────────────────────────────────────────────────────

  # Quarantine bookkeeping: bump the failure counter; at the configured
  # threshold the document leaves the automatic retry population entirely.
  defp record_failure(document, repo) do
    attempts = (document.failed_attempts || 0) + 1
    status = if attempts >= Config.max_failed_attempts(), do: "quarantined", else: "failed"

    document
    |> Ecto.Changeset.change(%{status: status, failed_attempts: attempts})
    |> repo.update()
  end

  defp do_chunk(document, opts, repo) do
    owner_id = Keyword.fetch!(opts, :owner_id)
    scope_id = Keyword.get(opts, :scope_id)

    # Delete existing chunks (re-processing)
    repo.delete_all(from(c in Chunk, where: c.document_id == ^document.id))

    # Chunk the content
    raw_chunks = Chunker.chunk(document.content)

    chunks =
      Enum.map(raw_chunks, fn raw ->
        {:ok, chunk} =
          %Chunk{}
          |> Chunk.changeset(%{
            document_id: document.id,
            sequence: raw.sequence,
            content: raw.content,
            token_count: raw.token_count,
            start_offset: raw.start_offset,
            end_offset: raw.end_offset,
            metadata: %{heading_context: raw.heading_context},
            owner_id: owner_id,
            scope_id: scope_id
          })
          |> repo.insert()

        chunk
      end)

    {:ok, chunks}
  rescue
    e ->
      Logger.error("Recollect.Pipeline: chunking failed: #{Exception.message(e)}")
      {:error, e}
  end

  defp do_embed_chunks(chunks) do
    # Clear any previous usage data
    Process.delete(:recollect_last_embedding_usage)

    # Not configured: skip cleanly. Chunks are still stored (searchable
    # via keyword/LIKE); only vector search is off. One debug line
    # instead of an error+warning per chunk.
    if Config.embedding_enabled?() do
      case Embedder.embed_chunks(chunks) do
        {:ok, _} = result ->
          result

        {:error, reason} ->
          Logger.warning("Recollect.Pipeline: chunk embedding failed, continuing: #{inspect(reason)}")

          {:ok, chunks}
      end
    else
      Logger.debug("Recollect.Pipeline: embedding disabled (no provider/credentials); skipping")
      {:ok, chunks}
    end
  end

  defp collect_embedding_usage do
    Process.get(:recollect_last_embedding_usage, %{tokens_used: 0})
  end

  defp do_extract(chunks, opts) do
    if Config.extraction_enabled?() do
      run_extraction(chunks, opts)
    else
      # Not configured (no llm_fn): skip the graph-extraction pass. Chunks
      # are still stored + embedded; only entity/relation extraction is
      # off. One debug line instead of a warning per chunk.
      Logger.debug("Recollect.Pipeline: extraction disabled (no provider/llm_fn); skipping")
      {:ok, %{entities: [], relations: []}}
    end
  end

  defp run_extraction(chunks, opts) do
    collection_id = Keyword.fetch!(opts, :collection_id)
    owner_id = Keyword.fetch!(opts, :owner_id)
    scope_id = Keyword.get(opts, :scope_id)

    {all_entities, all_relations} =
      Enum.reduce(chunks, {[], []}, fn chunk, {entities_acc, relations_acc} ->
        case Extractor.extract_from_chunk(chunk.content) do
          {:ok, %{entities: entities, relations: relations}} ->
            {:ok, persisted_entities} =
              Extractor.persist_entities(entities,
                collection_id: collection_id,
                owner_id: owner_id,
                scope_id: scope_id
              )

            entity_map =
              Map.new(persisted_entities, fn e -> {String.downcase(e.name), e.id} end)

            {:ok, persisted_relations} =
              Extractor.persist_relations(relations, entity_map,
                owner_id: owner_id,
                scope_id: scope_id,
                source_chunk_id: chunk.id
              )

            {entities_acc ++ persisted_entities, relations_acc ++ persisted_relations}

          {:error, reason} ->
            Logger.warning("Recollect.Pipeline: extraction failed for chunk #{chunk.id}: #{inspect(reason)}")

            {entities_acc, relations_acc}
        end
      end)

    {:ok, %{entities: all_entities, relations: all_relations}}
  end

  defp do_embed_entities(entities) do
    # Embed entities async — don't block pipeline. Skip entirely when
    # embedding is disabled (same reasoning as do_embed_chunks).
    if Config.embedding_enabled?() do
      Enum.each(entities, fn entity ->
        Task.Supervisor.start_child(
          Config.task_supervisor(),
          fn -> Embedder.embed_entity(entity) end,
          restart: :temporary
        )
      end)
    end

    {:ok, entities}
  rescue
    _ -> {:ok, entities}
  end

  # Document summary tier: a short gist per document, embedded so gist-level
  # queries can surface the document's chunks. Strictly best-effort — a
  # missing llm_fn, disabled embedding, or a failed call never fails the run.
  defp do_summarize(document) do
    cond do
      not Config.extraction_enabled?() ->
        Logger.debug("Recollect.Pipeline: summarization disabled (no llm_fn); skipping")
        :ok

      not Config.embedding_enabled?() ->
        Logger.debug("Recollect.Pipeline: embedding disabled; skipping summary")
        :ok

      true ->
        summarize_document(document)
    end
  end

  defp summarize_document(document) do
    llm_fn = Keyword.fetch!(Config.extraction_opts(), :llm_fn)

    messages = [
      %{role: "system", content: @summary_prompt},
      %{role: "user", content: String.slice(document.content || "", 0, 8_000)}
    ]

    # Hard brevity cap: a summary is a retrieval handle, not an essay.
    llm_opts = Keyword.put(Config.extraction_opts(), :max_tokens, 500)

    with {:ok, summary} when is_binary(summary) <- llm_fn.(messages, llm_opts),
         {:ok, _} <- Embedder.embed_document_summary(document.id, String.trim(summary)) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Recollect.Pipeline: summarization failed for document #{document.id}: #{inspect(reason)}")

        :ok

      _other ->
        :ok
    end
  end

  defp update_run(run, status, repo) do
    update_run(run, status, %{}, repo)
  end

  defp update_run(run, status, step_details, repo) do
    current = run.step_details || %{}
    merged = Map.merge(current, step_details)

    run
    |> PipelineRun.changeset(%{status: status, step_details: merged})
    |> repo.update()
  end
end
