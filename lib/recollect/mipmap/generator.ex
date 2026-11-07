defmodule Recollect.Mipmap do
  @moduledoc """
  Context mipmaps — progressive detail levels for retrieval.

  Stores entries at multiple detail levels:
  - `:full` - Full content
  - `:summary` - First 200 chars + key metadata
  - `:abstract` - Single line + type + tags  
  - `:anchor` - Type + single key term

  ## Usage

      # Generate mipmaps for an entry
      mipmaps = Recollect.Mipmap.generate_for(entry)
      
      # Query at specific level
      {:ok, results} = Recollect.Mipmap.retrieve("auth", scope_id, level: :abstract)
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Pipeline.Embedder
  alias Recollect.Telemetry

  @levels [:anchor, :abstract, :summary, :full]

  @doc """
  Generate mipmap entries for a source entry.

  Tags are passed explicitly (MEM-005): the entries table has no tags column,
  and callers (embedder, remember path) already hold the normalized list.
  """
  def generate_for(entry, tags \\ []) do
    start_time = System.monotonic_time()

    mipmaps = %{
      entry_id: entry.id,
      full: to_full(entry, tags),
      summary: to_summary(entry, tags),
      abstract: to_abstract(entry, tags),
      anchor: to_anchor(entry)
    }

    duration =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    Telemetry.event(
      [:recollect, :mipmap, :generate, :stop],
      %{duration_ms: duration, levels_generated: 4},
      %{entry_id: entry.id}
    )

    mipmaps
  end

  @doc "Store mipmaps for an entry in the database, including embeddings."
  def persist(entry, tags \\ []) do
    mipmaps = generate_for(entry, tags)
    repo = Config.repo()
    adapter = Config.adapter()

    levels = for {level, data} when level != :entry_id <- mipmaps, do: {level, data}

    # One batched embedding call for all four levels instead of four separate
    # calls (MEM-009) — the write path was paying 5 embeddings per remember.
    texts = Enum.map(levels, fn {_level, data} -> data.content end)

    embeddings =
      case Recollect.EmbeddingProvider.generate(texts) do
        {:ok, vectors} when length(vectors) == length(levels) -> vectors
        _ -> nil
      end

    Enum.each(Enum.with_index(levels), fn {{level, data}, idx} ->
      entry_id_bin = Recollect.Util.uuid_to_bin(entry.id)
      # `level` is a text column (an atom crashed the Postgrex encode) and
      # `metadata` is jsonb on Postgres — a pre-encoded JSON string would be
      # stored as a JSON string scalar, not an object.
      level = to_string(level)

      metadata =
        if adapter.dialect() == :postgres, do: data.metadata, else: Jason.encode!(data.metadata)

      repo.query(
        """
          INSERT INTO recollect_mipmaps (entry_id, level, content, metadata)
          VALUES ($1, $2, $3, $4)
          ON CONFLICT (entry_id, level) DO UPDATE SET content = $3, metadata = $4
        """,
        [entry_id_bin, level, data.content, metadata]
      )

      with embeddings when is_list(embeddings) <- embeddings,
           embedding when is_list(embedding) <- Enum.at(embeddings, idx) do
        embedding_value =
          case adapter.dialect() do
            :postgres ->
              if Code.ensure_loaded?(Pgvector),
                do: apply(Pgvector, :new, [embedding]),
                else: adapter.format_embedding(embedding)

            _ ->
              adapter.format_embedding(embedding)
          end

        repo.query(
          "UPDATE recollect_mipmaps SET embedding = $1 WHERE entry_id = $2 AND level = $3",
          [embedding_value, entry_id_bin, level]
        )
      end
    end)

    {:ok, length(levels)}
  end

  @doc """
  Persist mipmaps asynchronously (for use after entry embedding).

  Honors `config :recollect, mipmaps: [mode: ...]` (MEM-009):
  - `:eager` — persist on every write (the old always-on behavior)
  - `:lazy` — skip at write time; `retrieve/3` backfills on first escalation
  - `:off` — never persist
  """
  def persist_async(entry, tags \\ []) do
    if mode() == :eager do
      Task.Supervisor.start_child(
        Config.task_supervisor(),
        fn -> persist(entry, tags) end,
        restart: :temporary
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc "The configured mipmap mode: :off | :lazy | :eager (default :lazy)."
  def mode do
    :recollect
    |> Application.get_env(:mipmaps, [])
    |> case do
      opts when is_list(opts) -> Keyword.get(opts, :mode, :lazy)
      _ -> :lazy
    end
  end

  @doc """
  Retrieve mipmaps at a specific detail level.

  Options: `:level`, `:limit`, and `:query_embedding` — pass the embedding the
  caller already computed for the query (MEM-009) to avoid re-embedding.

  In `:lazy` mode the first retrieval for a scope backfills mipmaps for the
  scope's 200 most recent live entries; later retrievals reuse them.
  `:off` returns an empty result set without touching the database.
  """
  def retrieve(query, scope_id, opts \\ []) do
    if mode() == :off do
      {:ok, [], :off}
    else
      level = Keyword.get(opts, :level, :auto)
      limit = Keyword.get(opts, :limit, 10)

      actual_level =
        if level == :auto do
          determine_level(query)
        else
          level
        end

      # text column: an atom level crashed the Postgrex encode
      level_param = to_string(actual_level)

      repo = Config.repo()
      adapter = Config.adapter()

      maybe_backfill_lazy(scope_id)

      case query_embedding(query, opts) do
        {:ok, embedding} ->
          embedding_str =
            case adapter.format_embedding(embedding) do
              s when is_binary(s) -> s
              _ -> "[#{Enum.map_join(embedding, ",", &Float.to_string/1)}]"
            end

          {sql, params} =
            case adapter.dialect() do
              :postgres ->
                {
                  """
                  SELECT mm.entry_id, mm.level, mm.content, mm.metadata,
                         (1 - (mm.embedding <=> $1::text::vector)) AS score
                  FROM recollect_mipmaps mm
                  JOIN recollect_entries me ON mm.entry_id = me.id
                  WHERE me.scope_id = $2
                    AND me.entry_type != 'archived'
                    AND mm.level = $3
                    AND mm.embedding IS NOT NULL
                  ORDER BY mm.embedding <=> $1::text::vector
                  LIMIT $4
                  """,
                  [embedding_str, Recollect.Util.uuid_to_bin(scope_id), level_param, limit]
                }

              _ ->
                similarity = adapter.vector_similarity_sql("mm.embedding", "?")

                {
                  """
                  SELECT mm.entry_id, mm.level, mm.content, mm.metadata,
                         #{similarity} AS score
                  FROM recollect_mipmaps mm
                  JOIN recollect_entries me ON mm.entry_id = me.id
                  WHERE me.scope_id = ?
                    AND me.entry_type != 'archived'
                    AND mm.level = ?
                    AND mm.embedding IS NOT NULL
                  ORDER BY #{similarity} DESC
                  LIMIT ?
                  """,
                  [embedding_str, scope_id, level_param, limit]
                }
            end

          case repo.query(sql, params) do
            {:ok, %{rows: rows, columns: columns}} ->
              results =
                Enum.map(rows, fn row ->
                  Recollect.Util.row_to_map(columns, row)
                end)

              {:ok, results, actual_level}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp query_embedding(query, opts) do
    case Keyword.get(opts, :query_embedding) do
      embedding when is_list(embedding) -> {:ok, embedding}
      _ -> Embedder.embed_query(query)
    end
  end

  # Lazy mode: mipmaps are not written at remember-time; the first escalation
  # for a scope backfills a bounded batch. Row-level upserts make a
  # concurrent double-backfill idempotent.
  defp maybe_backfill_lazy(scope_id) do
    if mode() == :lazy do
      repo = Config.repo()

      existing =
        repo.query(
          """
            SELECT count(*) FROM recollect_mipmaps mm
            JOIN recollect_entries me ON me.id = mm.entry_id
            WHERE me.scope_id = $1
          """,
          [Recollect.Util.uuid_to_bin(scope_id)]
        )

      case existing do
        {:ok, %{rows: [[0]]}} ->
          entries =
            repo.all(
              from(e in Recollect.Schema.Entry,
                where: e.scope_id == ^scope_id and e.entry_type != "archived",
                order_by: [desc: e.inserted_at],
                limit: 200
              )
            )

          Enum.each(entries, fn entry ->
            persist(entry, Recollect.Knowledge.tags(entry.id))
          end)

        _ ->
          :ok
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc "Determine appropriate mipmap level for a query."
  def determine_level(query) do
    query_length = String.length(query)

    cond do
      query_length < 50 -> :abstract
      query_length < 200 -> :summary
      true -> :full
    end
  end

  @doc "Get available mipmap levels."
  def levels, do: @levels

  # Private: Level transformations

  defp to_full(entry, tags) do
    %{
      content: entry.content,
      metadata: %{
        entry_type: entry.entry_type,
        tags: tags || [],
        emotional_valence: entry.emotional_valence
      }
    }
  end

  defp to_summary(entry, tags) do
    content =
      entry.content
      |> String.slice(0, 200)
      |> String.trim()

    metadata = %{
      entry_type: entry.entry_type,
      tags: Enum.take(tags || [], 5),
      emotional_valence: entry.emotional_valence
    }

    %{content: content, metadata: metadata}
  end

  defp to_abstract(entry, tags) do
    first_line =
      entry.content
      |> String.split("\n")
      |> hd()
      |> String.slice(0, 100)
      |> String.trim()

    metadata = %{
      entry_type: entry.entry_type,
      tags: Enum.take(tags || [], 3)
    }

    %{content: first_line, metadata: metadata}
  end

  defp to_anchor(entry) do
    key_term = extract_key_term(entry.content)

    metadata = %{
      type: entry.entry_type
    }

    %{content: key_term, metadata: metadata}
  end

  defp extract_key_term(content) do
    content
    |> String.split()
    |> Enum.find(fn w -> String.length(w) > 4 end)
    |> Kernel.||(String.slice(content, 0, 20))
  end
end
