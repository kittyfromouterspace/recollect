defmodule Recollect.SupersedeTest do
  use Recollect.DataCase, async: false

  alias Recollect.Knowledge
  alias Recollect.Schema.Edge
  alias Recollect.Search.Graph
  alias Recollect.Search.Vector

  defp embedded_entry(content, opts) do
    {:ok, embedding} = Recollect.Embedding.Mock.embed("deploy process", [])

    Fixtures.entry(
      Keyword.merge(
        [content: content, embedding: embedding],
        opts
      )
    )
  end

  # Raw-SQL result maps carry ids as 16-byte binaries; load to string UUIDs.
  defp ids(results), do: Enum.map(results, &Ecto.UUID.load!(&1["id"]))

  describe "supersede/3" do
    test "creates a supersedes edge and stamps + zeroes the old entry" do
      old = Fixtures.entry(content: "old fact")
      new = Fixtures.entry(content: "new fact", scope_id: old.scope_id, owner_id: old.owner_id)

      assert {:ok, updated} = Knowledge.supersede(new.id, old.id)

      assert updated.confidence == 0.0
      assert updated.half_life_days == 0.01
      assert updated.metadata["superseded_by"] == new.id
      assert {:ok, _, _} = DateTime.from_iso8601(updated.metadata["superseded_at"])

      edge =
        Config.repo().get_by(Edge,
          source_entry_id: new.id,
          target_entry_id: old.id,
          relation: "supersedes"
        )

      assert edge
    end

    test "strength of a superseded entry is a float near zero, not a crash (MEM-008)" do
      old = Fixtures.entry(content: "old fact", half_life_days: 30.0)
      new = Fixtures.entry(content: "new fact", scope_id: old.scope_id, owner_id: old.owner_id)

      assert {:ok, superseded} = Knowledge.supersede(new.id, old.id)

      strength = Recollect.Strength.calculate(superseded)
      assert is_float(strength)
      assert strength <= 0.01
    end

    test "superseded_half_life is configurable (MEM-008)" do
      old = Fixtures.entry(content: "old fact", half_life_days: 30.0)
      new = Fixtures.entry(content: "new fact", scope_id: old.scope_id, owner_id: old.owner_id)

      assert {:ok, superseded} = Knowledge.supersede(new.id, old.id, superseded_half_life: 2.0)
      assert superseded.half_life_days == 2.0
      assert superseded.confidence == 0.0
    end

    test "keep_strength: true preserves confidence and half-life" do
      old = Fixtures.entry(content: "old fact", confidence: 0.9, half_life_days: 30.0)
      new = Fixtures.entry(content: "new fact", scope_id: old.scope_id, owner_id: old.owner_id)

      assert {:ok, updated} = Knowledge.supersede(new.id, old.id, keep_strength: true)

      assert updated.confidence == 0.9
      assert updated.half_life_days == 30.0
      assert updated.metadata["superseded_by"] == new.id
    end

    test "returns :not_found for a missing old entry" do
      new = Fixtures.entry()

      assert {:error, :not_found} = Knowledge.supersede(new.id, Ecto.UUID.generate())
    end
  end

  describe "search exclusion" do
    test "superseded entries are excluded from vector entry results by default" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      old = embedded_entry("old deploy fact", scope_id: scope_id, owner_id: owner_id)
      new = embedded_entry("new deploy fact", scope_id: scope_id, owner_id: owner_id)

      {:ok, before} = Vector.search_entries("deploy process", scope_id)
      assert before |> ids() |> Enum.sort() == Enum.sort([old.id, new.id])

      {:ok, _} = Knowledge.supersede(new.id, old.id)

      {:ok, after_default} = Vector.search_entries("deploy process", scope_id)
      assert ids(after_default) == [new.id]
    end

    test "include_superseded: true opts out of the exclusion" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      old = embedded_entry("old deploy fact", scope_id: scope_id, owner_id: owner_id)
      new = embedded_entry("new deploy fact", scope_id: scope_id, owner_id: owner_id)

      {:ok, _} = Knowledge.supersede(new.id, old.id)

      {:ok, results} = Vector.search_entries("deploy process", scope_id, include_superseded: true)
      assert results |> ids() |> Enum.sort() == Enum.sort([old.id, new.id])
    end

    test "Graph.follow_edges excludes superseded entries by default" do
      anchor = Fixtures.entry(content: "anchor")
      old = Fixtures.entry(content: "old related", scope_id: anchor.scope_id, owner_id: anchor.owner_id)
      fresh = Fixtures.entry(content: "fresh related", scope_id: anchor.scope_id, owner_id: anchor.owner_id)

      {:ok, _} = Knowledge.connect(anchor.id, old.id, "related_to")
      {:ok, _} = Knowledge.connect(anchor.id, fresh.id, "related_to")
      {:ok, _} = Knowledge.supersede(fresh.id, old.id)

      {:ok, default_related} = Graph.follow_edges([anchor.id])
      assert ids(default_related) == [fresh.id]

      {:ok, all_related} = Graph.follow_edges([anchor.id], include_superseded: true)
      assert all_related |> ids() |> Enum.sort() == Enum.sort([old.id, fresh.id])
    end

    test "Recollect.search/2 entries exclude superseded by default, opt-in via include_superseded" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      old = embedded_entry("old deploy fact", scope_id: scope_id, owner_id: owner_id)
      new = embedded_entry("new deploy fact", scope_id: scope_id, owner_id: owner_id)

      {:ok, _} = Knowledge.supersede(new.id, old.id)

      {:ok, pack} = Recollect.search("deploy process", scope_id: scope_id, tier: :lightweight)
      assert ids(pack.entries) == [new.id]

      {:ok, pack} =
        Recollect.search("deploy process", scope_id: scope_id, tier: :lightweight, include_superseded: true)

      assert pack.entries |> ids() |> Enum.sort() == Enum.sort([old.id, new.id])
    end
  end
end
