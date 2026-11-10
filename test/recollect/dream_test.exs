defmodule Recollect.DreamTest do
  use Recollect.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Recollect.Config
  alias Recollect.Dream
  alias Recollect.Schema.DreamRun
  alias Recollect.Schema.Entry

  # Fake stages write MARKER ENTRIES (not events — the input hash reads the
  # event ledger, so markers must not feed the hash). Each stage runs in
  # its own transaction, so rolled-back stages leave no marker behind.

  defmodule Markers do
    @moduledoc false
    def write(scope_id, kind) do
      %Entry{}
      |> Entry.changeset(%{
        scope_id: scope_id,
        owner_id: scope_id,
        content: "marker #{kind}",
        source: "system"
      })
      |> Config.repo().insert()
    end
  end

  defmodule Counters do
    @moduledoc false
    @keys ["ok", "boom", "sleeper", "quick", "cancellable"]

    def bump(key) do
      n = :persistent_term.get({:dream_test_counter, key}, 0) + 1
      :persistent_term.put({:dream_test_counter, key}, n)
      n
    end

    def count(key), do: :persistent_term.get({:dream_test_counter, key}, 0)
    def reset, do: Enum.each(@keys, &:persistent_term.put({:dream_test_counter, &1}, 0))
  end

  defmodule OkStage do
    @moduledoc false
    def run(scope_id, _opts) do
      Counters.bump("ok")
      Markers.write(scope_id, "stage-ok")
      {:ok, %{"marked" => 1}}
    end
  end

  # fails on the first call, succeeds afterwards — models a transient stage
  defmodule BoomStage do
    @moduledoc false
    def run(scope_id, _opts) do
      calls = Counters.bump("boom")

      if calls == 1 do
        Markers.write(scope_id, "stage-boom")
        {:error, :exploded}
      else
        {:ok, %{"recovered" => true}}
      end
    end
  end

  defmodule SleeperStage do
    @moduledoc false
    def run(scope_id, _opts) do
      Counters.bump("sleeper")
      Process.sleep(20)
      Markers.write(scope_id, "stage-sleeper")
      {:ok, %{"slept" => true}}
    end
  end

  defmodule QuickStage do
    @moduledoc false
    def run(scope_id, _opts) do
      Counters.bump("quick")
      Markers.write(scope_id, "stage-quick")
      {:ok, %{}}
    end
  end

  defmodule CancellableStage do
    @moduledoc false
    def run(_scope_id, opts) do
      Counters.bump("cancellable")
      run_id = Keyword.fetch!(opts, :dream_run_id)
      Dream.cancel(run_id)
      if Dream.cancelled?(run_id), do: {:error, :cancelled}, else: {:ok, %{}}
    end
  end

  setup do
    Counters.reset()
    scope_id = Fixtures.scope_id()
    owner_id = Fixtures.owner_id()

    on_exit(fn -> Counters.reset() end)

    {:ok, scope_id: scope_id, owner_id: owner_id}
  end

  defp marker_contents(scope_id) do
    Config.repo().all(from(e in Entry, where: e.scope_id == ^scope_id, select: e.content))
  end

  describe "plan/2 (MEM-023)" do
    test "returns the work it would do without writing", %{scope_id: scope_id} do
      assert {:ok, plan} = Dream.plan(scope_id, stages: [OkStage])

      assert plan.input_hash
      assert plan.stages == ["Elixir.Recollect.DreamTest.OkStage"]
      assert plan.dry_run == true

      assert marker_contents(scope_id) == []

      assert Config.repo().aggregate(
               from(r in DreamRun, where: r.scope_id == ^scope_id),
               :count,
               :id
             ) == 0
    end

    test "a completed run shows as cached in the plan", %{scope_id: scope_id} do
      assert {:ok, _} = Dream.run(scope_id, stages: [OkStage])
      assert {:ok, plan} = Dream.plan(scope_id, stages: [OkStage])
      assert plan.cached == true
    end
  end

  describe "run/2 idempotency (MEM-023)" do
    test "same input hash twice: the second run returns the first without work", %{
      scope_id: scope_id
    } do
      {:ok, first} = Dream.run(scope_id, stages: [OkStage])
      assert first.status == "done"
      assert first.replayed == false
      assert Counters.count("ok") == 1

      {:ok, second} = Dream.run(scope_id, stages: [OkStage])
      assert second.replayed == true
      assert second.id == first.id
      assert second.status == "done"
      assert Counters.count("ok") == 1, "no stage work on a replayed run"
    end

    test "a failed run can be retried with the same hash and resumes", %{scope_id: scope_id} do
      {:ok, failed} = Dream.run(scope_id, stages: [OkStage, BoomStage])
      assert failed.status == "failed"

      {:ok, retried} = Dream.run(scope_id, stages: [OkStage, BoomStage])
      assert retried.status == "done"
      assert Counters.count("ok") == 1, "the completed stage must not rerun"
      assert Counters.count("boom") == 2, "the failed stage reruns"
    end

    test "force: true reruns everything", %{scope_id: scope_id} do
      {:ok, _} = Dream.run(scope_id, stages: [OkStage])
      {:ok, _} = Dream.run(scope_id, stages: [OkStage], force: true)
      assert Counters.count("ok") == 2
    end
  end

  describe "run/2 locking (MEM-023)" do
    test "a busy scope returns {:error, :locked}" do
      locked_lock_fn = fn _fun -> {:error, :locked} end

      assert {:error, :locked} =
               Dream.run(Fixtures.scope_id(), stages: [OkStage], lock_fn: locked_lock_fn)

      assert Counters.count("ok") == 0, "the stages never run without the lock"
    end

    test "the real lock acquires and releases around the run", %{scope_id: scope_id} do
      assert {:ok, result} = Dream.run(scope_id, stages: [OkStage])
      assert result.status == "done"
    end
  end

  describe "run/2 budget and failure (MEM-023)" do
    test "wall budget exceeded: aborted at a stage boundary, no half-finished writes", %{
      scope_id: scope_id
    } do
      {:ok, result} = Dream.run(scope_id, stages: [SleeperStage, QuickStage], max_wall_ms: 10)

      assert result.status == "aborted"
      assert result.error == "wall budget exceeded"

      # the first stage's transaction committed; the second never ran
      contents = marker_contents(scope_id)
      assert "marker stage-sleeper" in contents
      refute "marker stage-quick" in contents
    end

    test "stage failure: failing stage's writes absent, earlier stages completed", %{
      scope_id: scope_id
    } do
      {:ok, result} = Dream.run(scope_id, stages: [OkStage, BoomStage])

      assert result.status == "failed"
      assert result.error =~ "exploded"

      # boom stage's transaction rolled back — its marker row is absent
      refute "marker stage-boom" in marker_contents(scope_id)
      assert "marker stage-ok" in marker_contents(scope_id)

      assert result.stages["ok_stage"]["status"] == "completed"
      assert result.stages["boom_stage"]["status"] == "failed"
    end

    test "cancellation aborts the run", %{scope_id: scope_id} do
      {:ok, result} = Dream.run(scope_id, stages: [CancellableStage])

      assert result.status == "aborted"
      assert result.error == "cancelled"
    end

    test "the plan doubles as the dry run: no stages, no writes", %{scope_id: scope_id} do
      assert {:ok, _plan} = Dream.plan(scope_id, stages: [OkStage])
      assert Counters.count("ok") == 0
      assert marker_contents(scope_id) == []
    end

    test "status/1 fetches the run row", %{scope_id: scope_id} do
      {:ok, result} = Dream.run(scope_id, stages: [OkStage])
      assert {:ok, run} = Dream.status(result.id)
      assert run.status == "done"
      assert {:error, :not_found} = Dream.status(Ecto.UUID.generate())
    end
  end

  test "events-disabled scopes require an explicit idempotency_key" do
    previous = Application.get_env(:recollect, :events)
    Application.put_env(:recollect, :events, enabled: false)

    try do
      assert_raise ArgumentError, ~r/idempotency_key/, fn ->
        Dream.run(Fixtures.scope_id(), stages: [OkStage])
      end

      assert {:ok, result} =
               Dream.run(Fixtures.scope_id(), stages: [OkStage], idempotency_key: "nightly-1")

      assert result.status == "done"
    after
      if previous,
        do: Application.put_env(:recollect, :events, previous),
        else: Application.delete_env(:recollect, :events)
    end
  end
end
