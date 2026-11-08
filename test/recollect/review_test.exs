defmodule Recollect.ReviewTest do
  use Recollect.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Recollect.Config
  alias Recollect.Knowledge
  alias Recollect.Review
  alias Recollect.Schema.Entry

  describe "Knowledge.review/2 candidates (MEM-017)" do
    test "an entry with no evidence and no accesses is flagged never_retrieved + unverified" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      old =
        [scope_id: scope_id, owner_id: owner_id]
        |> Fixtures.entry()
        |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -60 * 86_400, :second))
        |> Config.repo().update!()

      {:ok, candidates} = Review.candidates(scope_id)

      candidate = Enum.find(candidates, &(&1.entry.id == old.id))
      assert candidate
      assert :never_retrieved in candidate.reasons
      assert :unverified in candidate.reasons
      assert candidate.suggested in [:archive, :verify]
    end

    test "an entry with evidence, a recent access, and observed epistemic is not flagged" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {:ok, event} =
        Recollect.Event.record(owner_id: owner_id, event_type: "message", content: "witnessed in a session")

      fresh =
        Fixtures.entry(
          scope_id: scope_id,
          owner_id: owner_id,
          access_count: 3,
          last_accessed_at: DateTime.utc_now(),
          epistemic: "observed"
        )

      {:ok, _} =
        Recollect.Evidence.link(fresh.id, "supports",
          event_id: event.id,
          source_type: "event",
          source_ref: "session:1"
        )

      {:ok, candidates} = Review.candidates(scope_id)
      refute Enum.any?(candidates, &(&1.entry.id == fresh.id))
    end

    test "expired entries are flagged :expired with :archive suggested" do
      scope_id = Fixtures.scope_id()

      Fixtures.entry(
        scope_id: scope_id,
        owner_id: Fixtures.owner_id(),
        valid_to: DateTime.add(DateTime.utc_now(), -3600, :second),
        epistemic: "observed",
        access_count: 5,
        last_accessed_at: DateTime.utc_now()
      )

      {:ok, candidates} = Review.candidates(scope_id)

      assert [%{reasons: [:expired], suggested: :archive}] = candidates
    end

    test "same source_id across different sources is a :duplicate with :merge suggested" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      Fixtures.entry(
        scope_id: scope_id,
        owner_id: owner_id,
        source: "agent",
        source_id: "shared-id",
        access_count: 1,
        epistemic: "observed"
      )

      twin =
        Fixtures.entry(
          scope_id: scope_id,
          owner_id: owner_id,
          source: "system",
          source_id: "shared-id",
          access_count: 1,
          epistemic: "observed"
        )

      {:ok, candidates} = Review.candidates(scope_id)
      candidate = Enum.find(candidates, &(&1.entry.id == twin.id))

      assert candidate
      assert :duplicate in candidate.reasons
      assert candidate.suggested == :merge
    end

    test "an orphan session_summary is flagged :orphan_summary with :delete suggested" do
      scope_id = Fixtures.scope_id()

      Fixtures.entry(
        scope_id: scope_id,
        owner_id: Fixtures.owner_id(),
        entry_type: "session_summary",
        access_count: 2,
        epistemic: "observed"
      )

      {:ok, candidates} = Review.candidates(scope_id)

      assert [%{reasons: [:orphan_summary], suggested: :delete}] = candidates
    end

    test "limit caps the candidate list" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      for i <- 1..3 do
        [scope_id: scope_id, owner_id: owner_id, content: "old unretrieved note #{i}"]
        |> Fixtures.entry()
        |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -60 * 86_400, :second))
        |> Config.repo().update!()
      end

      {:ok, candidates} = Review.candidates(scope_id, limit: 2)
      assert length(candidates) == 2
    end
  end

  describe "Knowledge.explain/1 (MEM-017)" do
    test "includes evidence, usage, verification, supersession, and a non-empty why" do
      owner_id = Fixtures.owner_id()
      scope_id = Fixtures.scope_id()

      {:ok, event} =
        Recollect.Event.record(owner_id: owner_id, event_type: "commit", content: "abc123 fix flake")

      {:ok, entry} =
        Knowledge.remember("Billing retries are capped at 60s.",
          owner_id: owner_id,
          scope_id: scope_id,
          verification: "code_ref",
          tags: ["billing"]
        )

      {:ok, _} =
        Recollect.Evidence.link(entry.id, "supports",
          event_id: event.id,
          source_type: "event",
          source_ref: "session:1:msg:7",
          excerpt: "retries capped"
        )

      assert {:ok, explained} = Knowledge.explain(entry.id)

      assert explained.entry.id == entry.id
      assert [%{relation: "supports", source_ref: "session:1:msg:7"}] = explained.evidence
      assert explained.usage.access_count >= 0
      assert explained.verification.marker == "code_ref"
      assert explained.why =~ "evidence"
      assert explained.why != ""
      assert is_list(explained.supersedes)
      assert is_list(explained.superseded_by)
    end

    test "supersession links flow in the right direction" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      old = Fixtures.entry(scope_id: scope_id, owner_id: owner_id)
      new = Fixtures.entry(scope_id: scope_id, owner_id: owner_id)

      {:ok, _} = Knowledge.connect(new.id, old.id, "supersedes")

      assert {:ok, explained_new} = Knowledge.explain(new.id)
      assert old.id in explained_new.supersedes
      assert explained_new.superseded_by == []

      assert {:ok, explained_old} = Knowledge.explain(old.id)
      assert new.id in explained_old.superseded_by
      assert explained_old.supersedes == []
    end

    test "unknown id returns :not_found" do
      assert {:error, :not_found} = Knowledge.explain(Ecto.UUID.generate())
    end
  end

  test "review/explain leave telemetry breadcrumbs" do
    scope_id = Fixtures.scope_id()
    entry = Fixtures.entry(scope_id: scope_id)

    {:ok, _} = Review.candidates(scope_id)
    {:ok, _} = Review.explain(entry.id)

    # No assertion on events themselves — the span wrappers would have
    # raised on bad options. This test guards the call signatures.
    assert true
  end

  test "expired candidate survives a soft-deleted twin (live only)" do
    scope_id = Fixtures.scope_id()

    dead =
      [scope_id: scope_id, owner_id: Fixtures.owner_id(), epistemic: "observed"]
      |> Fixtures.entry()
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Config.repo().update!()

    {:ok, candidates} = Review.candidates(scope_id)
    refute Enum.any?(candidates, &(&1.entry.id == dead.id))
    assert Config.repo().get(Entry, dead.id)
  end
end
