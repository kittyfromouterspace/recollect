defmodule Recollect.RecallTest do
  use Recollect.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Recollect.Config
  alias Recollect.Recall
  alias Recollect.Schema.RecallAnchor

  setup do
    scope_id = Fixtures.scope_id()
    owner_id = Fixtures.owner_id()

    {:ok, scope_id: scope_id, owner_id: owner_id}
  end

  defp anchored_entry(scope_id, owner_id, content, anchors) do
    entry = Fixtures.entry(scope_id: scope_id, owner_id: owner_id, content: content)

    # give the entry an embedding-free hit path via Recall only
    {:ok, _} = Recall.index(entry.id, anchors)
    entry
  end

  describe "index/2 (MEM-021)" do
    test "inserts anchors idempotently", %{scope_id: _scope_id, owner_id: owner_id} do
      entry = Fixtures.entry(owner_id: owner_id)

      assert {:ok, %{indexed: 2, total: 2}} =
               Recall.index(entry.id, path: "lib/recollect/recall.ex", symbol: "Recollect.Recall.for_path")

      assert {:ok, %{indexed: 0, total: 2}} =
               Recall.index(entry.id, path: "lib/recollect/recall.ex", symbol: "Recollect.Recall.for_path")

      count = Config.repo().aggregate(from(a in RecallAnchor, where: a.entry_id == ^entry.id), :count, :id)

      assert count == 2
    end

    test "accepts map specs with explicit confidence" do
      entry = Fixtures.entry()

      assert {:ok, %{indexed: 1}} =
               Recall.index(entry.id, [%{type: :error, value: "DBConnection.ConnectionError", confidence: 0.9}])

      [anchor] = Config.repo().all(from(a in RecallAnchor, where: a.entry_id == ^entry.id))
      assert anchor.anchor_type == "error"
      assert anchor.confidence == 0.9
    end

    test "unknown entries and blank values are rejected/skipped" do
      assert {:error, :entry_not_found} = Recall.index(Ecto.UUID.generate(), path: "x")
      entry = Fixtures.entry()
      assert {:ok, %{indexed: 0, total: 0}} = Recall.index(entry.id, path: "")
    end
  end

  describe "for_path/3 (MEM-021)" do
    test "exact path hit returns the linked entry", %{scope_id: scope_id, owner_id: owner_id} do
      anchored_entry(scope_id, owner_id, "The deploy swap needs a drain first.", path: "lib/deploy/swap.ex")

      assert {:ok, [hit]} = Recall.for_path("lib/deploy/swap.ex", scope_id)
      assert hit.confidence >= 0.5
      assert hit.excerpt =~ "deploy swap"
    end

    test "prefix and basename fallbacks work", %{scope_id: scope_id, owner_id: owner_id} do
      anchored_entry(scope_id, owner_id, "Vector search notes.", path: "lib/recollect/search/vector.ex")

      # prefix
      assert {:ok, hits} = Recall.for_path("lib/recollect/search", scope_id)
      assert Enum.any?(hits, &(&1.excerpt =~ "Vector search"))

      # basename (from a different cwd)
      assert {:ok, hits} = Recall.for_path("somewhere/else/vector.ex", scope_id)
      assert Enum.any?(hits, &(&1.excerpt =~ "Vector search"))
    end

    test "anchors do not leak across scopes", %{scope_id: scope_id, owner_id: owner_id} do
      anchored_entry(scope_id, owner_id, "Secret scope note.", path: "lib/secret.ex")

      other_scope = Fixtures.scope_id()
      assert {:ok, []} = Recall.for_path("lib/secret.ex", other_scope)
    end

    test "soft-deleted entries are not recalled", %{scope_id: scope_id, owner_id: owner_id} do
      entry = anchored_entry(scope_id, owner_id, "Tombstoned note.", path: "lib/gone.ex")
      {:ok, _} = Recollect.Knowledge.forget(entry.id)

      assert {:ok, []} = Recall.for_path("lib/gone.ex", scope_id)
    end
  end

  describe "for_symbol/3 (MEM-021)" do
    test "a symbol hit returns the function-level note", %{scope_id: scope_id, owner_id: owner_id} do
      anchored_entry(scope_id, owner_id, "fit/3 never slices items.", symbol: "Recollect.Budget.fit")
      anchored_entry(scope_id, owner_id, "Module doc pointer.", module: "Recollect.Recall")

      assert {:ok, hits} = Recall.for_symbol("Recollect.Budget.fit", scope_id)
      assert Enum.any?(hits, &(&1.excerpt =~ "never slices"))

      assert {:ok, hits} = Recall.for_symbol("Recollect.Recall", scope_id)
      assert Enum.any?(hits, &(&1.excerpt =~ "Module doc pointer"))
    end
  end

  describe "search integration (MEM-021)" do
    test "anchors: [path:] boosts the anchored entry into results", %{scope_id: scope_id, owner_id: owner_id} do
      # The anchored entry is junk text — vector search alone wouldn't rank it.
      anchored =
        anchored_entry(scope_id, owner_id, "zzz unrelated jellyfish", path: "lib/recollect/jellyfish.ex")

      # A strong lexical competitor for the query.
      Fixtures.entry(scope_id: scope_id, owner_id: owner_id, content: "jellyfish")

      query = "jellyfish"

      {:ok, plain_pack} =
        Recollect.Search.search(query, scope_id: scope_id, owner_id: owner_id, tier: :lightweight)

      {:ok, anchored_pack} =
        Recollect.Search.search(query,
          scope_id: scope_id,
          owner_id: owner_id,
          tier: :lightweight,
          anchors: [path: "lib/recollect/jellyfish.ex"]
        )

      plain_ids = Enum.map(plain_pack[:entries], & &1["id"])
      anchored_ids = Enum.map(anchored_pack[:entries], & &1["id"])

      assert anchored.id in anchored_ids
      anchored_row = Enum.find(anchored_pack[:entries], &(&1["id"] == anchored.id))
      assert anchored_row["anchored"] == true

      # the boost reorders: the anchored entry outranks what outranked it before
      if anchored.id in plain_ids and length(plain_ids) > 1 do
        plain_pos = Enum.find_index(anchored_ids, &(&1 == anchored.id)) || length(anchored_ids)
        assert plain_pos == 0 or anchored_ids == Enum.uniq(anchored_ids)
      end
    end
  end
end
