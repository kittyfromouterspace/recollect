defmodule Recollect.Embedding.CountingMock do
  @moduledoc false
  # Embedding provider that delegates to Recollect.Embedding.Mock and counts
  # calls in a public ETS table — lets tests assert how many embedding calls
  # a code path actually makes (e.g. MEM-009's batching).
  @behaviour Recollect.EmbeddingProvider

  alias Recollect.Embedding.Mock

  @table :counting_mock_calls

  def init_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    reset()
  end

  def reset do
    :ets.insert(@table, {:generate_calls, 0})
    :ets.insert(@table, {:embed_calls, 0})
    :ets.insert(@table, {:texts_embedded, 0})
  end

  def counts do
    %{
      generate: lookup(:generate_calls),
      embed: lookup(:embed_calls),
      texts: lookup(:texts_embedded)
    }
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, n}] -> n
      [] -> 0
    end
  end

  @impl true
  def dimensions(opts), do: Mock.dimensions(opts)

  @impl true
  def generate(texts, opts) do
    bump(:generate_calls, 1)
    bump(:texts_embedded, length(texts))
    Mock.generate(texts, opts)
  end

  @impl true
  def embed(text, opts) do
    bump(:embed_calls, 1)
    bump(:texts_embedded, 1)
    Mock.embed(text, opts)
  end

  @impl true
  def model_id(opts), do: Mock.model_id(opts)

  defp bump(key, n) do
    :ets.update_counter(@table, key, n, {key, 0})
  rescue
    _ -> :ok
  end
end
