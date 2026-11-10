defmodule Recollect.Search.Lexical do
  @moduledoc """
  Lexical (full-text) search over entries.

  Uses PostgreSQL tsvector/GIN or SQLite FTS5 depending on the configured
  database adapter. Returns entries with `:lexical_score` and
  `source: :lexical`.

  Dialect-branched: PostgreSQL uses tsvector/GIN; SQLite/libSQL uses FTS5.

  Gated behind `config :recollect, :retrieval, mode: :lexical` or
  `:hybrid` — vector-only mode skips lexical search entirely.
  """

  alias Recollect.Config

  require Logger

  @doc """
  Search entries lexically by full-text match.

  ## Options
  - `:scope_id` — UUID to scope search (required)
  - `:limit` — Max results (default: 10)
  - `:min_score` — Minimum relevance score (default: 0.0)

  Returns `{:ok, results}` where each result is a map with `:id`, `:content`,
  `:summary`, `:entry_type`, `:lexical_score`, `:source: :lexical`.
  """
  def search(query_text, scope_id, opts \\ []) do
    scope_id = Recollect.Util.uuid_to_string(scope_id)
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)

    case Config.adapter().dialect() do
      :postgres ->
        search_postgres(query_text, scope_id, limit, min_score)

      :sqlite ->
        search_sqlite(query_text, scope_id, limit, min_score)

      :libsql ->
        {:error, :unsupported_backend}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp search_postgres(query_text, scope_id, limit, min_score) do
    repo = Config.repo()

    sql = """
    SELECT
      me.id, me.content, me.summary, me.entry_type, me.source, me.source_id,
      me.metadata, me.confidence, me.inserted_at,
      me.half_life_days, me.pinned, me.emotional_valence, me.access_count,
      me.last_accessed_at, me.context_hints,
      ts_rank_cd(me.search_vector, plainto_tsquery('english', $2)) AS lexical_score
    FROM recollect_entries me
    WHERE me.scope_id = $1
      AND me.search_vector @@ plainto_tsquery('english', $2)
      AND ts_rank_cd(me.search_vector, plainto_tsquery('english', $2)) >= $3
    ORDER BY lexical_score DESC
    LIMIT #{limit}
    """

    case repo.query(sql, [Recollect.Util.uuid_to_bin(scope_id), query_text, min_score]) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> Recollect.Util.row_to_map(columns, row) end)}

      {:error, reason} ->
        Logger.error("Recollect.Search.Lexical: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp search_sqlite(query_text, scope_id, limit, min_score) do
    repo = Config.repo()

    sql = """
    SELECT
      e.id, e.content, e.summary, e.entry_type, e.source, e.source_id,
      e.metadata, e.confidence, e.inserted_at,
      e.half_life_days, e.pinned, e.emotional_valence, e.access_count,
      e.last_accessed_at, e.context_hints,
      bm25(recollect_entries_fts) AS lexical_score
    FROM recollect_entries_fts fts
    JOIN recollect_entries e ON e.id = fts.entry_id
    WHERE e.scope_id = ?
      AND fts MATCH ?
      AND bm25(recollect_entries_fts) <= ?
    ORDER BY lexical_score
    LIMIT #{limit}
    """

    case repo.query(sql, [scope_id, query_text, min_score]) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> Recollect.Util.row_to_map(columns, row) end)}

      {:error, reason} ->
        Logger.error("Recollect.Search.Lexical: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
