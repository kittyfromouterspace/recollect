defmodule Recollect.ProjectMappingTest do
  use ExUnit.Case, async: true

  alias Recollect.Learner.ProjectMapping

  describe "matches_slug?/2" do
    test "matches a claude-style path key" do
      assert ProjectMapping.matches_slug?("mark_mesh", "-home-lenz-code-mark_mesh")
    end

    test "matches a dash-separated key" do
      assert ProjectMapping.matches_slug?("mark_mesh", "mark-mesh")
    end

    test "matches a bare slug" do
      assert ProjectMapping.matches_slug?("mark_mesh", "mark_mesh")
    end

    test "rejects unrelated keys" do
      refute ProjectMapping.matches_slug?("mark_mesh", "-home-lenz-code-ops_center")
      refute ProjectMapping.matches_slug?("mark_mesh", "mesh_network")
    end
  end

  describe "relevant_agent_projects/2" do
    test "filters an injected discovered map" do
      discovered = %{
        claude_code: ["-home-lenz-code-mark_mesh", "-home-lenz-code-ops_center"],
        opencode: ["mark_mesh", "strategic_change_engine"]
      }

      assert ProjectMapping.relevant_agent_projects("mark_mesh", discovered) == %{
               claude_code: ["-home-lenz-code-mark_mesh"],
               opencode: ["mark_mesh"]
             }
    end

    test "agents with no matching keys are dropped" do
      assert ProjectMapping.relevant_agent_projects("ops_center", %{codex: ["mark_mesh"]}) == %{}
    end
  end

  describe "scope_for_key/2" do
    setup do
      root = Path.join(System.tmp_dir!(), "code-root-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "mark_mesh"))

      on_exit(fn -> File.rm_rf!(root) end)
      %{code_root: root}
    end

    test "resolves provider encodings against real checkouts", %{code_root: root} do
      assert ProjectMapping.scope_for_key("-home-lenz-code-mark-mesh", code_root: root) == "mark_mesh"
      assert ProjectMapping.scope_for_key("/home/lenz/code/mark_mesh", code_root: root) == "mark_mesh"
      assert ProjectMapping.scope_for_key("mark_mesh", code_root: root) == "mark_mesh"
    end

    test "falls back to the last segment for unknown checkouts", %{code_root: root} do
      assert ProjectMapping.scope_for_key("/home/lenz/code/ops_center", code_root: root) == "ops_center"
    end

    test "nil and unknown map to shared", %{code_root: root} do
      assert ProjectMapping.scope_for_key(nil, code_root: root) == "shared"
      assert ProjectMapping.scope_for_key("unknown", code_root: root) == "shared"
    end
  end
end
