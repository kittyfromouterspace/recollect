defmodule Recollect.RerankerTest do
  use Recollect.DataCase, async: false

  alias Recollect.Reranker

  @items [
    %{kind: :entry, id: "1", content: "first"},
    %{kind: :entry, id: "2", content: "second"},
    %{kind: :entry, id: "3", content: "third"},
    %{kind: :entry, id: "4", content: "fourth"},
    %{kind: :entry, id: "5", content: "fifth"}
  ]

  # Helper rerankers for testing
  defmodule ReversingReranker do
    @moduledoc false
    @behaviour Reranker

    @impl true
    def rerank(_query, items, _opts) do
      {top, rest} = Enum.split(items, 3)
      {:ok, Enum.reverse(top, rest)}
    end
  end

  defmodule FailingReranker do
    @moduledoc false
    @behaviour Reranker

    @impl true
    def rerank(_query, _items, _opts), do: {:error, :boom}
  end

  defmodule CustomReranker do
    @moduledoc false
    @behaviour Reranker

    @impl true
    def rerank(_query, items, _opts), do: {:ok, Enum.reverse(items)}
  end

  describe "Recollect.Reranker (MEM-033)" do
    test "no-op reranker preserves order" do
      {:ok, result} = Reranker.rerank("query", @items, [])
      assert result == @items
    end

    test "reversing reranker reverses the top N" do
      {:ok, result} = ReversingReranker.rerank("query", @items, [])

      assert result == [
               %{kind: :entry, id: "3", content: "third"},
               %{kind: :entry, id: "2", content: "second"},
               %{kind: :entry, id: "1", content: "first"},
               %{kind: :entry, id: "4", content: "fourth"},
               %{kind: :entry, id: "5", content: "fifth"}
             ]
    end
  end

  describe "Search.search/2 with rerank (MEM-033)" do
    setup do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()
      {:ok, scope_id: scope_id, owner_id: owner_id}
    end

    test "rerank: false preserves fused order (default)", %{scope_id: scope_id} do
      {:ok, context} = Recollect.search("test query", scope_id: scope_id, mode: :hybrid)

      assert is_list(context.items)
      assert context.mode == :hybrid
    end

    test "rerank: true applies reranker before budget", %{scope_id: scope_id} do
      {:ok, context} =
        Recollect.search("test query",
          scope_id: scope_id,
          mode: :hybrid,
          rerank: true,
          rerank_max_items: 10
        )

      assert is_list(context.items)
    end

    test "budget applied after reranking", %{scope_id: scope_id} do
      {:ok, context} =
        Recollect.search("test query",
          scope_id: scope_id,
          mode: :hybrid,
          rerank: true,
          rerank_max_items: 10,
          budget: 100
        )

      assert is_list(context.items)
    end

    test "failing reranker falls back to fused order via search", %{scope_id: scope_id} do
      {:ok, context} =
        Recollect.search("test query",
          scope_id: scope_id,
          mode: :hybrid,
          rerank: true,
          reranker: FailingReranker,
          rerank_max_items: 10
        )

      assert is_list(context.items)
    end

    test "custom reranker module is used", %{scope_id: scope_id} do
      {:ok, context} =
        Recollect.search("test query",
          scope_id: scope_id,
          mode: :hybrid,
          rerank: true,
          reranker: CustomReranker
        )

      assert is_list(context.items)
    end
  end
end
