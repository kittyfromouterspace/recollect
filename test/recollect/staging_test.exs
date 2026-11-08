defmodule Recollect.StagingTest do
  use Recollect.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Recollect.Config
  alias Recollect.Schema.Staging, as: StagingRow
  alias Recollect.Sleep
  alias Recollect.Staging
  alias Recollect.WorkingMemory

  setup do
    scope_id = Fixtures.scope_id()
    owner_id = Fixtures.owner_id()

    previous_brief = Application.get_env(:recollect, :staging)

    on_exit(fn ->
      if previous_brief,
        do: Application.put_env(:recollect, :staging, previous_brief),
        else: Application.delete_env(:recollect, :staging)
    end)

    {:ok, scope_id: scope_id, owner_id: owner_id}
  end

  describe "stage/3 + drain/2 (MEM-040)" do
    test "round-trip preserves content and metadata" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      assert {:ok, row} =
               Staging.stage(scope_id, "candidate note about the retry ladder",
                 owner_id: owner_id,
                 source: "session",
                 priority: 0.8,
                 metadata: %{"tags" => ["retries"]}
               )

      assert row.status == "staged"
      assert is_nil(row.drained_at)

      assert {:ok, [drained]} = Staging.drain(scope_id)
      assert drained.id == row.id
      assert drained.content =~ "retry ladder"
      assert drained.metadata["tags"] == ["retries"]

      # claimed rows are drained; a second drain gets nothing
      assert {:ok, []} = Staging.drain(scope_id)
      assert Config.repo().get(StagingRow, row.id).status == "drained"
    end

    test "two concurrent drains claim disjoint rows" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      rows =
        for i <- 1..6 do
          {:ok, row} = Staging.stage(scope_id, "note #{i}", owner_id: owner_id)
          row.id
        end

      drain_task = fn ->
        scope_id
        |> Staging.drain(limit: 100)
        |> elem(1)
        |> MapSet.new(& &1.id)
      end

      t1 = Task.async(drain_task)
      t2 = Task.async(drain_task)
      s1 = Task.await(t1)
      s2 = Task.await(t2)

      # disjoint
      assert MapSet.size(MapSet.intersection(s1, s2)) == 0
      # together they covered everything
      assert MapSet.size(MapSet.union(s1, s2)) == 6
      assert s1 |> MapSet.union(s2) |> MapSet.equal?(MapSet.new(rows))
    end

    test "secret-guarded content never lands in the table" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      assert {:error, :possible_secret} =
               Staging.stage(scope_id, "aws key AKIAIOSFODNN7EXAMPLE in the log", owner_id: owner_id)

      assert Config.repo().aggregate(
               from(s in StagingRow, where: s.scope_id == ^scope_id),
               :count,
               :id
             ) == 0

      # allow_secrets opts through to the guard
      assert {:ok, _} =
               Staging.stage(scope_id, "aws key AKIAIOSFODNN7EXAMPLE in the log",
                 owner_id: owner_id,
                 allow_secrets: true
               )
    end

    test "backlog cap rejects over-max staged rows" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()
      Application.put_env(:recollect, :staging, max_items: 2)

      assert {:ok, _} = Staging.stage(scope_id, "one", owner_id: owner_id)
      assert {:ok, _} = Staging.stage(scope_id, "two", owner_id: owner_id)
      assert {:error, :staging_backlog_full} = Staging.stage(scope_id, "three", owner_id: owner_id)
    end
  end

  describe "restage/1 (MEM-040)" do
    test "puts failed rows back to staged" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {:ok, row} = Staging.stage(scope_id, "will fail promotion", owner_id: owner_id)
      {:ok, [drained]} = Staging.drain(scope_id)
      assert Config.repo().get!(StagingRow, drained.id).status == "drained"

      assert {:ok, %{restaged: 1}} = Staging.restage([row.id])

      back = Config.repo().get(StagingRow, row.id)
      assert back.status == "staged"
      assert is_nil(back.drained_at)

      # and it can be drained again
      assert {:ok, [_]} = Staging.drain(scope_id)
    end
  end

  describe "Sleep.promote from_staging (MEM-040)" do
    test "drains staging, promotes survivors, restages failures" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {:ok, good} = Staging.stage(scope_id, "promote this staged note", owner_id: owner_id, priority: 0.9)

      # allow_secrets at stage time; the guard rejects it again at persist
      {:ok, bad} =
        Staging.stage(scope_id, "token sk-abcdef1234567890abcdef in the middle",
          owner_id: owner_id,
          priority: 0.9,
          allow_secrets: true
        )

      capture_log(fn ->
        assert {:ok, result} =
                 Sleep.promote(
                   scope_id: scope_id,
                   owner_id: owner_id,
                   from_staging: true,
                   use_llm: false,
                   importance_threshold: 0.5
                 )

        assert result.candidates == 2
        assert result.promoted == 1
        assert result.failed == 1
      end)

      assert Config.repo().get(StagingRow, good.id).status == "drained"
      assert Config.repo().get(StagingRow, bad.id).status == "staged"
    end
  end

  describe "prune/1 (MEM-040)" do
    test "retention prunes only drained rows past the window" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {:ok, will_be_drained} = Staging.stage(scope_id, "old drained", owner_id: owner_id)
      {:ok, staged_forever} = Staging.stage(scope_id, "still staged", owner_id: owner_id)

      {:ok, [_, _]} = Staging.drain(scope_id)

      # age one drained row beyond any window; the other goes back to staged
      Config.repo().update_all(
        from(s in StagingRow, where: s.id == ^will_be_drained.id),
        set: [drained_at: DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)]
      )

      assert {:ok, %{restaged: 1}} = Staging.restage([staged_forever.id])

      assert {:ok, %{pruned: 1}} = Staging.prune(retention_days: 7)

      assert is_nil(Config.repo().get(StagingRow, will_be_drained.id))

      # the staged row survives
      staged = Config.repo().all(from(s in StagingRow, where: s.status == "staged"))
      assert length(staged) == 1
      assert hd(staged).content == "still staged"
    end
  end

  describe "WorkingMemory deprecation (MEM-040)" do
    test "public functions log a deprecation warning pointing at Staging" do
      scope_id = Fixtures.scope_id()

      # the warning is once-per-VM — reset so this test observes it
      :persistent_term.put(:recollect_working_memory_deprecation_logged, false)

      log =
        capture_log(fn ->
          WorkingMemory.push(scope_id, "deprecated path note", importance: 0.5)
          WorkingMemory.read(scope_id)
        end)

      assert log =~ "deprecated"
      assert log =~ "Recollect.Staging"
    end
  end
end
