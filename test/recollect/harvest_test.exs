defmodule Recollect.HarvestTest do
  @moduledoc """
  End-to-end harvest pipeline tests against a fabricated Codex data dir.
  Env-mutating (RECOLLECT_HOME) and filesystem-bound, so async: false.
  """
  use ExUnit.Case, async: false

  alias Recollect.Learner.Checkpoint.File, as: FileCheckpoint
  alias Recollect.Learner.Consent
  alias Recollect.Learner.Harvest
  alias Recollect.Learner.Harvest.Sink

  setup do
    tmp = Path.join(System.tmp_dir!(), "harvest-test-#{System.unique_integer([:positive])}")
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
    write_session(Path.join(sessions, "sessions"), "ops", "/home/lenz/code/ops_center", "deploy ops_center")

    # Isolate the run from the host: codex reads the fabricated dir; every
    # other provider gets a nonexistent dir (their real default data dirs may
    # exist on the host and would leak into discovery).
    absent = Path.join(tmp, "absent")

    agent_configs =
      Map.new([:claude_code, :opencode, :gemini], &{&1, %{data_paths: [absent]}})
      |> Map.put(:codex, %{data_paths: [sessions]})

    {:ok, tmp: tmp, base_opts: [agents: [:codex], agent_configs: agent_configs]}
  end

  describe "consent gate" do
    test "unasked agents are skipped entirely", %{base_opts: opts} do
      result = Harvest.run([project: "mark_mesh", sink: :collect] ++ opts)

      assert result.count == 0
      assert result.records == []
    end

    test "granted agents are read", %{base_opts: opts} do
      Consent.grant(:codex)

      result = Harvest.run([project: "mark_mesh", sink: :collect] ++ opts)

      assert result.count > 0
      assert Enum.all?(result.records, &(&1.agent == :codex))
      assert Enum.all?(result.records, &String.contains?(&1.content, "bulletin"))
    end

    test "consent: :off bypasses the gate", %{base_opts: opts} do
      result = Harvest.run([project: "mark_mesh", sink: :collect, consent: :off] ++ opts)

      assert result.count > 0
    end
  end

  describe "project filter" do
    test "only slug-matching sessions are harvested", %{base_opts: opts} do
      result = Harvest.run([project: "mark_mesh", sink: :collect, consent: :off] ++ opts)

      assert result.matched == %{codex: ["mark_mesh"]}
      assert result.count > 0
      refute Enum.any?(result.records, &String.contains?(&1.content, "deploy"))
    end

    test "no match harvests nothing", %{base_opts: opts} do
      result = Harvest.run([project: "nope_nope", sink: :collect, consent: :off] ++ opts)

      assert result.count == 0
      assert result.matched == nil
    end

    test "project is required without all_sessions/match", %{base_opts: opts} do
      assert_raise ArgumentError, ~r/project is required/, fn ->
        Harvest.run([sink: :collect, consent: :off] ++ opts)
      end
    end
  end

  describe "checkpoints" do
    test "a clean slug-mapped run advances the file cursor; --full ignores it", %{base_opts: opts} do
      node = "tester@harvest"

      first =
        Harvest.run([project: "mark_mesh", sink: :collect, consent: :off, node_id: node] ++ opts)

      assert first.count > 0
      assert %{"codex" => %{"mark_mesh" => _iso}} = FileCheckpoint.since_map(node)

      second =
        Harvest.run([project: "mark_mesh", sink: :collect, consent: :off, node_id: node, full: true] ++ opts)

      assert second.count == first.count
    end

    test "dry-run never reads or writes the cursor", %{base_opts: opts} do
      node = "tester@dryrun"

      result =
        Harvest.run([project: "mark_mesh", sink: :dry_run, consent: :off, node_id: node] ++ opts)

      assert {:ok, %{previewed: n}} = result.sink_result
      assert n > 0
      assert FileCheckpoint.since_map(node) == %{}
    end
  end

  describe "jsonl sink" do
    test "appends one JSON object per record", %{tmp: tmp, base_opts: opts} do
      path = Path.join(tmp, "out.jsonl")

      result =
        Harvest.run([project: "mark_mesh", sink: {Sink.Jsonl, [path: path]}, consent: :off] ++ opts)

      assert {:ok, %{written: n, path: ^path}} = result.sink_result
      assert n == result.count

      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == result.count

      for line <- lines do
        decoded = Jason.decode!(line)
        assert decoded["agent"] == "codex"
        assert is_binary(decoded["content"])
      end
    end
  end

  describe "mcp sink" do
    test "posts one stage_memory tools/call per record", %{base_opts: opts} do
      test_pid = self()

      adapter = fn request ->
        payload = Jason.decode!(request.body)
        send(test_pid, {:mcp_call, payload})
        {request, %Req.Response{status: 200, body: %{"result" => %{"isError" => false}}}}
      end

      sink =
        {Sink.Mcp,
         [
           project: "mark_mesh",
           api_key: "test-key",
           node_id: "tester@mcp",
           req_options: [adapter: adapter, retry: false]
         ]}

      result = Harvest.run([project: "mark_mesh", sink: sink, consent: :off] ++ opts)

      assert {:ok, %{pushed: n}} = result.sink_result
      assert n == result.count

      for _ <- 1..result.count do
        assert_received {:mcp_call, payload}
        assert payload["method"] == "tools/call"
        assert %{"name" => "stage_memory", "arguments" => %{"input" => input}} = payload["params"]
        assert input["project"] == "mark_mesh"
        assert input["agent"] == "codex"
        assert input["node_id"] == "tester@mcp"
        assert is_float(input["importance"])
      end
    end

    test "tool errors fail the run (so cursors are not advanced)", %{base_opts: opts} do
      adapter = fn request ->
        {request,
         %Req.Response{
           status: 200,
           body: %{"result" => %{"isError" => true, "content" => [%{"text" => "boom"}]}}
         }}
      end

      sink =
        {Sink.Mcp,
         [
           project: "mark_mesh",
           api_key: "test-key",
           node_id: "tester@mcp-fail",
           req_options: [adapter: adapter, retry: false]
         ]}

      result =
        Harvest.run([project: "mark_mesh", sink: sink, consent: :off, node_id: "tester@mcp-fail"] ++ opts)

      assert {:error, %{failed: n, errors: ["boom" | _]}} = result.sink_result
      assert n == result.count
      assert FileCheckpoint.since_map("tester@mcp-fail") == %{}
    end
  end

  describe "importance/1" do
    test "signal words raise the score, capped at 1.0" do
      plain = Harvest.importance("ok")
      signalled = Harvest.importance("root cause: the fix, because we must always avoid it")
      huge = Harvest.importance("because decision decided fix fixed trap gotcha never always must avoid root cause lesson")

      assert signalled > plain
      assert huge == 1.0
    end
  end

  # Same fabrication as codex_projects_filter_test.exs
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
