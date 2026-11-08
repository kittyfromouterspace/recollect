defmodule Recollect.KnowledgeLifecycleTest do
  use Recollect.DataCase, async: false

  alias Recollect.Config
  alias Recollect.Knowledge
  alias Recollect.Schema.Entry

  describe "remember/2 lifecycle options (MEM-014)" do
    test "memory_level, stability, epistemic round-trip" do
      {:ok, entry} =
        Knowledge.remember("Deploy checklist: run migrations before swap.",
          scope_id: Fixtures.scope_id(),
          owner_id: Fixtures.owner_id(),
          memory_level: :global,
          stability: :stable,
          epistemic: :observed
        )

      assert entry.memory_level == "global"
      assert entry.stability == "stable"
      assert entry.epistemic == "observed"
    end

    test "defaults are workspace/evolving/inferred/none/version 1" do
      {:ok, entry} =
        Knowledge.remember("Just a note.",
          scope_id: Fixtures.scope_id(),
          owner_id: Fixtures.owner_id()
        )

      assert entry.memory_level == "workspace"
      assert entry.stability == "evolving"
      assert entry.epistemic == "inferred"
      assert entry.verification == "none"
      assert entry.version == 1
      assert is_nil(entry.valid_from)
      assert is_nil(entry.deleted_at)
    end

    test "verification stamps verified_at when not 'none'" do
      {:ok, entry} =
        Knowledge.remember("The retrier caps backoff at 60s.",
          scope_id: Fixtures.scope_id(),
          owner_id: Fixtures.owner_id(),
          verification: "code_ref"
        )

      assert entry.verification == "code_ref"
      assert entry.verified_at
    end

    test "validity window round-trips" do
      from = DateTime.add(DateTime.utc_now(), -86_400, :second)

      {:ok, entry} =
        Knowledge.remember("Ephemeral incident note.",
          scope_id: Fixtures.scope_id(),
          owner_id: Fixtures.owner_id(),
          valid_from: from,
          valid_to: DateTime.utc_now()
        )

      assert entry.valid_from == from
      assert entry.valid_to
    end

    test "invalid enum values return a changeset error" do
      assert {:error, %Ecto.Changeset{}} =
               Knowledge.remember("Bogus level.",
                 scope_id: Fixtures.scope_id(),
                 owner_id: Fixtures.owner_id(),
                 memory_level: :cosmic
               )
    end
  end

  describe "forget/1 soft delete (MEM-014)" do
    test "hides the entry from recent but keeps the row" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {:ok, entry} = Knowledge.remember("soft deleted knowledge", scope_id: scope_id, owner_id: owner_id)

      assert {:ok, softly_deleted} = Knowledge.forget(entry.id)
      assert softly_deleted.deleted_at

      {:ok, recents} = {:ok, Knowledge.recent(scope_id, limit: 50)}
      refute Enum.any?(recents, &(&1.id == entry.id))
      assert Config.repo().get(Entry, entry.id)
    end

    test "hard: true removes the row" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {:ok, entry} = Knowledge.remember("hard deleted knowledge", scope_id: scope_id, owner_id: owner_id)

      assert {:ok, _} = Knowledge.forget(entry.id, hard: true)
      assert Config.repo().get(Entry, entry.id) == nil
    end
  end

  describe "Entry.live/1" do
    test "excludes soft-deleted and archived entries" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      live_entry = Fixtures.entry(scope_id: scope_id, owner_id: owner_id)
      archived = Fixtures.entry(scope_id: scope_id, owner_id: owner_id, entry_type: "archived")

      dead =
        [scope_id: scope_id, owner_id: owner_id]
        |> Fixtures.entry()
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
        |> Config.repo().update!()

      ids = Entry |> Entry.live() |> Config.repo().all() |> Enum.map(& &1.id)

      assert live_entry.id in ids
      refute archived.id in ids
      refute dead.id in ids
    end
  end

  describe "dedupe :update version bump (MEM-012 deferral)" do
    test "re-storing the same source_id bumps the version" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {:ok, first} =
        Knowledge.remember("Initial claim about batching.",
          scope_id: scope_id,
          owner_id: owner_id,
          source: "agent",
          source_id: "session-1:turn-2",
          dedupe: :update
        )

      assert first.version == 1

      {:ok, updated} =
        Knowledge.remember("Refined claim about batching.",
          scope_id: scope_id,
          owner_id: owner_id,
          source: "agent",
          source_id: "session-1:turn-2",
          dedupe: :update
        )

      assert updated.dedupe_status == "updated"
      assert updated.version == first.version + 1
      assert updated.id == first.id
      assert updated.content == "Refined claim about batching."
    end

    test "dedupe :skip returns the existing row unchanged (same version)" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {:ok, first} =
        Knowledge.remember("Original wording.",
          scope_id: scope_id,
          owner_id: owner_id,
          source: "agent",
          source_id: "session-1:turn-4"
        )

      {:ok, skipped} =
        Knowledge.remember("Different wording.",
          scope_id: scope_id,
          owner_id: owner_id,
          source: "agent",
          source_id: "session-1:turn-4"
        )

      assert skipped.dedupe_status == "skipped"
      assert skipped.version == first.version
      assert skipped.content == "Original wording."
    end
  end
end
