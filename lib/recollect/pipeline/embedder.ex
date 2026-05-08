defmodule Recollect.Pipeline.Embedder do
  @moduledoc """
  Embeds chunks and entities using the configured embedding provider.
  Supports batch processing and async embedding via TaskSupervisor.
  """

  alias Recollect.Config
  alias Recollect.EmbeddingProvider
  alias Recollect.Schema.Entity

  require Logger

  @doc """
  Embed a list of chunks. Updates embedding column via direct SQL.

  Returns `{:ok, chunks}` with embeddings populated.
  """
  def embed_chunks(chunks) when is_list(chunks) do
    start_time = System.monotonic_time()
    texts = Enum.map(chunks, & &1.content)
    model_id = EmbeddingProvider.model_id()

    result =
      case EmbeddingProvider.generate(texts) do
        {:ok, embeddings} ->
          repo = Config.repo()

          updated =
            chunks
            |> Enum.zip(embeddings)
            |> Enum.map(fn {chunk, embedding} ->
              store_embedding(repo, "recollect_chunks", chunk.id, embedding, model_id)
              %{chunk | embedding: embedding}
            end)

          {:ok, updated}

        {:error, reason} ->
          Logger.error("Recollect.Embedder: chunk embedding failed: #{inspect(reason)}")
          {:error, reason}
      end

    duration = System.monotonic_time() - start_time

    Recollect.Telemetry.event([:recollect, :embed, :stop], %{
      duration: duration,
      count: length(chunks),
      provider: Config.embedding_provider()
    })

    result
  end

  @doc "Embed a single entity's name + description."
  def embed_entity(%Entity{} = entity) do
    start_time = System.monotonic_time()
    text = "#{entity.name}: #{entity.description || ""}"
    model_id = EmbeddingProvider.model_id()

    result =
      case EmbeddingProvider.embed(text) do
        {:ok, embedding} ->
          repo = Config.repo()
          store_embedding(repo, "recollect_entities", entity.id, embedding, model_id)
          {:ok, %{entity | embedding: embedding}}

        {:error, reason} ->
          Logger.warning("Recollect.Embedder: entity embedding failed for #{entity.id}: #{inspect(reason)}")

          {:error, reason}
      end

    duration = System.monotonic_time() - start_time

    Recollect.Telemetry.event([:recollect, :embed, :stop], %{
      duration: duration,
      count: 1,
      provider: Config.embedding_provider()
    })

    result
  end

  @doc "Embed a single entry asynchronously. No-op if embedding is disabled."
  def embed_entry_async(%{id: entry_id, content: content}) when is_binary(content) do
    if !Config.embedding_enabled?(), do: throw(:disabled)

    Task.Supervisor.start_child(
      Config.task_supervisor(),
      fn ->
        start_time = System.monotonic_time()
        model_id = EmbeddingProvider.model_id()

        result =
          case EmbeddingProvider.embed(content) do
            {:ok, embedding} ->
              store_embedding(Config.repo(), "recollect_entries", entry_id, embedding, model_id)

              try do
                repo = Config.repo()

                entry =
                  "SELECT id, content, entry_type, tags, emotional_valence FROM recollect_entries WHERE id = $1"
                  |> repo.query([Recollect.Util.uuid_to_bin(entry_id)])
                  |> case do
                    {:ok, %{rows: [[id, content, entry_type, tags, valence]], columns: _cols}} ->
                      %{id: id, content: content, entry_type: entry_type, tags: tags, emotional_valence: valence}

                    _ ->
                      nil
                  end

                if entry, do: Recollect.Mipmap.persist_async(entry)
              rescue
                _ -> :ok
              end

            {:error, reason} ->
              Logger.warning("Recollect.Embedder: entry embedding failed for #{entry_id}: #{inspect(reason)}")
          end

        duration = System.monotonic_time() - start_time

        Recollect.Telemetry.event([:recollect, :embed, :stop], %{
          duration: duration,
          count: 1,
          provider: Config.embedding_provider()
        })

        result
      end,
      restart: :temporary
    )
  rescue
    _ -> :ok
  catch
    :disabled -> :ok
  end

  def embed_entry_async(_), do: :ok

  @doc "Embed a query string for search (no storage)."
  def embed_query(text) do
    start_time = System.monotonic_time()
    result = EmbeddingProvider.embed(text)
    duration = System.monotonic_time() - start_time

    Recollect.Telemetry.event([:recollect, :embed, :stop], %{
      duration: duration,
      count: 1,
      provider: Config.embedding_provider()
    })

    result
  end

  defp store_embedding(repo, table, id, embedding, model_id) do
    adapter = Config.adapter()
    formatted = adapter.format_embedding(embedding)

    {query, params} =
      case adapter.dialect() do
        :postgres ->
          pgvec = if Code.ensure_loaded?(Pgvector), do: apply(Pgvector, :new, [embedding]), else: formatted
          id_bin = Recollect.Util.uuid_to_bin(id)
          {"UPDATE #{table} SET embedding = $1, embedding_model_id = $2 WHERE id = $3", [pgvec, model_id, id_bin]}

        _ ->
          {"UPDATE #{table} SET embedding = ?, embedding_model_id = ? WHERE id = ?", [formatted, model_id, id]}
      end

    case repo.query(query, params) do
      {:ok, _} ->
        :ok

      {:error, %DBConnection.OwnershipError{}} ->
        :ok

      {:error, reason} ->
        Logger.warning("Recollect.Embedder: failed to store embedding for #{id}: #{inspect(reason)}")
    end
  rescue
    DBConnection.ConnectionError ->
      :ok
  end
end
