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
end
