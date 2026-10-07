defmodule Recollect.Maintenance.Reembed do
  @moduledoc """
  Re-embeds entries, chunks, and entities using a pluggable embedding
  function and tracks per-row provenance via `embedding_model_id`.

  ## Options

    * `:embedding_fn` — `(text -> {:ok, vector, model_id} | {:ok, vector} | {:error, term})`
      called per row. Defaults to a function that delegates to the
      configured `Recollect.EmbeddingProvider` (existing behavior).
    * `:progress_callback` — `(progress_map -> :ok)` invoked per batch
      with `%{table:, processed:, total:, current_batch:}`.
    * `:batch_size` — rows per batch (default: `100`).
    * `:concurrency` — parallel embedding tasks per batch (default: `2`).
    * `:tables` — which tables to re-embed (default: all three).
    * `:scope` — what to select for re-embedding:
        * `:nil_only` (default) — rows where `embedding IS NULL`
        * `:all` — every row in the table
        * `{:stale_model, current_model_id}` — rows whose stored
          `embedding_model_id` differs from `current_model_id` or is NULL
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.EmbeddingProvider

  require Logger

  @default_tables ["recollect_chunks", "recollect_entries", "recollect_entities"]

  @doc """
  Re-embeds rows in the specified tables according to the given scope.

  See module documentation for available options.
  """
  def run(opts \\ []) do
    embedding_fn = Keyword.get(opts, :embedding_fn, &default_embedding_fn/1)
    progress_callback = Keyword.get(opts, :progress_callback, fn _ -> :ok end)
    batch_size = Keyword.get(opts, :batch_size, 100)
    concurrency = Keyword.get(opts, :concurrency, 2)
    tables = Keyword.get(opts, :tables, @default_tables)
    scope = Keyword.get(opts, :scope, :nil_only)
    repo = Config.repo()

    total =
      Enum.reduce(tables, 0, fn table, acc ->
        {:ok, count} = reembed_table(table, repo, batch_size, concurrency, scope, embedding_fn, progress_callback)
        acc + count
      end)

    Logger.info("Recollect.Reembed: re-embedded #{total} records")

    if Keyword.get(opts, :regenerate_mipmaps, false) and "recollect_entries" in tables do
      regenerate_mipmaps(repo)
    end

    {:ok, total}
  end

  defp reembed_table(table, repo, batch_size, _concurrency, scope, embedding_fn, progress_callback) do
    base = scope_query(table, scope)
    total = repo.aggregate(base, :count, :id)

    rows =
      repo.all(from(e in base, select: %{id: e.id, content: e.content}))

    {processed, _} =
      rows
      |> Enum.chunk_every(batch_size)
      |> Enum.reduce({0, 0}, fn batch, {acc, _} ->
        processed_in_batch =
          Enum.reduce(batch, 0, fn %{id: id, content: content}, count ->
            case embedding_fn.(content) do
              {:ok, embedding, model_id} ->
                write_row(repo, table, id, embedding, model_id)
                count + 1

              {:ok, embedding} ->
                write_row(repo, table, id, embedding, nil)
                count + 1

              _ ->
                count
            end
          end)

        new_total = acc + processed_in_batch

        progress_callback.(%{
          table: table,
          processed: new_total,
          total: total,
          current_batch: processed_in_batch
        })

        {new_total, processed_in_batch}
      end)

    {:ok, processed}
  end

  defp scope_query(table, :nil_only) do
    from(e in table, where: is_nil(e.embedding), order_by: [desc: e.inserted_at])
  end

  defp scope_query(table, :all) do
    from(e in table, order_by: [desc: e.inserted_at])
  end

  defp scope_query(table, {:stale_model, current_id}) when is_binary(current_id) do
    from(e in table,
      where: is_nil(e.embedding) or e.embedding_model_id != ^current_id or is_nil(e.embedding_model_id),
      order_by: [desc: e.inserted_at]
    )
  end

  defp write_row(repo, table, id, embedding, model_id) do
    adapter = Config.adapter()
    formatted = adapter.format_embedding(embedding)

    case adapter.dialect() do
      :postgres ->
        pgvec = if Code.ensure_loaded?(Pgvector), do: apply(Pgvector, :new, [embedding]), else: formatted
        id_bin = Recollect.Util.uuid_to_bin(id)

        repo.query(
          "UPDATE #{table} SET embedding = $1, embedding_model_id = $2 WHERE id = $3",
          [pgvec, model_id, id_bin]
        )

      _ ->
        repo.query(
          "UPDATE #{table} SET embedding = ?, embedding_model_id = ? WHERE id = ?",
          [formatted, model_id, id]
        )
    end
  end

  defp default_embedding_fn(content) do
    case EmbeddingProvider.embed(content) do
      {:ok, embedding} -> {:ok, embedding, EmbeddingProvider.model_id()}
      other -> other
    end
  end

  defp regenerate_mipmaps(repo) do
    case repo.query(
           "SELECT id, content, entry_type, emotional_valence FROM recollect_entries WHERE embedding IS NOT NULL LIMIT 500",
           []
         ) do
      {:ok, %{rows: rows}} ->
        entries =
          Enum.map(rows, fn [id, content, entry_type, valence] ->
            %{id: id, content: content, entry_type: entry_type, tags: [], emotional_valence: valence}
          end)

        Enum.each(entries, fn entry ->
          try do
            Recollect.Mipmap.persist(entry)
          rescue
            _ -> :ok
          end
        end)

        Logger.info("Recollect.Reembed: regenerated mipmaps for #{length(entries)} entries")

      _ ->
        :ok
    end
  end
end
