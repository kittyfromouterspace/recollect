defmodule Recollect.LearningIdempotencyTest do
  @moduledoc """
  MEM-015: ingestion is idempotent end to end.

  * `remember/2` commits entry + tags + evidence in one Ecto.Multi, and a
    `(source, source_id)` conflict resolves without raising (:skip/:update).
  * `ingest_batch/2` counts inserted/updated/skipped/failed.
  * Harvest records carry a stable source_id, and a second run against the
    same checkpoint is a no-op.
  """
  use Recollect.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Recollect.Knowledge
  alias Recollect.Learner.Checkpoint.File, as: FileCheckpoint
  alias Recollect.Learner.Harvest
  alias Recollect.Schema.Entry

  describe "ingest_batch/2 (MEM-015)" do
    test "batch with duplicate records: one inserted, one skipped" do
      owner_id = Fixtures.owner_id()
      scope_id = Fixtures.scope_id()

      record = %{
        content: "The bulletin parser trims the trailing CRLF before split.",
        source: "agent",
        source_id: "codex:session:abc123",
        tags: ["parser"]
      }

      assert {:ok, %{inserted: 1, updated: 0, skipped: 1, failed: 0}} =
               Knowledge.ingest_batch([record, record],
                 owner_id: owner_id,
                 scope_id: scope_id
               )

      assert {:ok, _unrelated} =
               Knowledge.remember("unrelated", owner_id: owner_id, scope_id: scope_id)

      assert length(Config.repo().all(from(e in Entry, where: e.owner_id == ^owner_id))) == 2
    end

    test "a bad record counts as failed without aborting the batch" do
      owner_id = Fixtures.owner_id()

      assert {:ok, %{inserted: 1, failed: 1, skipped: 0, updated: 0}} =
               Knowledge.ingest_batch(
                 [%{content: "good note"}, %{content: nil}],
                 owner_id: owner_id,
                 scope_id: Fixtures.scope_id()
               )
    end

    test "record opts override batch opts" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()
      other_scope = Fixtures.scope_id()

      {:ok, %{inserted: 2}} =
        Knowledge.ingest_batch(
          [%{content: "in default scope"}, %{content: "in other scope", scope_id: other_scope}],
          owner_id: owner_id,
          scope_id: scope_id
        )

      assert %{scope_id: ^scope_id} =
               Entry |> Config.repo().get_by(content: "in default scope") |> Map.from_struct()

      assert %{scope_id: ^other_scope} =
               Entry |> Config.repo().get_by(content: "in other scope") |> Map.from_struct()
    end

    test ":update mode updates content and version" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {:ok, first} =
        Knowledge.remember("v1 wording",
          owner_id: owner_id,
          scope_id: scope_id,
          source: "agent",
          source_id: "turn-9",
          dedupe: :update
        )

      {:ok, updated} =
        Knowledge.remember("v2 wording",
          owner_id: owner_id,
          scope_id: scope_id,
          source: "agent",
          source_id: "turn-9",
          dedupe: :update
        )

      assert updated.id == first.id
      assert updated.content == "v2 wording"
      assert updated.version == first.version + 1
    end
  end

  describe "concurrent (source, source_id) inserts (MEM-012/015)" do
    test "both insert paths race — no raise, one row wins" do
      owner_id = Fixtures.owner_id()
      scope_id = Fixtures.scope_id()

      results =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Knowledge.remember("concurrent claim about caching",
              owner_id: owner_id,
              scope_id: scope_id,
              source: "agent",
              source_id: "session-x:turn-1"
            )
          end)
        end)
        |> Task.await_many(15_000)

      ids =
        results
        |> Enum.map(fn
          {:ok, entry} -> entry.id
          {:error, :duplicate} -> :duplicate
          {:error, other} -> {:error, other}
        end)
        |> Enum.uniq()

      assert length(ids) == 1
    end
  end

  describe "remember/2 evidence writes in one Multi (MEM-015)" do
    test "entry, tags, and evidence links commit together" do
      owner_id = Fixtures.owner_id()
      scope_id = Fixtures.scope_id()

      {:ok, event} =
        Recollect.Event.record(owner_id: owner_id, event_type: "message", content: "the evidence source")

      {:ok, entry} =
        Knowledge.remember("Claim backed by ledger evidence.",
          owner_id: owner_id,
          scope_id: scope_id,
          tags: ["evidence", "test"],
          evidence: [
            %{
              relation: "supports",
              event_id: event.id,
              source_type: "event",
              source_ref: "session:1:msg:3",
              excerpt: "the evidence source"
            }
          ]
        )

      assert entry.tags == ["evidence", "test"]
      assert {:ok, [link]} = Recollect.Evidence.for_entry(entry.id)
      assert link.relation == "supports"
      assert link.event_id == event.id
    end

    test "an invalid evidence link rolls the whole remember back" do
      owner_id = Fixtures.owner_id()
      scope_id = Fixtures.scope_id()

      assert {:error, {:invalid_evidence, _reason}} =
               Knowledge.remember("Claim with a bad link.",
                 owner_id: owner_id,
                 scope_id: scope_id,
                 tags: ["never stored"],
                 evidence: [%{relation: "hates", source_type: "event", source_ref: "x"}]
               )

      assert Config.repo().all(from(e in Entry, where: e.owner_id == ^owner_id)) == []
      assert Config.repo().all(from(t in Recollect.Schema.EntryTag, where: t.owner_id == ^owner_id)) == []
    end

    test "dedupe :update also links fresh evidence atomically" do
      owner_id = Fixtures.owner_id()
      scope_id = Fixtures.scope_id()

      {:ok, event} =
        Recollect.Event.record(owner_id: owner_id, event_type: "commit", content: "sha123")

      opts = [
        owner_id: owner_id,
        scope_id: scope_id,
        source: "agent",
        source_id: "session-y:turn-2",
        dedupe: :update
      ]

      {:ok, first} = Knowledge.remember("first wording", opts)

      {:ok, updated} =
        Knowledge.remember(
          "second wording",
          Keyword.put(opts, :evidence, [
            %{relation: "derived_from", event_id: event.id, source_type: "event", source_ref: "s:y:2"}
          ])
        )

      assert updated.id == first.id
      assert updated.version == first.version + 1

      assert {:ok, [link]} = Recollect.Evidence.for_entry(first.id)
      assert link.relation == "derived_from"
    end
  end

  describe "harvest records carry stable identity (MEM-015)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "idempotency-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      previous = System.get_env("RECOLLECT_HOME")
      System.put_env("RECOLLECT_HOME", Path.join(tmp, "recollect_home"))

      on_exit(fn ->
        if previous,
          do: System.put_env("RECOLLECT_HOME", previous),
          else: System.delete_env("RECOLLECT_HOME")

        File.rm_rf!(tmp)
      end)

      sessions = Path.join(tmp, "codex")
      File.mkdir_p!(Path.join(sessions, "sessions"))

      write_session(Path.join(sessions, "sessions"), "mark_mesh", "/home/lenz/code/mark_mesh", "fix the bulletin parser")

      absent = Path.join(tmp, "absent")

      agent_configs =
        [:claude_code, :opencode, :gemini]
        |> Map.new(&{&1, %{data_paths: [absent]}})
        |> Map.put(:codex, %{data_paths: [sessions]})

      {:ok, tmp: tmp, base_opts: [agents: [:codex], agent_configs: agent_configs]}
    end

    test "records expose source_id derived from agent + session", %{base_opts: opts} do
      result = Harvest.run([project: "mark_mesh", sink: :collect, consent: :off] ++ opts)

      assert result.count > 0
      assert Enum.all?(result.records, &is_binary(&1.source_id))
      assert Enum.all?(result.records, &String.contains?(&1.source_id, "codex"))
    end

    test "a second run against the same checkpoint is a no-op", %{base_opts: opts} do
      node = "tester@idempotent"

      first =
        Harvest.run([project: "mark_mesh", sink: :collect, consent: :off, node_id: node] ++ opts)

      assert first.count > 0
      assert %{"codex" => %{"mark_mesh" => _iso}} = FileCheckpoint.since_map(node)

      second =
        Harvest.run([project: "mark_mesh", sink: :collect, consent: :off, node_id: node] ++ opts)

      assert second.count == 0
      assert second.records == []
    end
  end

  defp write_session(dir, name, cwd, prompt) do
    lines = [
      %{"payload" => %{"cwd" => cwd}},
      %{
        "type" => "response_item",
        "payload" => %{"role" => "user", "content" => [%{"type" => "input_text", "text" => prompt}]}
      }
    ]

    body = Enum.map_join(lines, "\n", &Jason.encode!/1)
    File.write!(Path.join(dir, "rollout-2026-01-01T00-00-00-#{name}.jsonl"), body)
  end
end
