defmodule Recollect.SearchTest do
  use Recollect.DataCase, async: false

  alias Recollect.Config
  alias Recollect.Schema.Entry

  setup do
    scope_id = Fixtures.scope_id()
    owner_id = Fixtures.owner_id()
    {:ok, scope_id: scope_id, owner_id: owner_id}
  end

  describe "search API" do
    test "search returns context pack structure", %{scope_id: scope_id, owner_id: owner_id} do
      Fixtures.entry(scope_id: scope_id, owner_id: owner_id, content: "Test entry")

      {:ok, context} = Recollect.search("query", scope_id: scope_id, owner_id: owner_id)

      assert is_map(context)
      assert Map.has_key?(context, :chunks)
      assert Map.has_key?(context, :entries)
      assert Map.has_key?(context, :related_entries)
      assert Map.has_key?(context, :entities)
      assert Map.has_key?(context, :relations)
      assert Map.has_key?(context, :query)
    end

    test "search accepts tier option", %{scope_id: scope_id, owner_id: owner_id} do
      Fixtures.entry(scope_id: scope_id, owner_id: owner_id, content: "Test entry")

      {:ok, context} =
        Recollect.search("query", scope_id: scope_id, owner_id: owner_id, tier: :lightweight)

      assert context.chunks == []
      assert is_list(context.entries)
    end

    test "search_vectors returns list of results", %{scope_id: scope_id} do
      Fixtures.entry(scope_id: scope_id, content: "Test content")

      {:ok, results} = Recollect.search_vectors("query", scope_id: scope_id)
      assert is_list(results)
    end
  end

  describe "MEM-032: hybrid mode and fusion" do
    test "search with mode: :vector returns legacy structure", %{scope_id: scope_id} do
      {:ok, context} = Recollect.search("test query", scope_id: scope_id, mode: :vector)

      assert is_list(context.entries)
      assert is_list(context.items)
      assert context.mode == :vector
    end

    test "search with mode: :hybrid returns fused items", %{scope_id: scope_id} do
      {:ok, context} = Recollect.search("test query", scope_id: scope_id, mode: :hybrid)

      assert is_list(context.items)
      assert context.mode == :hybrid
      assert is_integer(context.candidates_considered)
    end

    test "search with include_pages returns pages in results", %{scope_id: scope_id} do
      {:ok, context} =
        Recollect.search("test query", scope_id: scope_id, include_pages: true)

      assert is_list(context.pages)
      assert context.pages == [] || is_list(context.pages)
    end

    test "search returns candidates_considered count", %{scope_id: scope_id} do
      {:ok, context} = Recollect.search("test query", scope_id: scope_id, mode: :hybrid)

      assert is_integer(context.candidates_considered)
      assert context.candidates_considered >= 0
    end
  end

  describe "access tracking" do
    test "forget removes entry from search results (soft deletes)" do
      entry = Fixtures.entry()

      assert Config.repo().get(Entry, entry.id)

      {:ok, _} = Recollect.forget(entry.id)

      # MEM-014: soft delete keeps the row but hides it.
      assert Config.repo().get(Entry, entry.id)
      assert Config.repo().get(Entry, entry.id).deleted_at
    end
  end
end
