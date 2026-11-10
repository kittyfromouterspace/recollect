defmodule Recollect.Embedding.Local do
  @moduledoc """
  Local embedding provider using Bumblebee with sentence-transformers/all-MiniLM-L6-v2.

  This is the default embedding provider for Recollect. It runs entirely
  locally — no API keys or external services required. Model weights are
  downloaded from HuggingFace Hub on first use and cached on disk.

  ## Requirements

  Add to your `mix.exs` dependencies:

      {:bumblebee, "~> 0.6.0"}

  ## Configuration

  The local provider is used by default when no other provider is
  configured. You can explicitly select it:

      config :recollect,
        embedding: [
          provider: Recollect.Embedding.Local
        ]

  Options can be passed via `:local_embedding`:

      config :recollect, :local_embedding,
        model: "sentence-transformers/all-MiniLM-L6-v2",
        compile: [batch_size: 32, sequence_length: 128]

  ## Overriding with another provider

  To use a different embedding provider (e.g. an API-based one), set
  the `:provider` key:

      config :recollect,
        embedding: [
          provider: Recollect.Embedding.OpenRouter,
          credentials_fn: fn ->
            %{api_key: "...", model: "google/text-embedding-004", dimensions: 768}
          end
        ]
  """

  @behaviour Recollect.EmbeddingProvider

  @dimensions 384
  @model_id "all-MiniLM-L6-v2"

  @deps_available match?({:module, _}, Code.ensure_compiled(Bumblebee)) and
                    match?({:module, _}, Code.ensure_compiled(Nx))

  @doc "The registered name of the Nx.Serving process."
  def serving_name, do: __MODULE__.Serving

  @doc "Returns the embedding dimensions for the configured model."
  def dimensions, do: @dimensions

  @doc """
  Build the Nx.Serving for the embedding model.

  Called by the Recollect application supervisor during startup. Downloads
  model weights from HuggingFace Hub on first call (cached afterward).

  Returns `{:ok, serving}` or `{:error, reason}`.
  """
  if @deps_available do
    @default_model "sentence-transformers/all-MiniLM-L6-v2"

    def build_serving do
      do_build_serving()
    end

    defp do_build_serving do
      config = Application.get_env(:recollect, :local_embedding, [])
      model_id = Keyword.get(config, :model, @default_model)
      compile = Keyword.get(config, :compile, batch_size: 32, sequence_length: 128)
      defn_options = Keyword.get(config, :defn_options, default_defn_options())

      with {:ok, model_info} <- Bumblebee.load_model({:hf, model_id}),
           {:ok, tokenizer} <- Bumblebee.load_tokenizer({:hf, model_id}) do
        {_init_fun, encoder} = Axon.build(model_info.model)

        embedding_fun = fn params, inputs ->
          output = encoder.(params, inputs)

          embedding =
            case output do
              %{pooled_state: pooled} -> pooled
              %{hidden_state: hidden} -> hidden
              other -> other
            end

          Bumblebee.Utils.Nx.normalize(embedding)
        end

        batch_size = Keyword.get(compile, :batch_size, 32)
        sequence_length = Keyword.get(compile, :sequence_length, 128)

        tokenizer =
          Bumblebee.configure(tokenizer,
            length: sequence_length,
            return_token_type_ids: false
          )

        serving =
          fn _batch_key, defn_options ->
            embedding_fun =
              Nx.Defn.compile(
                embedding_fun,
                [
                  model_info.params,
                  %{
                    "input_ids" => Nx.template({batch_size, sequence_length}, :u32),
                    "attention_mask" => Nx.template({batch_size, sequence_length}, :u32)
                  }
                ],
                defn_options
              )

            fn inputs ->
              inputs = Bumblebee.Shared.maybe_pad(inputs, batch_size)

              model_info.params
              |> embedding_fun.(inputs)
              |> Bumblebee.Shared.serving_post_computation()
            end
          end
          |> Nx.Serving.new(defn_options)
          |> Nx.Serving.batch_size(batch_size)
          |> Nx.Serving.client_preprocessing(fn input ->
            {texts, multi?} =
              Bumblebee.Shared.validate_serving_input!(input, &Bumblebee.Shared.validate_string/1)

            inputs =
              Nx.with_default_backend(Nx.BinaryBackend, fn ->
                Bumblebee.apply_tokenizer(tokenizer, texts)
              end)

            batch = Nx.Batch.concatenate([inputs])
            {batch, multi?}
          end)
          |> Nx.Serving.client_postprocessing(fn {embeddings, _metadata}, multi? ->
            for_result =
              for embedding <- Bumblebee.Utils.Nx.batch_to_list(embeddings) do
                %{embedding: embedding}
              end

            Bumblebee.Shared.normalize_output(for_result, multi?)
          end)

        {:ok, serving}
      end
    end

    defp default_defn_options do
      []
    end

    @impl true
    def generate(texts, _opts) when is_list(texts) do
      if serving_running?() do
        %{embedding: tensor} = Nx.Serving.batched_run(serving_name(), texts)
        n = elem(Nx.shape(tensor), 0)
        embeddings = for i <- 0..(n - 1), do: Nx.to_flat_list(tensor[i])
        {:ok, embeddings}
      else
        {:error, "Local embedding serving is not running. Ensure :bumblebee is in your dependencies."}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end

    @impl true
    def embed(text, opts) do
      case generate([text], opts) do
        {:ok, [embedding]} -> {:ok, embedding}
        {:error, reason} -> {:error, reason}
      end
    end

    defp serving_running? do
      case GenServer.whereis(serving_name()) do
        nil -> false
        _pid -> true
      end
    end
  else
    def build_serving do
      {:error, ":bumblebee is not installed. Add it to your mix.exs dependencies to use Recollect.Embedding.Local."}
    end

    @impl true
    def generate(_texts, _opts) do
      {:error, ":bumblebee is not installed. Add it to your mix.exs dependencies to use Recollect.Embedding.Local."}
    end

    @impl true
    def embed(_text, _opts) do
      {:error, ":bumblebee is not installed. Add it to your mix.exs dependencies to use Recollect.Embedding.Local."}
    end
  end

  @impl true
  def dimensions(_opts), do: @dimensions

  @impl true
  def model_id(_opts), do: @model_id
end
