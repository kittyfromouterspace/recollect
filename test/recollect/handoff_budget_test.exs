defmodule Recollect.HandoffBudgetTest do
  use Recollect.DataCase, async: false

  alias Recollect.Handoff
  alias Recollect.Tokenizer
  alias Recollect.WorkingMemory

  setup do
    scope_id = Fixtures.scope_id()

    previous = Application.get_env(:recollect, :brief)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:recollect, :brief, previous),
        else: Application.delete_env(:recollect, :brief)

      WorkingMemory.clear(scope_id)
    end)

    {:ok, scope_id: scope_id}
  end

  describe "Handoff.create/2 budget caps (MEM-022)" do
    test "over-budget handoffs are truncated with explicit markers" do
      Application.put_env(:recollect, :brief, token_budget: 120)

      scope_id = Fixtures.scope_id()
      long_what = String.duplicate("what context ", 40)
      next = for i <- 1..30, do: "step #{i} with enough words to matter for the budget"

      assert {:ok, _} = Handoff.create(scope_id, what: long_what, next: next)
      assert {:ok, handoff} = Handoff.get(scope_id)

      # string cap applied with marker
      assert handoff.what =~ "…[truncated]"
      # list cap applied with marker
      assert Enum.any?(handoff.next, &(&1 =~ "truncated"))

      # and the whole thing fits the configured budget
      parts = [handoff.what | handoff.next]
      assert Tokenizer.estimate(Enum.join(parts, "\n")) <= 120
    end

    test "under-budget handoffs pass through unmarked" do
      scope_id = Fixtures.scope_id()

      assert {:ok, _} = Handoff.create(scope_id, what: "Short handoff", next: ["one", "two"])
      assert {:ok, handoff} = Handoff.get(scope_id)

      refute handoff.what =~ "truncated"
      assert handoff.next == ["one", "two"]
      assert handoff.blockers == []
    end
  end

  describe "WorkingMemory.load_handoff/1 bounds (MEM-022)" do
    test "large handoffs load few, low-importance items and never evict session notes", %{
      scope_id: scope_id
    } do
      Application.put_env(:recollect, :brief, max_items_per_section: 4)

      # the session's own note
      WorkingMemory.push(scope_id, "session note: the parser fix is half done", importance: 0.85)

      next = for i <- 1..30, do: "step #{i}"
      artifacts = for i <- 1..10, do: "artifact #{i}"

      {:ok, _} = Handoff.create(scope_id, what: "big handoff", next: next, artifacts: artifacts)
      assert {:ok, %{pushed: pushed}} = WorkingMemory.load_handoff(scope_id)
      assert pushed <= 4

      {:ok, entries} = WorkingMemory.read(scope_id)

      # session note survived (a 40-item handoff used to evict it)
      assert Enum.any?(entries, &(&1.content =~ "session note"))
      # and every handoff item ranks below the session note
      note_importance = entries |> Enum.find(&(&1.content =~ "session note")) |> then(& &1.importance)

      assert Enum.all?(entries, &(&1.importance <= note_importance))
    end
  end
end
