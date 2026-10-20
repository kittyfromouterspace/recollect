defmodule Recollect.CheckpointFileTest do
  use ExUnit.Case, async: false

  alias Recollect.Learner.Checkpoint.File, as: FileCheckpoint

  setup do
    tmp = Path.join(System.tmp_dir!(), "checkpoint-test-#{System.unique_integer([:positive])}")
    previous = System.get_env("RECOLLECT_HOME")
    System.put_env("RECOLLECT_HOME", tmp)

    on_exit(fn ->
      if previous,
        do: System.put_env("RECOLLECT_HOME", previous),
        else: System.delete_env("RECOLLECT_HOME")

      File.rm_rf!(tmp)
    end)

    :ok
  end

  test "unknown node has no cursors" do
    assert FileCheckpoint.since_map("nobody@nowhere") == %{}
  end

  test "record/3 advances per-agent per-key cursors; since_map/1 reads them back" do
    ts = DateTime.utc_now()

    assert :ok =
             FileCheckpoint.record("lenz@taschenbuch", %{codex: ["mark_mesh", "ops_center"]}, ts)

    iso = DateTime.to_iso8601(ts)

    assert FileCheckpoint.since_map("lenz@taschenbuch") == %{
             "codex" => %{"mark_mesh" => iso, "ops_center" => iso}
           }

    # cursors are node-scoped: another node sees nothing
    assert FileCheckpoint.since_map("lenz@other-laptop") == %{}
  end

  test "a second record overwrites the cursor" do
    first = ~U[2026-01-01 00:00:00Z]
    second = ~U[2026-02-01 00:00:00Z]

    FileCheckpoint.record("lenz@taschenbuch", %{codex: ["mark_mesh"]}, first)
    FileCheckpoint.record("lenz@taschenbuch", %{codex: ["mark_mesh"]}, second)

    assert FileCheckpoint.since_map("lenz@taschenbuch") == %{
             "codex" => %{"mark_mesh" => DateTime.to_iso8601(second)}
           }
  end
end
