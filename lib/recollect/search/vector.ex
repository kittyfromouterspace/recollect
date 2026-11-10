defmodule Recollect.Search.Vector do
  @moduledoc """
  Semantic similarity search over chunks and entries.

  Supports multiple database backends via the `Recollect.DatabaseAdapter` behaviour:
  - PostgreSQL with pgvector
  - SQLite with sqlite-vec
  - libSQL with native vector support
  """

  alias Recollect.Confidence
  alias Recollect.Config
  alias Recollect.Context.Detector
  alias Recollect.OutcomeTracker
  alias Recollect.Pipeline.Embedder
  alias Recollect.RetrievalCounter
  alias Recollect.Search.ContextBooster

  require Logger

  defp embedding_to_str(embedding) when is_list(embedding) do
    adapter = Config.adapter()
    result = adapter.format_embedding(embedding)

    if is_binary(result), do: result, else: "[#{Enum.map_join(embedding, ",", &Float.to_string/1)}]"
  end

  @doc """
  Search for similar chunks and/or entries.

  ## Options
  - `:owner_id` — UUID to scope chunk search
  - `:scope_id` — UUID to scope entry search
  - `:limit` — Max results (default: 10)
  - `:min_score` — Minimum similarity 0.0-1.0 (default: 0.0)
  - `:tier` — `:full`, `:lightweight`, or `:both` (default: `:both`)
  - `:include_superseded` — include entries superseded via a `"supersedes"`
    edge (default: false — superseded entries are excluded)
  - `:filters` — Map of additional filters:
      - `:entry_type` — Filter by entry type (e.g., :decision, :preference)
      - `:tags` — Only entries carrying ALL of these tags (normalized)
      - `:tags_any` — Only entries carrying AT LEAST ONE of these tags
      - `:temporal` — `:recent` (last 30 days), `:archived`, or DateTime range
      - `:confidence_min` — Minimum confidence threshold
  """
  def search(query_text, opts \\ []) do
    start_time = System.monotonic_time()
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)
    tier = Keyword.get(opts, :tier, :both)
    filters = Keyword.get(opts, :filters, %{})

    result =
      case Embedder.embed_query(query_text) do
        {:ok, query_embedding} ->
          embedding_str = embedding_to_str(query_embedding)

          results =
            []
            |> maybe_search_chunks(embedding_str, opts, limit, min_score, tier)
            |> maybe_search_entries(embedding_str, opts, limit, min_score, tier, filters)
            |> maybe_search_summaries(embedding_str, opts, limit, min_score, tier)
            |> maybe_escalate_to_mipmaps(query_text, opts, limit, query_embedding)

          {:ok, results}

        {:error, reason} ->
          # Embeddings disabled — return empty results so caller can use keyword fallback
          if Config.embedding_enabled?() do
            {:error, reason}
          else
            {:ok, []}
          end
      end

    duration = System.monotonic_time() - start_time

    case result do
      {:ok, results} ->
        Recollect.Telemetry.event([:recollect, :search, :vector, :stop], %{
          duration: duration,
          result_count: length(results),
          tier: tier,
          filters_applied: map_size(filters) > 0,
          has_entry_type_filter: filters[:entry_type] != nil,
          has_temporal_filter: filters[:temporal] != nil,
          has_confidence_filter: filters[:confidence_min] != nil
        })

      _ ->
        :ok
    end

    result
  end

  @doc "Search chunks only."
  def search_chunks(query_text, owner_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)

    case Embedder.embed_query(query_text) do
      {:ok, embedding} ->
        embedding_str = embedding_to_str(embedding)
        do_search_chunks(embedding_str, owner_id, limit, min_score)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Search entries only."
  def search_entries(query_text, scope_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)
    filters = Keyword.get(opts, :filters, %{})
    include_superseded = Keyword.get(opts, :include_superseded, false)

    case Embedder.embed_query(query_text) do
      {:ok, embedding} ->
        embedding_str = embedding_to_str(embedding)
        do_search_entries(embedding_str, scope_id, limit, min_score, filters, include_superseded)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Search entries only using a pre-computed embedding string."
  def search_entries_by_embedding(embedding_str, scope_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)
    filters = Keyword.get(opts, :filters, %{})
    include_superseded = Keyword.get(opts, :include_superseded, false)

    do_search_entries(embedding_str, scope_id, limit, min_score, filters, include_superseded)
  end

  @doc """
  Search entries by owner_id across all scopes (global brain search).
  Used for cross-workspace knowledge retrieval with workspace-priority ranking.

  Options:
    - `:scope_priority` — a scope_id to boost results from (workspace priority)
    - `:limit` — max results (default 10)
    - `:min_score` — minimum similarity score (default 0.0)
    - `:filters` — additional entry filters
  """
  def search_entries_by_owner(query_text, owner_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)
    filters = Keyword.get(opts, :filters, %{})
    scope_priority = Keyword.get(opts, :scope_priority)
    include_superseded = Keyword.get(opts, :include_superseded, false)

    case Embedder.embed_query(query_text) do
      {:ok, embedding} ->
        embedding_str = embedding_to_str(embedding)

        case do_search_entries_by_owner(embedding_str, owner_id, limit, min_score, filters, include_superseded) do
          {:ok, results} ->
            results = apply_scope_priority(results, scope_priority)
            {:ok, results}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_scope_priority(results, nil), do: results
  defp apply_scope_priority(results, _scope_id), do: results

  @doc "Search entities by vector similarity."
  def search_entities_vec(query_text, owner_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    case Embedder.embed_query(query_text) do
      {:ok, embedding} ->
        embedding_str = embedding_to_str(embedding)
        do_search_entities(embedding_str, owner_id, limit)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp maybe_search_chunks(acc, embedding_str, opts, limit, min_score, tier) when tier in [:full, :both] do
    case Keyword.get(opts, :owner_id) do
      nil ->
        acc

      owner_id ->
        case do_search_chunks(embedding_str, owner_id, limit, min_score) do
          {:ok, results} -> acc ++ Enum.map(results, &Map.put(&1, :result_type, :chunk))
          _ -> acc
        end
    end
  end

  defp maybe_search_chunks(acc, _, _, _, _, _), do: acc

  defp maybe_escalate_to_mipmaps(results, query_text, opts, limit, query_embedding) when length(results) < 3 do
    case Keyword.get(opts, :scope_id) do
      nil ->
        results

      scope_id ->
        # MEM-009: reuse the embedding search already computed for this query.
        case Recollect.Mipmap.retrieve(query_text, scope_id,
               limit: limit,
               query_embedding: query_embedding
             ) do
          {:ok, mipmap_results, _level} when mipmap_results != [] ->
            existing_ids = MapSet.new(results, fn r -> r["entry_id"] end)

            mipmap_entries =
              mipmap_results
              |> Enum.reject(fn m -> MapSet.member?(existing_ids, m["entry_id"]) end)
              |> Enum.map(&Map.put(&1, :result_type, :mipmap))

            results ++ mipmap_entries

          _ ->
            results
        end
    end
  end

  defp maybe_escalate_to_mipmaps(results, _, _, _, _), do: results

  defp maybe_search_entries(acc, embedding_str, opts, limit, min_score, tier, filters)
       when tier in [:lightweight, :both] do
    case Keyword.get(opts, :scope_id) do
      nil ->
        acc

      scope_id ->
        include_superseded = Keyword.get(opts, :include_superseded, false)

        case do_search_entries(embedding_str, scope_id, limit, min_score, filters, include_superseded) do
          {:ok, results} -> acc ++ Enum.map(results, &Map.put(&1, :result_type, :entry))
          _ -> acc
        end
    end
  end

  defp maybe_search_entries(acc, _, _, _, _, _, _), do: acc

  # Document summary tier (Tier 1, :full/:both only): vector-match document
  # gists, then contribute each hit's top chunks — marked `via: :summary` —
  # when they aren't already present from direct chunk search.
  defp maybe_search_summaries(acc, embedding_str, opts, limit, min_score, tier) when tier in [:full, :both] do
    case Keyword.get(opts, :owner_id) do
      nil ->
        acc

      owner_id ->
        case do_search_summaries(embedding_str, owner_id, limit, min_score) do
          {:ok, []} ->
            acc

          {:ok, summaries} ->
            acc ++ summary_chunks(summaries, embedding_str, acc, opts)

          _ ->
            acc
        end
    end
  end

  defp maybe_search_summaries(acc, _, _, _, _, _), do: acc

  @summary_chunk_limit 3

  defp summary_chunks(summaries, embedding_str, existing, opts) do
    chunk_limit = Keyword.get(opts, :summary_chunk_limit, @summary_chunk_limit)

    existing_ids =
      MapSet.new(existing, fn r -> r["id"] || r[:id] end)

    summaries
    |> Enum.flat_map(fn summary ->
      case do_top_chunks_for_document(embedding_str, summary["document_id"], chunk_limit) do
        {:ok, chunks} ->
          Enum.map(chunks, fn chunk ->
            chunk
            |> Map.put(:result_type, :chunk)
            |> Map.put(:via, :summary)
          end)

        _ ->
          []
      end
    end)
    |> Enum.reject(fn chunk -> MapSet.member?(existing_ids, chunk["id"]) end)
  end

  defp do_search_chunks(embedding_str, owner_id, limit, min_score) do
    adapter = Config.adapter()
    repo = Config.repo()

    {sql, params} = chunks_query(adapter.dialect(), adapter, embedding_str, owner_id, limit, min_score)

    case repo.query(sql, params) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> Recollect.Util.row_to_map(columns, row) end)}

      {:error, reason} ->
        Logger.error("Recollect vector search (chunks) failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_search_entries(embedding_str, scope_id, limit, min_score, filters, include_superseded) do
    adapter = Config.adapter()
    repo = Config.repo()

    {sql, params} =
      entries_query(adapter.dialect(), adapter, embedding_str, scope_id, limit, min_score, filters, include_superseded)

    case repo.query(sql, params) do
      {:ok, %{rows: rows, columns: columns}} ->
        results = Enum.map(rows, fn row -> Recollect.Util.row_to_map(columns, row) end)
        results = add_context_boost(results)
        bump_retrieval(results)
        track_for_outcome(scope_id, results)
        {:ok, results}

      {:error, reason} ->
        Logger.error("Recollect vector search (entries) failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_search_entries_by_owner(embedding_str, owner_id, limit, min_score, filters, include_superseded) do
    adapter = Config.adapter()
    repo = Config.repo()

    {sql, params} =
      entries_query_by_owner(
        adapter.dialect(),
        adapter,
        embedding_str,
        owner_id,
        limit,
        min_score,
        filters,
        include_superseded
      )

    case repo.query(sql, params) do
      {:ok, %{rows: rows, columns: columns}} ->
        results = Enum.map(rows, fn row -> Recollect.Util.row_to_map(columns, row) end)
        results = add_context_boost(results)
        {:ok, results}

      {:error, reason} ->
        Logger.error("Recollect vector search (entries by owner) failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_search_entities(embedding_str, owner_id, limit) do
    adapter = Config.adapter()
    repo = Config.repo()

    {sql, params} = entities_query(adapter.dialect(), adapter, embedding_str, owner_id, limit)

    case repo.query(sql, params) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> Recollect.Util.row_to_map(columns, row) end)}

      {:error, reason} ->
        Logger.error("Recollect vector search (entities) failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Query Builders (PostgreSQL) ─────────────────────────────────────

  defp chunks_query(:postgres, _adapter, embedding_str, owner_id, limit, min_score) do
    sql = """
    SELECT
      mc.id, mc.content, mc.document_id, mc.sequence,
      mc.token_count, mc.metadata,
      (1 - (mc.embedding <=> $1::text::vector)) AS score
    FROM recollect_chunks mc
    WHERE mc.owner_id = $2
      AND mc.embedding IS NOT NULL
      AND (1 - (mc.embedding <=> $1::text::vector)) >= $3
    ORDER BY mc.embedding <=> $1::text::vector
    LIMIT $4
    """

    {sql, [embedding_str, Recollect.Util.uuid_to_bin(owner_id), min_score, limit]}
  end

  # ── Query Builders (SQLite / sqlite-vec) ────────────────────────────

  defp chunks_query(:sqlite, adapter, embedding_str, owner_id, limit, min_score) do
    similarity = adapter.vector_similarity_sql("mc.embedding", "?")
    distance = adapter.vector_distance_sql("mc.embedding", "?")

    sql = """
    SELECT
      mc.id, mc.content, mc.document_id, mc.sequence,
      mc.token_count, mc.metadata,
      #{similarity} AS score
    FROM recollect_chunks mc
    WHERE mc.owner_id = ?
      AND mc.embedding IS NOT NULL
      AND #{similarity} >= ?
    ORDER BY #{distance}
    LIMIT ?
    """

    # Each ? in the distance/similarity expressions consumes one embedding_str param
    {sql, [embedding_str, owner_id, embedding_str, min_score, embedding_str, limit]}
  end

  # ── Query Builders (libSQL) ─────────────────────────────────────────

  defp chunks_query(:libsql, adapter, embedding_str, owner_id, limit, min_score) do
    # libSQL uses same ? placeholder style as SQLite
    chunks_query(:sqlite, adapter, embedding_str, owner_id, limit, min_score)
  end

  defp entries_query(:postgres, _adapter, embedding_str, scope_id, limit, min_score, filters, include_superseded) do
    {filter_sql, filter_params} = build_entry_filters_pg(filters)

    sql = """
    SELECT
      me.id, me.content, me.summary, me.entry_type, me.source,
      me.metadata, me.confidence, me.inserted_at,
      me.half_life_days, me.pinned, me.emotional_valence, me.access_count,
      me.last_accessed_at, me.context_hints,
      (1 - (me.embedding <=> $1::text::vector)) AS score
    FROM recollect_entries me
    WHERE me.scope_id = $2
      AND me.embedding IS NOT NULL
      AND me.entry_type != 'archived'
      AND me.deleted_at IS NULL
      AND (1 - (me.embedding <=> $1::text::vector)) >= $3
      #{superseded_exclusion_sql(include_superseded)}
      #{filter_sql}
    ORDER BY me.embedding <=> $1::text::vector
    LIMIT $4
    """

    params = [embedding_str, Recollect.Util.uuid_to_bin(scope_id), min_score, limit | filter_params]
    {sql, params}
  end

  defp entries_query(dialect, adapter, embedding_str, scope_id, limit, min_score, filters, include_superseded)
       when dialect in [:sqlite, :libsql] do
    similarity = adapter.vector_similarity_sql("me.embedding", "?")
    distance = adapter.vector_distance_sql("me.embedding", "?")

    {filter_sql, filter_params} = build_entry_filters_sqlite(filters)

    sql = """
    SELECT
      me.id, me.content, me.summary, me.entry_type, me.source,
      me.metadata, me.confidence, me.inserted_at,
      me.half_life_days, me.pinned, me.emotional_valence, me.access_count,
      me.last_accessed_at, me.context_hints,
      #{similarity} AS score
    FROM recollect_entries me
    WHERE me.scope_id = ?
      AND me.embedding IS NOT NULL
      AND me.entry_type != 'archived'
      AND me.deleted_at IS NULL
      AND #{similarity} >= ?
      #{superseded_exclusion_sql(include_superseded)}
      #{filter_sql}
    ORDER BY #{distance}
    LIMIT ?
    """

    # similarity (SELECT) + scope_id + similarity (WHERE) + min_score + filter_params + distance (ORDER BY) + limit
    params = [embedding_str, scope_id, embedding_str, min_score] ++ filter_params ++ [embedding_str, limit]
    {sql, params}
  end

  defp entries_query_by_owner(:postgres, _adapter, embedding_str, owner_id, limit, min_score, filters, include_superseded) do
    {filter_sql, filter_params} = build_entry_filters_pg(filters)

    sql = """
    SELECT
      me.id, me.content, me.summary, me.entry_type, me.source,
      me.metadata, me.confidence, me.inserted_at,
      me.half_life_days, me.pinned, me.emotional_valence, me.access_count,
      me.last_accessed_at, me.context_hints, me.scope_id,
      (1 - (me.embedding <=> $1::text::vector)) AS score
    FROM recollect_entries me
    WHERE me.owner_id = $2
      AND me.embedding IS NOT NULL
      AND me.entry_type != 'archived'
      AND me.deleted_at IS NULL
      AND (1 - (me.embedding <=> $1::text::vector)) >= $3
      #{superseded_exclusion_sql(include_superseded)}
      #{filter_sql}
    ORDER BY me.embedding <=> $1::text::vector
    LIMIT $4
    """

    params = [embedding_str, Recollect.Util.uuid_to_bin(owner_id), min_score, limit | filter_params]
    {sql, params}
  end

  defp entries_query_by_owner(dialect, adapter, embedding_str, owner_id, limit, min_score, filters, include_superseded)
       when dialect in [:sqlite, :libsql] do
    similarity = adapter.vector_similarity_sql("me.embedding", "?")
    distance = adapter.vector_distance_sql("me.embedding", "?")

    {filter_sql, filter_params} = build_entry_filters_sqlite(filters)

    sql = """
    SELECT
      me.id, me.content, me.summary, me.entry_type, me.source,
      me.metadata, me.confidence, me.inserted_at,
      me.half_life_days, me.pinned, me.emotional_valence, me.access_count,
      me.last_accessed_at, me.context_hints, me.scope_id,
      #{similarity} AS score
    FROM recollect_entries me
    WHERE me.owner_id = ?
      AND me.embedding IS NOT NULL
      AND me.entry_type != 'archived'
      AND me.deleted_at IS NULL
      AND #{similarity} >= ?
      #{superseded_exclusion_sql(include_superseded)}
      #{filter_sql}
    ORDER BY #{distance}
    LIMIT ?
    """

    params = [embedding_str, owner_id, embedding_str, min_score] ++ filter_params ++ [embedding_str, limit]
    {sql, params}
  end

  @doc """
  Keyword fallback search over entries using ILIKE/LIKE on content and summary.

  Used when embeddings are disabled or vector recall is poor.
  Adapter-aware casing: ILIKE for PostgreSQL, LIKE for SQLite/libSQL.

  Returns `{:ok, results}` where each result has `:id`, `:content`, `:summary`,
  `:entry_type`, `:score` (set to 1.0 for keyword match), and `:source: :keyword`.
  """
  def keyword_search_entries(query_text, scope_id, owner_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    filters = Keyword.get(opts, :filters, %{})

    adapter = Config.adapter()
    repo = Config.repo()

    {sql, params} =
      keyword_entries_query(adapter.dialect(), adapter, query_text, scope_id, owner_id, limit, filters)

    case repo.query(sql, params) do
      {:ok, %{rows: rows, columns: columns}} ->
        results = Enum.map(rows, fn row -> Recollect.Util.row_to_map(columns, row) end)
        results = Enum.map(results, fn r -> Map.put(r, :source, :keyword) end)
        {:ok, results}

      {:error, reason} ->
        Logger.error("Recollect keyword search failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp keyword_entries_query(:postgres, _adapter, query_text, scope_id, owner_id, limit, filters) do
    {filter_sql, filter_params} = build_entry_filters_pg(filters)

    search_terms = String.split(query_text, " ", trim: true)

    like_conditions =
      search_terms
      |> Enum.with_index()
      |> Enum.map_join(" AND ", fn {_term, idx} ->
        param_idx = 3 + (idx * 2)
        "(me.content ILIKE $#{param_idx} OR me.summary ILIKE $#{param_idx + 1})"
      end)

    params = [Recollect.Util.uuid_to_bin(scope_id), Recollect.Util.uuid_to_bin(owner_id)]
    param_terms = Enum.flat_map(search_terms, fn t -> ["%" <> t <> "%", "%" <> t <> "%"] end)

    params = [Recollect.Util.uuid_to_bin(scope_id), Recollect.Util.uuid_to_bin(owner_id)]
    param_terms = Enum.flat_map(search_terms, fn t -> ["%" <> t <> "%", "%" <> t <> "%"] end)

    sql = """
    SELECT
      me.id, me.content, me.summary, me.entry_type, me.source,
      me.metadata, me.confidence, me.inserted_at,
      me.half_life_days, me.pinned, me.emotional_valence, me.access_count,
      me.last_accessed_at, me.context_hints, me.scope_id,
      1.0 AS score
    FROM recollect_entries me
    WHERE me.scope_id = $1
      AND me.owner_id = $2
      AND me.entry_type != 'archived'
      AND me.deleted_at IS NULL
      AND (#{like_conditions})
      #{filter_sql}
    ORDER BY me.updated_at DESC, me.access_count DESC
    LIMIT #{limit}
    """

    {sql, params ++ param_terms ++ filter_params}
  end

  defp keyword_entries_query(dialect, _adapter, query_text, scope_id, owner_id, limit, filters)
       when dialect in [:sqlite, :libsql] do
    {filter_sql, filter_params} = build_entry_filters_sqlite(filters)

    search_terms = String.split(query_text, " ", trim: true)

    like_conditions =
      search_terms
      |> Enum.with_index()
      |> Enum.map_join(" AND ", fn {_term, idx} ->
        param_idx = 3 + (idx * 2)
        "(me.content LIKE ?#{param_idx} OR me.summary LIKE ?#{param_idx + 1})"
      end)

    params = [Recollect.Util.uuid_to_bin(scope_id), Recollect.Util.uuid_to_bin(owner_id)]
    param_terms = Enum.flat_map(search_terms, fn t -> ["%" <> t <> "%", "%" <> t <> "%"] end)

    sql = """
    SELECT
      me.id, me.content, me.summary, me.entry_type, me.source,
      me.metadata, me.confidence, me.inserted_at,
      me.half_life_days, me.pinned, me.emotional_valence, me.access_count,
      me.last_accessed_at, me.context_hints, me.scope_id,
      1.0 AS score
    FROM recollect_entries me
    WHERE me.scope_id = ?
      AND me.owner_id = ?
      AND me.entry_type != 'archived'
      AND me.deleted_at IS NULL
      AND (#{like_conditions})
      #{filter_sql}
    ORDER BY me.updated_at DESC, me.access_count DESC
    LIMIT #{limit}
    """

    {sql, params ++ param_terms ++ filter_params}
  end

  defp entities_query(:postgres, _adapter, embedding_str, owner_id, limit) do
    sql = """
    SELECT
      me.id, me.name, me.entity_type, me.description,
      me.mention_count,
      (1 - (me.embedding <=> $1::text::vector)) AS score
    FROM recollect_entities me
    WHERE me.owner_id = $2
      AND me.embedding IS NOT NULL
    ORDER BY me.embedding <=> $1::text::vector
    LIMIT $3
    """

    {sql, [embedding_str, Recollect.Util.uuid_to_bin(owner_id), limit]}
  end

  defp entities_query(dialect, adapter, embedding_str, owner_id, limit) when dialect in [:sqlite, :libsql] do
    similarity = adapter.vector_similarity_sql("me.embedding", "?")
    distance = adapter.vector_distance_sql("me.embedding", "?")

    sql = """
    SELECT
      me.id, me.name, me.entity_type, me.description,
      me.mention_count,
      #{similarity} AS score
    FROM recollect_entities me
    WHERE me.owner_id = ?
      AND me.embedding IS NOT NULL
    ORDER BY #{distance}
    LIMIT ?
    """

    {sql, [embedding_str, owner_id, embedding_str, limit]}
  end

  # ── Superseded Exclusion ────────────────────────────────────────────

  # Superseded entries (incoming "supersedes" edge) are spent knowledge:
  # hidden by default, opt back in with `include_superseded: true`.
  defp superseded_exclusion_sql(true), do: ""

  defp superseded_exclusion_sql(false) do
    "AND NOT EXISTS (SELECT 1 FROM recollect_edges se WHERE se.target_entry_id = me.id AND se.relation = 'supersedes')"
  end

  # ── Document Summary Tier ───────────────────────────────────────────

  defp do_search_summaries(embedding_str, owner_id, limit, min_score) do
    adapter = Config.adapter()
    repo = Config.repo()

    {sql, params} = summaries_query(adapter.dialect(), adapter, embedding_str, owner_id, limit, min_score)

    case repo.query(sql, params) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> Recollect.Util.row_to_map(columns, row) end)}

      {:error, reason} ->
        Logger.error("Recollect vector search (document summaries) failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_top_chunks_for_document(embedding_str, document_id, limit) do
    adapter = Config.adapter()
    repo = Config.repo()

    {sql, params} = top_chunks_query(adapter.dialect(), adapter, embedding_str, document_id, limit)

    case repo.query(sql, params) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> Recollect.Util.row_to_map(columns, row) end)}

      {:error, reason} ->
        Logger.error("Recollect summary chunk fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp summaries_query(:postgres, _adapter, embedding_str, owner_id, limit, min_score) do
    sql = """
    SELECT
      md.id AS document_id, md.title, md.summary,
      (1 - (md.summary_embedding <=> $1::text::vector)) AS score
    FROM recollect_documents md
    WHERE md.owner_id = $2
      AND md.summary_embedding IS NOT NULL
      AND (1 - (md.summary_embedding <=> $1::text::vector)) >= $3
    ORDER BY md.summary_embedding <=> $1::text::vector
    LIMIT $4
    """

    {sql, [embedding_str, Recollect.Util.uuid_to_bin(owner_id), min_score, limit]}
  end

  defp summaries_query(dialect, adapter, embedding_str, owner_id, limit, min_score) when dialect in [:sqlite, :libsql] do
    similarity = adapter.vector_similarity_sql("md.summary_embedding", "?")
    distance = adapter.vector_distance_sql("md.summary_embedding", "?")

    sql = """
    SELECT
      md.id AS document_id, md.title, md.summary,
      #{similarity} AS score
    FROM recollect_documents md
    WHERE md.owner_id = ?
      AND md.summary_embedding IS NOT NULL
      AND #{similarity} >= ?
    ORDER BY #{distance}
    LIMIT ?
    """

    {sql, [embedding_str, owner_id, embedding_str, min_score, embedding_str, limit]}
  end

  defp top_chunks_query(:postgres, _adapter, embedding_str, document_id, limit) do
    sql = """
    SELECT
      mc.id, mc.content, mc.document_id, mc.sequence,
      mc.token_count, mc.metadata,
      (1 - (mc.embedding <=> $1::text::vector)) AS score
    FROM recollect_chunks mc
    WHERE mc.document_id = $2
      AND mc.embedding IS NOT NULL
    ORDER BY mc.embedding <=> $1::text::vector
    LIMIT $3
    """

    {sql, [embedding_str, Recollect.Util.uuid_to_bin(document_id), limit]}
  end

  defp top_chunks_query(dialect, adapter, embedding_str, document_id, limit) when dialect in [:sqlite, :libsql] do
    distance = adapter.vector_distance_sql("mc.embedding", "?")

    sql = """
    SELECT
      mc.id, mc.content, mc.document_id, mc.sequence,
      mc.token_count, mc.metadata
    FROM recollect_chunks mc
    WHERE mc.document_id = ?
      AND mc.embedding IS NOT NULL
    ORDER BY #{distance}
    LIMIT ?
    """

    {sql, [document_id, embedding_str, limit]}
  end

  # ── Filter Builders ─────────────────────────────────────────────────
  #
  # Clauses are `{sql, params}` pairs; params is always a list so multi-param
  # clauses (tags) keep the placeholder arithmetic honest. The base query
  # binds $1..$4 (embedding, scope/owner, min_score, limit), so filter
  # placeholders start at $5.

  defp build_entry_filters_pg(filters) when filters == %{} or filters == nil do
    {"", []}
  end

  defp build_entry_filters_pg(filters) do
    clauses =
      []
      |> add_entry_type_filter_pg(filters[:entry_type])
      |> add_confidence_filter_pg(filters[:confidence_min])
      |> add_temporal_filter_pg(filters[:temporal])
      |> add_tags_all_filter_pg(filters[:tags])
      |> add_tags_any_filter_pg(filters[:tags_any])

    {conditions, param_lists} = Enum.unzip(clauses)

    filter_sql =
      if conditions == [] do
        ""
      else
        "AND " <> Enum.join(conditions, " AND ")
      end

    {filter_sql, Enum.flat_map(param_lists, & &1)}
  end

  defp next_pg_idx(clauses) do
    5 + (clauses |> Enum.flat_map(fn {_sql, params} -> params end) |> length())
  end

  defp add_entry_type_filter_pg(acc, nil), do: acc

  defp add_entry_type_filter_pg(acc, entry_type) do
    acc ++ [{"me.entry_type = $#{next_pg_idx(acc)}", [to_string(entry_type)]}]
  end

  defp add_confidence_filter_pg(acc, nil), do: acc

  defp add_confidence_filter_pg(acc, confidence_min) do
    acc ++ [{"me.confidence >= $#{next_pg_idx(acc)}", [confidence_min]}]
  end

  defp add_temporal_filter_pg(acc, nil), do: acc

  defp add_temporal_filter_pg(acc, :recent) do
    thirty_days_ago = DateTime.add(DateTime.utc_now(), -30 * 24 * 3600, :second)
    acc ++ [{"me.inserted_at >= $#{next_pg_idx(acc)}", [thirty_days_ago]}]
  end

  # :tags — every listed tag must be present on the entry.
  defp add_tags_all_filter_pg(acc, nil), do: acc

  defp add_tags_all_filter_pg(acc, tags) when is_list(tags) do
    case Recollect.Knowledge.normalize_tags(tags) do
      [] ->
        acc

      normalized ->
        idx = next_pg_idx(acc)

        acc ++
          [
            {"(SELECT count(DISTINCT t.tag) FROM recollect_entry_tags t " <>
               "WHERE t.entry_id = me.id AND t.tag = ANY($#{idx}::text[])) = $#{idx + 1}",
             [normalized, length(normalized)]}
          ]
    end
  end

  # :tags_any — at least one listed tag must be present.
  defp add_tags_any_filter_pg(acc, nil), do: acc

  defp add_tags_any_filter_pg(acc, tags) when is_list(tags) do
    case Recollect.Knowledge.normalize_tags(tags) do
      [] ->
        acc

      normalized ->
        acc ++
          [
            {"EXISTS (SELECT 1 FROM recollect_entry_tags t " <>
               "WHERE t.entry_id = me.id AND t.tag = ANY($#{next_pg_idx(acc)}::text[]))", [normalized]}
          ]
    end
  end

  defp build_entry_filters_sqlite(filters) when filters == %{} or filters == nil do
    {"", []}
  end

  defp build_entry_filters_sqlite(filters) do
    clauses =
      []
      |> add_filter_sqlite(filters[:entry_type], "me.entry_type = ?", &to_string/1)
      |> add_filter_sqlite(filters[:confidence_min], "me.confidence >= ?", & &1)
      |> add_temporal_filter_sqlite(filters[:temporal])
      |> add_tags_all_filter_sqlite(filters[:tags])
      |> add_tags_any_filter_sqlite(filters[:tags_any])

    {conditions, param_lists} = Enum.unzip(clauses)

    filter_sql =
      if conditions == [] do
        ""
      else
        "AND " <> Enum.join(conditions, " AND ")
      end

    {filter_sql, Enum.flat_map(param_lists, & &1)}
  end

  defp add_filter_sqlite(acc, nil, _sql, _transform), do: acc

  defp add_filter_sqlite(acc, value, sql, transform) do
    acc ++ [{sql, [transform.(value)]}]
  end

  defp add_temporal_filter_sqlite(acc, nil), do: acc

  defp add_temporal_filter_sqlite(acc, :recent) do
    thirty_days_ago = DateTime.add(DateTime.utc_now(), -30 * 24 * 3600, :second)
    acc ++ [{"me.inserted_at >= ?", [DateTime.to_iso8601(thirty_days_ago)]}]
  end

  defp sqlite_tag_placeholders(tags), do: Enum.map_join(tags, ", ", fn _ -> "?" end)

  defp add_tags_all_filter_sqlite(acc, nil), do: acc

  defp add_tags_all_filter_sqlite(acc, tags) when is_list(tags) do
    case Recollect.Knowledge.normalize_tags(tags) do
      [] ->
        acc

      normalized ->
        acc ++
          [
            {"(SELECT count(DISTINCT t.tag) FROM recollect_entry_tags t " <>
               "WHERE t.entry_id = me.id AND t.tag IN (#{sqlite_tag_placeholders(normalized)})) = ?",
             normalized ++ [length(normalized)]}
          ]
    end
  end

  defp add_tags_any_filter_sqlite(acc, nil), do: acc

  defp add_tags_any_filter_sqlite(acc, tags) when is_list(tags) do
    case Recollect.Knowledge.normalize_tags(tags) do
      [] ->
        acc

      normalized ->
        acc ++
          [
            {"EXISTS (SELECT 1 FROM recollect_entry_tags t " <>
               "WHERE t.entry_id = me.id AND t.tag IN (#{sqlite_tag_placeholders(normalized)}))", normalized}
          ]
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp bump_retrieval(results) do
    ids = results |> Enum.map(& &1["id"]) |> Enum.reject(&is_nil/1)
    RetrievalCounter.bump_many(ids)
    Confidence.wake_up_stale_entries(ids)
  end

  defp track_for_outcome(scope_id, results) do
    ids = results |> Enum.map(& &1["id"]) |> Enum.reject(&is_nil/1)
    if ids != [], do: OutcomeTracker.set(scope_id, ids)
  end

  defp add_context_boost(results) do
    current = Detector.detect_cached()

    if map_size(current) == 0 do
      results
    else
      Enum.map(results, fn entry ->
        [entry] |> ContextBooster.apply_boost(current) |> hd()
      end)
    end
  end
end
