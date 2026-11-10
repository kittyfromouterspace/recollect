defmodule Recollect.Reranker do
  @moduledoc """
  Optional reranker behaviour for hybrid search (MEM-033).

  RRF is robust but not semantic. Hosts can plug in a cross-encoder or LLM
  reranker to re-order fused results before the token budget is applied.

  ## Behaviour

      defmodule MyReranker do
        @behaviour Recollect.Reranker

        @impl true
        def rerank(query, items, opts) do
          # Re-order items based on query semantics
          {:ok, reordered}
        end
      end

  ## Configuration

      config :recollect,
        retrieval: [
          rerank: true,          # enable reranking (default: false)
          reranker: MyReranker,  # reranker module (default: Recollect.Reranker)
          rerank_max_items: 20   # max items to send to reranker (default: 50)
        ]

  Reranking is off by default. When `rerank: true`, the top `rerank_max_items`
  fused results are sent to the reranker before the token budget is applied.
  If the reranker errors, the fused order is preserved as a fallback.
  """

  @behaviour Recollect.Reranker

  @callback rerank(query :: String.t(), items :: list(), opts :: keyword()) ::
              {:ok, list()} | {:error, term()}

  @doc """
  No-op reranker — preserves the fused order unchanged.

  This is the default implementation when no custom reranker is configured.
  """
  @impl true
  def rerank(_query, items, _opts) do
    {:ok, items}
  end
end
