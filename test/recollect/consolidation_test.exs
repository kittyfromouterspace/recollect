defmodule Recollect.ConsolidationTest do
  use Recollect.DataCase, async: false

  alias Recollect.Consolidation

  describe "run/1 regression (MEM-001)" do
    test "runs on a non-empty scope without raising and records the run" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      Fixtures.entry(%{
        scope_id: scope_id,
        owner_id: owner_id,
        content: "Billing retries use exponential backoff capped at 60s.",
        entry_type: "note"
      })

      assert {:ok, result} = Consolidation.run(scope_id: scope_id)
      assert is_map(result)
      assert result.decayed >= 0
      assert result.removed >= 0

      {:ok, %{rows: rows}} =
        Config.repo().query(
          "SELECT scope_id, decayed, removed FROM recollect_consolidation_runs WHERE scope_id = $1",
          [Recollect.Util.uuid_to_bin(scope_id)]
        )

      assert length(rows) == 1
    end

    test "keeps pinned entries even with nil last_accessed_at" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      Fixtures.entry(%{
        scope_id: scope_id,
        owner_id: owner_id,
        content: "Pinned operational rule: never deploy on Friday.",
        pinned: true,
        last_accessed_at: nil
      })

      assert {:ok, result} = Consolidation.run(scope_id: scope_id)
      assert result.removed == 0
    end

    test "does not raise on an entry with half_life_days of 0.0" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      Fixtures.entry(%{
        scope_id: scope_id,
        owner_id: owner_id,
        content: "Superseded claim with a zero half-life.",
        half_life_days: 0.0,
        confidence: 0.0
      })

      assert {:ok, _result} = Consolidation.run(scope_id: scope_id)
    end

    test "entries stay untouched when decay threshold keeps them alive" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      entry =
        Fixtures.entry(%{
          scope_id: scope_id,
          owner_id: owner_id,
          content: "Fresh note that must survive consolidation."
        })

      assert {:ok, result} = Consolidation.run(scope_id: scope_id)
      assert result.removed == 0
      assert result.decayed == 0

      still_there = Config.repo().get!(Recollect.Schema.Entry, entry.id)
      assert still_there.entry_type == entry.entry_type
    end
  end

  describe "run/1 decay persistence (MEM-002)" do
    test "archives entries below the decay threshold and reports the real count" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      stale =
        Fixtures.entry(%{
          scope_id: scope_id,
          owner_id: owner_id,
          content: "Stale note from months ago.",
          last_accessed_at: DateTime.add(DateTime.utc_now(), -400, :day)
        })

      fresh =
        Fixtures.entry(%{
          scope_id: scope_id,
          owner_id: owner_id,
          content: "Fresh note accessed today."
        })

      assert {:ok, result} = Consolidation.run(scope_id: scope_id)
      assert result.removed == 1

      archived = Config.repo().reload!(stale)
      assert archived.entry_type == "archived"

      kept = Config.repo().reload!(fresh)
      assert kept.entry_type != "archived"

      {:ok, %{rows: rows}} =
        Config.repo().query(
          "SELECT removed FROM recollect_consolidation_runs WHERE scope_id = $1",
          [Recollect.Util.uuid_to_bin(scope_id)]
        )

      assert [[removed]] = rows
      assert removed == 1
    end

    test "dry_run archives nothing and writes no run record" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      stale =
        Fixtures.entry(%{
          scope_id: scope_id,
          owner_id: owner_id,
          content: "Stale note that a dry run must not archive.",
          last_accessed_at: DateTime.add(DateTime.utc_now(), -400, :day)
        })

      assert {:ok, result} = Consolidation.run(scope_id: scope_id, dry_run: true)
      assert result.removed == 1

      untouched = Config.repo().reload!(stale)
      assert untouched.entry_type != "archived"

      {:ok, %{rows: rows}} =
        Config.repo().query(
          "SELECT count(*) FROM recollect_consolidation_runs WHERE scope_id = $1",
          [Recollect.Util.uuid_to_bin(scope_id)]
        )

      assert [[0]] = rows
    end

    test "pinned entries survive decay even when ancient" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      pinned =
        Fixtures.entry(%{
          scope_id: scope_id,
          owner_id: owner_id,
          content: "Ancient but pinned operational rule.",
          pinned: true,
          last_accessed_at: DateTime.add(DateTime.utc_now(), -400, :day)
        })

      assert {:ok, result} = Consolidation.run(scope_id: scope_id)
      assert result.removed == 0

      kept = Config.repo().reload!(pinned)
      assert kept.entry_type != "archived"
    end
  end

  describe "merge clustering (MEM-003)" do
    test "a chain of overlapping entries forms ONE cluster and one summary" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      # Entries 1→2→3→4 each overlap their neighbour fully; under the old
      # raw-parent grouping this chain split into phantom sub-clusters and no
      # cluster reached min_cluster: 3.
      Enum.each(1..4, fn i ->
        Fixtures.entry(%{
          scope_id: scope_id,
          owner_id: owner_id,
          content: "Deploy step alpha: run the migration checker #{i}",
          entry_type: "note"
        })
      end)

      assert {:ok, result} = Consolidation.run(scope_id: scope_id, min_cluster: 3)
      assert result.merged == 1
      assert result.semantic_created == 1
    end

    test "two disjoint groups produce two clusters" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      Enum.each(1..3, fn i ->
        Fixtures.entry(%{
          scope_id: scope_id,
          owner_id: owner_id,
          content: "Billing retry cluster item #{i}: exponential backoff",
          entry_type: "note"
        })
      end)

      Enum.each(1..3, fn i ->
        Fixtures.entry(%{
          scope_id: scope_id,
          owner_id: owner_id,
          content: "Kubernetes cluster item #{i}: node drain procedure",
          entry_type: "note"
        })
      end)

      assert {:ok, result} = Consolidation.run(scope_id: scope_id, min_cluster: 3)
      assert result.merged == 2
      assert result.semantic_created == 2
    end
  end
end
