defmodule Recollect.Config do
  @moduledoc """
  Runtime configuration resolution for Recollect.

  The host application provides all configuration via `config :recollect`.
  Recollect never starts its own Repo, stores API keys, or makes assumptions
  about the host app's secret management.

  ## Credentials Resolution

  Instead of static API keys, Recollect uses a `:credentials_fn` callback that
  the host app provides. This function is called at runtime to fetch
  credentials from whatever secret system the host app uses.

  ## Example Configuration

      # Homunculus (uses SecretStore)
      config :recollect,
        repo: Homunculus.Repo,
        embedding: [
          provider: Recollect.Embedding.OpenRouter,
          credentials_fn: fn ->
            case Homunculus.SecretStore.get("openrouter", "api_key") do
              {:ok, key} -> %{api_key: key, model: "google/text-embedding-004", dimensions: 768}
              _ -> :disabled
            end
          end
        ]

      # Strategic Change Engine (uses LlmCredential)
      config :recollect,
        repo: StrategicChangeEngine.Repo,
        embedding: [
          provider: Recollect.Embedding.OpenRouter,
          credentials_fn: fn ->
            case StrategicChangeEngine.Admin.LlmCredential.active_for_provider(:openrouter, authorize?: false) do
              {:ok, cred} -> %{api_key: cred.api_key, model: "google/text-embedding-004", dimensions: 768}
              _ -> :disabled
            end
          end
        ]
  """

  @doc "The Ecto Repo module provided by the host app."
  def repo do
    Application.fetch_env!(:recollect, :repo)
  end

  @doc "Table name prefix for all Recollect tables."
  def table_prefix do
    Application.get_env(:recollect, :table_prefix, "recollect_")
  end

  @doc """
  Embedding provider module (implements Recollect.EmbeddingProvider).

  The host application must configure a provider via `config :recollect`.
  """
  def embedding_provider do
    config = Application.get_env(:recollect, :embedding, [])
    Keyword.get(config, :provider)
  end

  @doc """
  Resolve embedding credentials at runtime via the host app's secret system.

  Calls the `:credentials_fn` from config. Returns a map with at minimum
  `:api_key`, plus optional `:model`, `:base_url`, `:dimensions`.

  Returns `:disabled` if no credentials are available.
  """
  def embedding_credentials do
    config = Application.get_env(:recollect, :embedding, [])

    case Keyword.get(config, :credentials_fn) do
      fun when is_function(fun, 0) ->
        fun.()

      nil ->
        static_opts = Keyword.drop(config, [:provider, :credentials_fn])

        cond do
          Keyword.get(static_opts, :api_key) ->
            static_opts |> Map.new() |> Map.put(:api_key, Keyword.get(static_opts, :api_key))

          Keyword.get(static_opts, :mock) == true ->
            Map.new(static_opts)

          true ->
            :disabled
        end
    end
  end

  @doc """
  Build embedding opts by merging resolved credentials with static config.

  This is what gets passed to the embedding provider's generate/2 callback.
  """
  def embedding_opts do
    case embedding_credentials() do
      :disabled ->
        [disabled: true]

      %{} = creds ->
        Map.to_list(creds)
    end
  end

  @doc "Extraction provider module (implements Recollect.ExtractionProvider)."
  def extraction_provider do
    config = Application.get_env(:recollect, :extraction, [])
    Keyword.get(config, :provider, Recollect.Extraction.LlmJson)
  end

  @doc "Extraction provider options (includes llm_fn from host app)."
  def extraction_opts do
    config = Application.get_env(:recollect, :extraction, [])
    Keyword.delete(config, :provider)
  end

  @doc "Embedding vector dimensions (resolved from credentials, static config, or provider default)."
  def dimensions do
    case embedding_credentials() do
      %{dimensions: d} when is_integer(d) ->
        d

      _ ->
        config = Application.get_env(:recollect, :embedding, [])

        Keyword.get(config, :dimensions, provider_default_dimensions())
    end
  end

  defp provider_default_dimensions do
    provider = embedding_provider()

    if function_exported?(provider, :dimensions, 0) do
      provider.dimensions()
    else
      1536
    end
  end

  @doc "The configured database adapter module."
  def adapter do
    Application.get_env(:recollect, :database_adapter, Recollect.DatabaseAdapter.Postgres)
  end

  @doc "Check if embedding is available."
  def embedding_enabled? do
    embedding_provider() != nil && embedding_credentials() != :disabled
  end

  @doc "TaskSupervisor name for async operations."
  def task_supervisor do
    Application.get_env(:recollect, :task_supervisor, Recollect.TaskSupervisor)
  end

  @doc """
  Optional callback invoked when entities or relations are persisted.

  Called by `Recollect.Pipeline.Extractor.persist_entities/2` and
  `persist_relations/3` after successful database operations.

  The host app can set this via `config :recollect, on_graph_change: {mod, fun, args}`
  where the function receives a map like `%{type: :entity | :relation, operation: :insert | :update, data: map}`.

  Returns `:ok` or is ignored if not configured.
  """
  def on_graph_change do
    case Application.get_env(:recollect, :on_graph_change) do
      {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
        fn event -> apply(module, function, args ++ [event]) end

      nil ->
        fn _event -> :ok end
    end
  end
end
