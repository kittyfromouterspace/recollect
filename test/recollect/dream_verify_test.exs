defmodule Recollect.DreamVerifyTest do
  use Recollect.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Recollect.Config
  alias Recollect.Dream
  alias Recollect.Dream.Verify
  alias Recollect.Schema.Entry

  setup do
    scope_id = Fixtures.scope_id()
    owner_id = Fixtures.owner_id()

    previous = Application.get_env(:recollect, :dream)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:recollect, :dream, previous),
        else: Application.delete_env(:recollect, :dream)
    end)

    {:ok, scope_id: scope_id, owner_id: owner_id}
  end

  defp claim_with_evidence(scope_id, owner_id, content, evidence) do
    entry = Fixtures.entry(scope_id: scope_id, owner_id: owner_id, content: content)

    Enum.each(evidence, fn spec ->
      {:ok, _} =
        Recollect.Evidence.link(
          entry.id,
          spec[:relation] || "supports",
          event_id: spec[:event_id],
          source_type: spec[:source_type],
          source_ref: spec[:source_ref],
          excerpt: spec[:excerpt]
        )
    end)

    entry
  end

  defp live_entry(entry_id) do
    Config.repo().get!(Entry, entry_id)
  end

  defp run_verify(scope_id, extra \\ []) do
    Dream.run(scope_id, Keyword.merge([stages: [Verify]], extra))
  end

  defp verify_metrics(scope_id, extra \\ []) do
    {:ok, result} = run_verify(scope_id, extra)
    stage = result.stages["verify"]
    stage["metrics"]
  end

  describe "Dream.Verify (MEM-024)" do
    test "existing file evidence verifies (verification code_ref, observed upgrade)" do
      path = Path.join(System.tmp_dir!(), "verify-ok-#{System.unique_integer([:positive])}.ex")
      File.write!(path, "the real deploy script")

      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      entry =
        claim_with_evidence(scope_id, owner_id, "Deploy uses scripts/deploy.sh", [
          %{source_type: "file", source_ref: path}
        ])

      metrics = verify_metrics(scope_id)
      assert metrics["verified"] == 1

      updated = live_entry(entry.id)
      assert updated.verification == "code_ref"
      assert updated.verified_at
      assert updated.epistemic == "observed"

      File.rm!(path)
    end

    test "missing file evidence downgrades to held + stale, never deletes" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      entry =
        claim_with_evidence(scope_id, owner_id, "Claim about a file that vanished", [
          %{source_type: "file", source_ref: "/nonexistent/definitely-gone-#{System.unique_integer()}.ex"}
        ])

      metrics = verify_metrics(scope_id)
      assert metrics["downgraded"] == 1

      updated = live_entry(entry.id)
      assert updated.epistemic == "held"
      assert updated.confidence_state == "stale"
      assert updated.content == "Claim about a file that vanished"
      refute updated.deleted_at
    end

    test "user evidence is authoritative (verification user)" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      entry =
        claim_with_evidence(scope_id, owner_id, "The user confirmed the migration order.", [
          %{source_type: "user", source_ref: "user:lenz"}
        ])

      metrics = verify_metrics(scope_id)
      assert metrics["verified"] == 1

      updated = live_entry(entry.id)
      assert updated.verification == "user"
      assert updated.epistemic == "observed"
    end

    test "live event evidence verifies as cross_session; a nullified event downgrades" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {:ok, event} =
        Recollect.Event.record(
          owner_id: owner_id,
          scope_id: scope_id,
          event_type: "message",
          content: "the transcript backing the claim"
        )

      good =
        claim_with_evidence(scope_id, owner_id, "Claim with a live transcript", [
          %{source_type: "event", event_id: event.id, source_ref: "session:1"}
        ])

      stale =
        claim_with_evidence(scope_id, owner_id, "Claim whose event was pruned", [
          %{source_type: "event", source_ref: "session:9"}
        ])

      metrics = verify_metrics(scope_id)
      assert metrics["verified"] == 1
      assert metrics["downgraded"] == 1

      assert live_entry(good.id).verification == "cross_session"
      assert live_entry(stale.id).epistemic == "held"
    end

    test "budget stops the stage cleanly (max_items)" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      for i <- 1..3 do
        claim_with_evidence(scope_id, owner_id, "Budget claim #{i}", [
          %{source_type: "user", source_ref: "user:#{i}"}
        ])
      end

      metrics = verify_metrics(scope_id, max_items: 1)
      assert metrics["checked"] == 1
      assert metrics["truncated"] == true
    end

    test "the stage runs inside a dream run and records metrics" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      claim_with_evidence(scope_id, owner_id, "Inside a dream run claim.", [
        %{source_type: "user", source_ref: "user:lenz"}
      ])

      assert {:ok, result} = Dream.run(scope_id, stages: [Verify])

      assert result.status == "done"
      assert result.stages["verify"]["status"] == "completed"
      assert result.stages["verify"]["metrics"]["verified"] == 1
    end

    test "url checks stay behind the config flag" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      entry =
        claim_with_evidence(scope_id, owner_id, "Claim citing a URL.", [
          %{source_type: "url", source_ref: "https://example.invalid/no-such-page"}
        ])

      # flag off: skipped, nothing changes
      metrics = verify_metrics(scope_id)
      assert metrics["unchanged"] == 1
      assert live_entry(entry.id).verification == "none"

      # flag on: unreachable URL downgrades
      Application.put_env(:recollect, :dream, check_urls: true)
      metrics = verify_metrics(scope_id)
      assert metrics["downgraded"] == 1
    end
  end
end
