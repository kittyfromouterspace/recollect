defmodule Recollect.BriefTest do
  use Recollect.DataCase, async: false

  alias Recollect.Brief
  alias Recollect.Knowledge
  alias Recollect.Tokenizer

  setup do
    Brief.init()
    scope_id = Fixtures.scope_id()
    owner_id = Fixtures.owner_id()

    on_exit(fn ->
      Brief.invalidate(scope_id)
    end)

    {:ok, scope_id: scope_id, owner_id: owner_id}
  end

  defp remember_rule(scope_id, owner_id, content, opts \\ []) do
    Knowledge.remember(content,
      scope_id: scope_id,
      owner_id: owner_id,
      tags: Keyword.get(opts, :tags, ["rule"]),
      stability: Keyword.get(opts, :stability, :stable),
      entry_type: Keyword.get(opts, :entry_type, :note)
    )
  end

  describe "build/2 (MEM-019)" do
    test "renders markdown with a budget header, sections, and citations", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      {:ok, _} = remember_rule(scope_id, owner_id, "Always run mix format before committing.")
      {:ok, _} = Recollect.Handoff.create(scope_id, what: "Auth refactor", next: ["finish login tests"])

      assert {:ok, brief} = Brief.build(scope_id, workspace: "acme")

      assert brief.text =~ "## Memory brief (workspace: acme,"
      assert brief.text =~ "### Rules (stable)"
      assert brief.text =~ "Always run mix format before committing."
      assert brief.text =~ "### Focus"
      assert brief.text =~ "Where we left off: Auth refactor"
      assert brief.text =~ "[e1]"
      assert brief.text =~ "[h1]"
      assert brief.used > 0
      assert brief.used <= brief.budget
    end

    test "verified entries show the verified date in their citation", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      {:ok, _} =
        remember_rule(scope_id, owner_id, "Deploy checklist: run migrations first.",
          tags: ["rule"],
          stability: :stable
        )

      {:ok, _} =
        Knowledge.remember("Migrations run before swap, always.",
          scope_id: scope_id,
          owner_id: owner_id,
          tags: ["rule"],
          stability: :stable,
          verification: "code_ref"
        )

      assert {:ok, brief} = Brief.build(scope_id)
      assert brief.text =~ "verified"
    end

    test "stays under budget for 1, 10, and 100 candidates", %{scope_id: _scope_id, owner_id: owner_id} do
      for count <- [1, 10, 100] do
        scope = Fixtures.scope_id()

        for i <- 1..count do
          remember_rule(scope, owner_id, "Rule #{i}: deploy checklist item with enough words to matter #{i}.")
        end

        assert {:ok, brief} = Brief.build(scope, per_section: 100)
        assert Tokenizer.estimate(brief.text) <= brief.budget + 60, "count #{count} exceeded budget"
        assert brief.used <= brief.budget
        Brief.invalidate(scope)
      end
    end

    test "rules (stable) render before volatile sections", %{scope_id: scope_id, owner_id: owner_id} do
      {:ok, _} =
        Knowledge.remember("Gotcha: the swap needs a drain first.",
          scope_id: scope_id,
          owner_id: owner_id,
          tags: ["gotcha"],
          stability: :volatile
        )

      {:ok, _} = remember_rule(scope_id, owner_id, "Format before commit.")

      assert {:ok, brief} = Brief.build(scope_id)
      assert {rules_offset, _} = :binary.match(brief.text, "### Rules")
      assert {traps_offset, _} = :binary.match(brief.text, "### Traps")
      assert rules_offset < traps_offset
    end

    test "an entry qualifying for several sections appears once", %{scope_id: scope_id, owner_id: owner_id} do
      # tagged rule AND gotcha, also held epistemic — rules section wins
      {:ok, entry} =
        Knowledge.remember("Double-tagged claim about rollbacks.",
          scope_id: scope_id,
          owner_id: owner_id,
          tags: ["rule", "gotcha"],
          stability: :stable,
          epistemic: :held
        )

      assert {:ok, brief} = Brief.build(scope_id)
      hits = Enum.filter(brief.items, &(&1.id == entry.id))
      assert length(hits) == 1
      assert hd(hits).section == :rules
    end

    test "cache serves the same generation; a write bumps it and changes output", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      {:ok, _} = remember_rule(scope_id, owner_id, "First rule.")

      assert {:ok, brief1} = Brief.build(scope_id)
      assert {:ok, brief2} = Brief.build(scope_id)
      assert brief2.generation == brief1.generation
      assert brief2.text == brief1.text

      {:ok, _} = remember_rule(scope_id, owner_id, "Second rule, added later.")

      assert {:ok, brief3} = Brief.build(scope_id)
      assert brief3.generation > brief1.generation
      assert brief3.text =~ "Second rule, added later."
      refute brief3.text == brief1.text
    end

    test "a budget too small for any item returns explicit empty text", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      {:ok, _} = remember_rule(scope_id, owner_id, "A rule long enough to not fit a tiny budget.")

      assert {:ok, brief} = Brief.build(scope_id, budget: 5)
      assert brief.text == ""
      assert brief.truncated == true
      assert brief.dropped != []
    end

    test "render/2 re-renders built briefs in other formats", %{scope_id: scope_id, owner_id: owner_id} do
      {:ok, _} = remember_rule(scope_id, owner_id, "Render me in three shapes.")

      assert {:ok, brief} = Brief.build(scope_id, format: :text)
      assert brief.text =~ "Memory brief (workspace:"
      assert brief.text =~ "Render me in three shapes."

      markdown = Brief.render(brief, :markdown)
      assert markdown =~ "### Rules (stable)"

      json = Brief.render(brief, :json)
      assert {:ok, decoded} = Jason.decode(json)
      assert %{"sections" => sections, "budget" => _, "used" => _} = decoded

      item = sections |> Enum.find(&(&1["key"] == "rules")) |> then(&hd(&1["items"]))
      assert item["citation"] =~ ~r/^e\d+$/
      assert is_integer(item["tokens"]) and item["tokens"] > 0
      assert item["id"]
    end

    test "text format has no markdown headers", %{scope_id: scope_id, owner_id: owner_id} do
      {:ok, _} = remember_rule(scope_id, owner_id, "Plain text rule.")

      assert {:ok, brief} = Brief.build(scope_id, format: :text)
      refute brief.text =~ "###"
      assert brief.text =~ "Rules (stable):"
    end
  end

  describe "invalidate/1" do
    test "forgetting an entry invalidates the cached brief", %{scope_id: scope_id, owner_id: owner_id} do
      {:ok, entry} = remember_rule(scope_id, owner_id, "Soon to be forgotten rule.")

      assert {:ok, brief1} = Brief.build(scope_id)
      assert brief1.text =~ "Soon to be forgotten rule."

      {:ok, _} = Knowledge.forget(entry.id)

      assert {:ok, brief2} = Brief.build(scope_id)
      refute brief2.text =~ "Soon to be forgotten rule."
    end
  end
end
