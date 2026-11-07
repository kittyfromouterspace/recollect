defmodule Recollect.SchemaIndexTest do
  use Recollect.DataCase, async: false

  alias Recollect.SchemaIndex

  setup do
    # The schema index is process-global ETS state, not sandboxed — clear it
    # so each test sees exactly the index it builds.
    :ets.delete_all_objects(:recollect_schema_index)
    :ok
  end

  defp tagged_entry(scope_id, tags) do
    {:ok, entry} =
      Recollect.remember("note about #{Enum.join(tags, ",")}",
        owner_id: Fixtures.owner_id(),
        scope_id: scope_id,
        tags: tags
      )

    entry
  end

  describe "rebuild/1 (MEM-006)" do
    test "aggregates tag frequency for one scope, excluding other scopes" do
      scope_id = Fixtures.scope_id()
      other_scope = Fixtures.scope_id()

      tagged_entry(scope_id, ["billing", "ops"])
      tagged_entry(scope_id, ["billing"])
      tagged_entry(other_scope, ["k8s"])

      assert %{tag_clusters: 2, entry_count: 2} = SchemaIndex.rebuild(scope_id)

      freq = SchemaIndex.tag_frequency(scope_id)
      assert freq == %{"billing" => 2, "ops" => 1}
      assert SchemaIndex.entry_count(scope_id) == 2
    end

    test "scoped lookup falls back to the global aggregate" do
      scope_id = Fixtures.scope_id()
      tagged_entry(scope_id, ["billing"])

      SchemaIndex.rebuild()

      fresh_scope = Fixtures.scope_id()
      assert SchemaIndex.tag_frequency(fresh_scope) == %{"billing" => 1}
      assert SchemaIndex.entry_count(fresh_scope) == 1
    end

    test "archived entries do not count" do
      scope_id = Fixtures.scope_id()
      entry = tagged_entry(scope_id, ["billing"])

      entry
      |> Ecto.Changeset.change(entry_type: "archived")
      |> Config.repo().update!()

      SchemaIndex.rebuild(scope_id)

      assert SchemaIndex.tag_frequency(scope_id) == %{}
      assert SchemaIndex.entry_count(scope_id) == 0
    end
  end

  describe "SchemaFit (MEM-006)" do
    test "empty index yields neutral 0.5" do
      assert Recollect.SchemaFit.compute("content", ["x"], Fixtures.scope_id()) == 0.5
      assert Recollect.SchemaFit.compute_tag_fit(["x"], Fixtures.scope_id()) == 0.5
    end

    test "known tags score above neutral after a scope rebuild" do
      scope_id = Fixtures.scope_id()

      for _i <- 1..5 do
        tagged_entry(scope_id, ["billing"])
      end

      SchemaIndex.rebuild(scope_id)

      score = Recollect.SchemaFit.compute_tag_fit(["billing"], scope_id)
      assert score > 0.5
    end

    test "content fit samples at most the configured number of entries" do
      scope_id = Fixtures.scope_id()

      for i <- 1..10 do
        tagged_entry(scope_id, ["sample#{i}"])
      end

      Application.put_env(:recollect, :schema_fit, content_sample_size: 3)

      try do
        # With 10 near-identical entries and a sample of 3, matches can be at
        # most 3; min(1.0, 3 / max(5, 3 * 0.1)) == 0.6 proves the cap held
        # (without the cap, 10 matches would hit the 1.0 ceiling).
        score = Recollect.SchemaFit.compute_content_fit("note about sample1", scope_id)
        assert score <= 0.6
      after
        Application.delete_env(:recollect, :schema_fit)
      end
    end

    test "remember writes tag-fit synchronously and refines asynchronously" do
      scope_id = Fixtures.scope_id()

      for _i <- 1..4 do
        tagged_entry(scope_id, ["billing"])
      end

      SchemaIndex.rebuild(scope_id)

      {:ok, entry} =
        Recollect.remember("billing retries capped at 60 seconds",
          owner_id: Fixtures.owner_id(),
          scope_id: scope_id,
          tags: ["billing"]
        )

      assert entry.schema_fit > 0.5

      # The async refine writes the combined score back; give it a moment.
      Process.sleep(200)
      refined = Config.repo().reload!(entry)
      assert is_float(refined.schema_fit)
    end
  end
end
