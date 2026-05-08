defmodule Recollect.CodingAgentTest do
  use ExUnit.Case, async: true

  alias Recollect.Learner.CodingAgent
  alias Recollect.Learner.CodingAgent.ClaudeCode
  alias Recollect.Learner.CodingAgent.Codex
  alias Recollect.Learner.CodingAgent.Gemini
  alias Recollect.Learner.CodingAgent.OpenCode

  describe "CodingAgent" do
    test "source is :coding_agents" do
      assert CodingAgent.source() == :coding_agents
    end

    test "providers returns list of modules" do
      providers = CodingAgent.providers()

      assert is_list(providers)
      assert ClaudeCode in providers
      assert Codex in providers
      assert Gemini in providers
      assert OpenCode in providers
    end

    test "status returns availability info" do
      status = CodingAgent.status()

      assert is_list(status)
      assert length(status) >= 4

      for {name, available?, paths} <- status do
        assert is_atom(name)
        assert is_boolean(available?)
        assert is_list(paths)
      end
    end
  end

  describe "provider behaviour" do
    test "all providers implement required callbacks" do
      for provider <- CodingAgent.providers() do
        exports = provider.module_info(:exports)
        assert {:agent_name, 0} in exports
        assert {:default_data_paths, 0} in exports
        assert {:available?, 0} in exports or {:available?, 1} in exports
        assert {:fetch_events, 0} in exports or {:fetch_events, 1} in exports or {:fetch_events, 2} in exports
        assert {:extract, 1} in exports
      end
    end

    test "all providers return unique agent names" do
      names = Enum.map(CodingAgent.providers(), & &1.agent_name())

      assert length(names) == length(Enum.uniq(names))
    end

    test "all providers return non-empty data paths" do
      for provider <- CodingAgent.providers() do
        paths = provider.default_data_paths()
        assert is_list(paths)
        assert length(paths) > 0
      end
    end
  end

  describe "Claude Code provider" do
    test "agent name" do
      assert ClaudeCode.agent_name() == :claude_code
    end

    test "available reflects directory existence" do
      assert is_boolean(ClaudeCode.available?())
    end
  end

  describe "Codex provider" do
    test "agent name" do
      assert Codex.agent_name() == :codex
    end

    test "available reflects directory existence" do
      assert is_boolean(Codex.available?())
    end

    test "extract handles instructions event" do
      {:ok, extract} = Codex.extract(%{source: :instructions, content: "Always write tests."})

      assert extract.entry_type == :decision
      assert extract.content =~ "Always write tests"
    end

    test "extract skips empty instructions" do
      assert {:skip, _} = Codex.extract(%{source: :instructions, content: ""})
    end

    test "extract handles session event" do
      {:ok, extract} =
        Codex.extract(%{
          source: :session,
          user_prompts: ["Build a steampunk UI", "Add more chrome"],
          project: "geek_sessions",
          session_id: "abc123"
        })

      assert extract.entry_type == :note
      assert extract.content =~ "steampunk"
    end

    test "extract skips session with no prompts" do
      assert {:skip, _} = Codex.extract(%{source: :session, user_prompts: [], project: "x", session_id: "y"})
    end

    test "summarize groups sessions into insights" do
      events = [
        %{source: :session, user_prompts: ["fix bug"], project: "myapp", session_id: "s1"},
        %{source: :session, user_prompts: ["add feature"], project: "myapp", session_id: "s2"}
      ]

      insights = Codex.summarize(events, "scope")

      assert length(insights) == 1
      assert hd(insights).entry_type == :development_insight
    end
  end

  describe "Gemini provider" do
    test "agent name" do
      assert Gemini.agent_name() == :gemini
    end

    test "extract handles session event" do
      {:ok, extract} =
        Gemini.extract(%{
          source: :session,
          user_prompts: ["Analyze the codebase", "Fix the tests"],
          project: "worth",
          session_id: "d5ec4b2a"
        })

      assert extract.entry_type == :note
      assert extract.content =~ "Analyze the codebase"
    end

    test "extract skips empty session" do
      assert {:skip, _} = Gemini.extract(%{source: :session, user_prompts: [], project: "x", session_id: "y"})
    end
  end

  describe "OpenCode provider" do
    test "agent name" do
      assert OpenCode.agent_name() == :opencode
    end

    test "extract handles session event" do
      {:ok, extract} =
        OpenCode.extract(%{
          source: :session,
          title: "Fix auth bug",
          project: "worth",
          directory: "/home/lenz/code/worth"
        })

      assert extract.entry_type == :note
      assert extract.content =~ "Fix auth bug"
    end

    test "summarize groups sessions into insights" do
      events = [
        %{source: :session, title: "Session 1", project: "worth", directory: "/home/lenz/code/worth"},
        %{source: :session, title: "Session 2", project: "worth", directory: "/home/lenz/code/worth"},
        %{source: :session, title: "Session 3", project: "other", directory: "/home/lenz/code/other"}
      ]

      insights = OpenCode.summarize(events, "scope")

      worth = Enum.find(insights, &String.contains?(&1.content, "worth"))
      assert worth
      assert worth.metadata[:session_count] == 2
    end
  end

  describe "CodingAgent.extract dispatches to correct provider" do
    test "dispatches claude_code events" do
      {:ok, extract} =
        CodingAgent.extract(%{
          agent: :claude_code,
          source: :claude_md,
          project: "test",
          content: "Use Elixir conventions."
        })

      assert extract.content =~ "Elixir conventions"
    end

    test "dispatches codex events" do
      {:ok, extract} =
        CodingAgent.extract(%{
          agent: :codex,
          source: :instructions,
          content: "Be concise."
        })

      assert extract.content =~ "Be concise"
    end

    test "skips unknown agent" do
      assert {:skip, _} = CodingAgent.extract(%{agent: :unknown_agent, source: :whatever})
    end
  end
end
