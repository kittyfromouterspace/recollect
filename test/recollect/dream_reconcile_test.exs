defmodule Recollect.DreamReconcileTest do
  use Recollect.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Recollect.Config
  alias Recollect.Dream
  alias Recollect.Schema.Conflict
  alias Recollect.Schema.Entry
  alias Recollect.Schema.Reconciliation

  setup do
    scope_id = Fixtures.scope_id()
    owner_id = Fixtures.owner_id()

    {:ok, scope_id: scope_id, owner_id: owner_id}
  end

  defp contradictory_pair(scope_id, owner_id, thesis_text, antithesis_text) do
    a = Fixtures.entry(scope_id: scope_id, owner_id: owner_id, content: thesis_text)
    b = Fixtures.entry(scope_id: scope_id, owner_id: owner_id, content: antithesis_text)

    {:ok, _} =
      Recollect.Conflicts.persist(scope_id, owner_id, [
        %{entry_a_id: a.id, entry_b_id: b.id, reason: "contradiction", score: 0.9}
      ])

    {a, b}
  end

  defp run_reconcile(scope_id, extra \\ []) do
    {:ok, result} = Dream.run(scope_id, Keyword.merge([stages: [Recollect.Dream.Reconcile]], extra))
    result.stages["reconcile"]["metrics"]
  end

  describe "Dream.Reconcile (MEM-025)" do
    test "contradictory claims produce an unresolved reconciliation with both ids (no LLM)", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      {a, b} = contradictory_pair(scope_id, owner_id, "Postgres is the primary store.", "MySQL is the primary store.")

      metrics = run_reconcile(scope_id)
      assert metrics["conflicts_seen"] == 1
      assert metrics["unresolved"] == 1

      [rec] = Config.repo().all(from(r in Reconciliation, where: r.scope_id == ^scope_id))
      assert rec.unresolved == true
      assert rec.status == "unresolved"
      assert rec.thesis_entry_id in [a.id, b.id]
      assert rec.antithesis_entry_id in [a.id, b.id]
      assert rec.thesis_entry_id != rec.antithesis_entry_id
      assert is_nil(rec.synthesis_entry_id)
      assert rec.reasoning
    end

    test "the losing claims keep content, gain valid_to, and keep their half-life" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {a, b} =
        contradictory_pair(scope_id, owner_id, "Thesis: retries cap at 60s.", "Antithesis: retries cap at 30s.")

      # half-life values that must survive reconciliation
      Config.repo().update_all(
        from(e in Entry, where: e.id in [^a.id, ^b.id]),
        set: [half_life_days: 9.5]
      )

      synthesis_fn = fn _messages, _opts ->
        {:ok, "Retries cap at the lower of 30s/60s depending on the deployment tier."}
      end

      metrics = run_reconcile(scope_id, synthesis_fn: synthesis_fn)
      assert metrics["reconciled"] == 1

      reloaded = Config.repo().all(from(e in Entry, where: e.id in [^a.id, ^b.id]))
      assert Enum.all?(reloaded, &(&1.valid_to && &1.half_life_days == 9.5))
      assert Enum.any?(reloaded, &(&1.content =~ "Thesis"))
      assert Enum.any?(reloaded, &(&1.content =~ "Antithesis"))

      # a synthesis claim exists with supersedes edges to both old claims
      # (source_id uses the CANONICAL pair order, like the stage does)
      [min_id, max_id] = Enum.sort([a.id, b.id])
      source_id = "reconcile:#{min_id}:#{max_id}"

      synthesis =
        Config.repo().one(from(e in Entry, where: e.source_id == ^source_id))

      assert synthesis
      assert synthesis.content =~ "Retries cap"

      edges =
        Config.repo().all(from(ed in Recollect.Schema.Edge, where: ed.relation == "supersedes"))

      assert length(edges) == 2
      assert Enum.all?(edges, &(&1.source_entry_id == synthesis.id))
    end

    test "the resolved conflict closes; an unresolved one stays open" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {a, _b} = contradictory_pair(scope_id, owner_id, "Thesis A.", "Antithesis B.")

      synthesis_fn = fn _messages, _opts -> {:ok, "Both statements agree under config-specific defaults."} end
      run_reconcile(scope_id, synthesis_fn: synthesis_fn)

      conflict = Config.repo().get_by(Conflict, entry_a_id: a.id)
      assert conflict.status == "resolved"
      assert conflict.resolved_by

      # unresolved case: rerun with no synthesis on a fresh pair
      {c, d} = contradictory_pair(scope_id, owner_id, "Thesis C.", "Antithesis D.")
      run_reconcile(scope_id)

      conflict_cd = Config.repo().get_by(Conflict, entry_a_id: c.id)
      assert conflict_cd.status == "open"
      assert conflict_cd.entry_b_id == d.id
    end

    test "rerunning does not duplicate the reconciliation (single-flight)", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      contradictory_pair(scope_id, owner_id, "Thesis: e2e tests gate merges.", "Antithesis: only unit tests gate merges.")

      run_reconcile(scope_id)
      run_reconcile(scope_id)

      count = Config.repo().aggregate(Reconciliation, :count, :id)
      assert count == 1
    end

    test "pair order is canonical: (a, b) and (b, a) are the same row", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      {a, b} = contradictory_pair(scope_id, owner_id, "T1.", "A1.")

      # reverse the pair in a second conflict row for a different scope pair? no —
      # same pair in a fresh scope reconciles to identical canonical order
      other_scope = Fixtures.scope_id()
      a2 = Fixtures.entry(scope_id: other_scope, owner_id: owner_id, content: a.content)
      b2 = Fixtures.entry(scope_id: other_scope, owner_id: owner_id, content: b.content)

      {:ok, _} =
        Recollect.Conflicts.persist(other_scope, owner_id, [
          %{entry_a_id: b2.id, entry_b_id: a2.id, reason: "contradiction", score: 0.9}
        ])

      run_reconcile(scope_id)
      run_reconcile(other_scope)

      recs =
        Config.repo().all(from(r in Reconciliation, order_by: [asc: r.scope_id]))

      assert length(recs) == 2
      # canonical: thesis is always the smaller id
      assert Enum.all?(recs, &(&1.thesis_entry_id < &1.antithesis_entry_id))
    end

    test "telemetry: conflicts_seen / reconciled / unresolved", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      contradictory_pair(scope_id, owner_id, "T.", "A.")
      metrics = run_reconcile(scope_id)

      assert metrics["conflicts_seen"] == 1
      assert metrics["unresolved"] == 1
      assert metrics["reconciled"] == 0
    end
  end
end
