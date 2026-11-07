defmodule Recollect.ConflictDetectionTest do
  use Recollect.DataCase, async: false

  alias Recollect.ConflictDetection
  alias Recollect.Conflicts

  @enabled "Feature flag X is enabled for all users"
  @disabled "Feature flag X is disabled for all users"

  defp entry_pair do
    a =
      Fixtures.entry(%{
        content: @enabled,
        entry_type: "observation"
      })

    b =
      Fixtures.entry(%{
        content: @disabled,
        entry_type: "observation",
        scope_id: a.scope_id,
        owner_id: a.owner_id
      })

    {a, b}
  end

  defp open_conflicts(scope_id) do
    {:ok, rows} = Conflicts.list(scope_id)
    rows
  end

  describe "detect/1 (MEM-004)" do
    test "a contradictory pair is detected with canonical pair order" do
      {a, b} = entry_pair()

      conflicts = ConflictDetection.detect(a.scope_id)

      assert length(conflicts) == 1
      conflict = hd(conflicts)
      assert conflict.reason == "enabled/disabled mismatch"
      assert conflict.entry_a_id <= conflict.entry_b_id
      assert {conflict.entry_a_id, conflict.entry_b_id} in [{a.id, b.id}, {b.id, a.id}]
    end

    test "the pair persists exactly one conflict row, idempotently" do
      {a, _b} = entry_pair()

      conflicts = ConflictDetection.detect(a.scope_id)
      assert {:ok, 1} = Conflicts.persist(a.scope_id, a.owner_id, conflicts)
      assert {:ok, 1} = Conflicts.persist(a.scope_id, a.owner_id, conflicts)

      assert length(open_conflicts(a.scope_id)) == 1
    end

    test "a resolved conflict re-opens when the contradiction is detected again" do
      {a, b} = entry_pair()

      conflicts = ConflictDetection.detect(a.scope_id)
      {:ok, 1} = Conflicts.persist(a.scope_id, a.owner_id, conflicts)

      [conflict] = open_conflicts(a.scope_id)
      conflict_id = Ecto.UUID.load!(conflict["id"])

      assert {:ok, _} = Conflicts.resolve(conflict_id, a.id)
      assert open_conflicts(a.scope_id) == []

      # Re-detect the same contradiction: it must come back as open.
      {:ok, 1} = Conflicts.persist(a.scope_id, a.owner_id, ConflictDetection.detect(a.scope_id))
      assert [%{"status" => "open"}] = open_conflicts(a.scope_id)

      # and it is still the same single row
      assert a.scope_id |> Conflicts.list_all() |> elem(1) |> length() == 1
      assert b.id != a.id
    end

    test "non-contradictory entries produce no conflict" do
      a = Fixtures.entry(content: "Deploy scripts live in /app/scripts on the build box")

      Fixtures.entry(%{
        content: "Billing retries use exponential backoff capped at 60s",
        scope_id: a.scope_id,
        owner_id: a.owner_id
      })

      assert ConflictDetection.detect(a.scope_id) == []
    end

    test "consolidation end-to-end persists detected conflicts" do
      {a, _b} = entry_pair()

      assert {:ok, result} = Recollect.Consolidation.run(scope_id: a.scope_id)
      assert result.conflicts_detected >= 1
      assert length(open_conflicts(a.scope_id)) >= 1
    end
  end
end
