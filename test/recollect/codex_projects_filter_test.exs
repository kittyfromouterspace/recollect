defmodule Recollect.CodexProjectsFilterTest do
  @moduledoc "The Codex provider must honor the :projects filter (parity with Claude Code)."
  use ExUnit.Case, async: true

  alias Recollect.Learner.CodingAgent.Codex

  setup do
    base = Path.join(System.tmp_dir!(), "codex-test-#{System.unique_integer([:positive])}")
    sessions = Path.join(base, "sessions")
    File.mkdir_p!(sessions)

    write_session(sessions, "mark_mesh", "/home/lenz/code/mark_mesh", "fix the bulletin parser")
    write_session(sessions, "ops", "/home/lenz/code/ops_center", "deploy ops_center")

    on_exit(fn -> File.rm_rf!(base) end)
    %{config: %{data_paths: [base]}}
  end

  test "no filter returns sessions from all projects", %{config: config} do
    projects = config |> Codex.fetch_events([]) |> session_projects()
    assert "mark_mesh" in projects
    assert "ops_center" in projects
  end

  test ":projects keeps only matching sessions", %{config: config} do
    projects = config |> Codex.fetch_events(projects: ["mark_mesh"]) |> session_projects()
    assert projects == ["mark_mesh"]
  end

  test ":projects with no match drops everything", %{config: config} do
    assert config |> Codex.fetch_events(projects: ["nope"]) |> session_projects() == []
  end

  defp session_projects(events) do
    events
    |> Enum.filter(&(&1.source == :session))
    |> Enum.map(& &1.project)
    |> Enum.uniq()
    |> Enum.sort()
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
