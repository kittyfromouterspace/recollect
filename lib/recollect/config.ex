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

  alias Recollect.Extraction.LlmJson

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
    case Application.get_env(:recollect, :embedding, []) do
      config when is_list(config) -> Keyword.get(config, :provider)
      _ -> nil
    end
  end

  @doc """
  Resolve embedding credentials at runtime via the host app's secret system.

  Calls the `:credentials_fn` from config. Returns a map with at minimum
  `:api_key`, plus optional `:model`, `:base_url`, `:dimensions`.

  Returns `:disabled` if no credentials are available.
  """
  def embedding_credentials do
    case Application.get_env(:recollect, :embedding, []) do
      config when is_list(config) ->
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

      _ ->
        :disabled
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
    case Application.get_env(:recollect, :extraction, []) do
      config when is_list(config) -> Keyword.get(config, :provider, LlmJson)
      _ -> LlmJson
    end
  end

  @doc "Extraction provider options (includes llm_fn from host app)."
  def extraction_opts do
    case Application.get_env(:recollect, :extraction, []) do
      opts when is_list(opts) -> Keyword.delete(opts, :provider)
      _ -> []
    end
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

  @doc """
  Check if entity/relation extraction is available.

  The built-in `Recollect.Extraction.LlmJson` provider needs a host-supplied
  `:llm_fn`; without one, the pipeline skips extraction cleanly instead of
  failing per chunk. A custom provider configured with no `:llm_fn` is
  assumed self-sufficient (enabled).
  """
  def extraction_enabled? do
    provider = extraction_provider()
    opts = extraction_opts()

    cond do
      is_nil(provider) -> false
      provider == LlmJson -> is_function(Keyword.get(opts, :llm_fn))
      true -> true
    end
  end

  @doc "TaskSupervisor name for async operations."
  def task_supervisor do
    Application.get_env(:recollect, :task_supervisor, Recollect.TaskSupervisor)
  end

  @doc """
  Consecutive pipeline failures before a document is quarantined.

  Configure via `config :recollect, max_failed_attempts: 5`. Default: 3.
  """
  def max_failed_attempts do
    Application.get_env(:recollect, :max_failed_attempts, 3)
  end

  @doc """
  Event ledger options (`config :recollect, events: [...]`).

  Recognized keys:

  - `:retention_days` — ledger GC horizon used by `Recollect.Event.prune/1` (default 30)
  - `:enabled` — whether the learning pipeline records events (used by MEM-016)
  - `:max_content_bytes` — per-event content cap (used by MEM-016)
  """
  def events do
    Application.get_env(:recollect, :events, [])
  end

  @doc "The `:staging` option group (`config :recollect, staging: [...]`).
  Recognized keys: `:retention_days` (drained-row GC horizon, default 7)
  and `:max_items` (per-scope staged backlog cap, default 1000)."
  def staging do
    Application.get_env(:recollect, :staging, [])
  end

  @doc "The `:pages` option group (`config :recollect, pages: [...]`).

  Recognized keys: `:enabled` (page synthesis stage toggle, default false),
  `:compression_ratio` (MEM-029 guard, default 0.5), and
  `:max_pages_per_scope` (MEM-029 cap, default 100)."
  def pages do
    Application.get_env(:recollect, :pages, [])
  end

  @doc "The `:dream` option group (`config :recollect, dream: [...]`).

  Recognized keys: `:enabled` (dream toggle), `:max_wall_ms` (run wall
  budget, default 30000), `:lock_wait_ms` (advisory-lock wait, default 0
  = try-only), `:max_items` (per-stage item cap passed to stages)."
  def dream do
    Application.get_env(:recollect, :dream, [])
  end

  @doc "The `:brief` option group (`config :recollect, brief: [...]`).

  Recognized keys: `:token_budget` (handoff budget checks, default 1500),
  `:max_items_per_section` (working-memory handoff loading, default 5),
  `:enabled` (brief toggle, used by hosts)."
  def brief do
    Application.get_env(:recollect, :brief, [])
  end

  @doc """
  Optional exact tokenizer for budget math (`config :recollect,
  tokenizer_fn: &MyTokenizer.count/1`), a 1-arity fun from text to token
  count. When unset, `Recollect.Tokenizer` falls back to `ceil(chars / 4)`.
  """
  def tokenizer_fn do
    Application.get_env(:recollect, :tokenizer_fn)
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
