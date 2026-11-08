defmodule Recollect.DreamPromoteTest do
  use Recollect.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Recollect.Config
  alias Recollect.Dream
  alias Recollect.Schema.Entry
  alias Recollect.Schema.EntryTag
  alias Recollect.Schema.Event, as: EventRow
  alias Recollect.Staging

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

  defp rule_candidate(scope_id, owner_id, content) do
    entry =
      Fixtures.entry(
        scope_id: scope_id,
        owner_id: owner_id,
        content: content,
        verification: "user",
        stability: "stable",
        last_accessed_at: DateTime.utc_now(),
        access_count: 12
      )

    {:ok, event} =
      Recollect.Event.record(owner_id: owner_id, scope_id: scope_id, event_type: "message", content: "witness")

    {:ok, _} = Recollect.Evidence.link(entry.id, "supports", event_id: event.id, source_type: "event", source_ref: "s:1")

    entry
  end

  describe "Dream.Promote (MEM-026)" do
    test "a verified, frequently retrieved claim is promoted with the rule tag" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()
      entry = rule_candidate(scope_id, owner_id, "Always run the smoke suite after deploy.")

      {:ok, metrics} = Dream.Promote.run(scope_id, [])
      assert metrics.promoted == 1

      tags = Config.repo().all(from(t in EntryTag, where: t.entry_id == ^entry.id))
      assert "rule" in Enum.map(tags, & &1.tag)

      # the brief now sees it
      assert {:ok, brief} = Recollect.Brief.build(scope_id)
      assert brief.text =~ "Always run the smoke suite after deploy."
    end

    test "negative-valence claims promote into the trap section" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      Fixtures.entry(
        scope_id: scope_id,
        owner_id: owner_id,
        content: "Gotcha: the drain runs before the swap, not after.",
        verification: "user",
        stability: "stable",
        emotional_valence: "negative",
        last_accessed_at: DateTime.utc_now(),
        access_count: 8
      )

      {:ok, metrics} = Dream.Promote.run(scope_id, [])
      assert metrics.promoted == 1

      assert {:ok, brief} = Recollect.Brief.build(scope_id)
      assert brief.text =~ "### Traps"
    end

    test "a never-retrieved, unverified claim is demoted, not deleted" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      entry =
        Fixtures.entry(
          scope_id: scope_id,
          owner_id: owner_id,
          content: "unproven speculation with a rule tag",
          inserted_at: DateTime.add(DateTime.utc_now(), -60 * 86_400, :second)
        )

      {:ok, _} = Staging.stage(scope_id, "irrelevant", owner_id: owner_id)
      {:ok, _} = Recollect.Evidence.link(entry.id, "supports", source_type: "file", source_ref: "/definitely/missing.ex")
      {:ok, _} = Recollect.Knowledge.set_tags(entry.id, ["rule"])

      {:ok, metrics} = Dream.Promote.run(scope_id, [])
      assert metrics.demoted >= 1

      tags = Config.repo().all(from(t in EntryTag, where: t.entry_id == ^entry.id))
      refute "rule" in Enum.map(tags, & &1.tag)

      reloaded = Config.repo().get!(Entry, entry.id)
      assert reloaded.metadata["demoted_at"]
      assert is_nil(reloaded.deleted_at), "demotion never deletes"
    end

    test "a claim demoted beyond the grace period archives" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      entry =
        Fixtures.entry(
          scope_id: scope_id,
          owner_id: owner_id,
          content: "long-stale speculation",
          metadata: %{
            "demoted_at" => DateTime.utc_now() |> DateTime.add(-30 * 86_400, :second) |> DateTime.to_iso8601()
          }
        )

      {:ok, metrics} = Dream.Promote.run(scope_id, demote_grace_days: 14)

      archived = Config.repo().get!(Entry, entry.id)
      assert metrics.archived == 1
      assert archived.entry_type == "archived"
    end

    test "the brief changes after promotion (generation bump)" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      assert {:ok, before} = Recollect.Brief.build(scope_id)
      entry = rule_candidate(scope_id, owner_id, "New promoted rule about caching.")
      {:ok, _} = Dream.Promote.run(scope_id, [])
      assert {:ok, after_promote} = Recollect.Brief.build(scope_id)

      refute before.text =~ "New promoted rule about caching."
      assert after_promote.text =~ "New promoted rule about caching."
      assert after_promote.generation > before.generation or after_promote.text != before.text
      assert entry.id
    end
  end

  describe "Dream.Prune (MEM-026)" do
    test "duplicate events (same owner + hash) are pruned, keeping the earliest" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      hash = Base.encode16(:crypto.hash(:sha256, "same content"), case: :lower)
      now = DateTime.utc_now()

      # MEM-013's unique index prevents hash duplicates entirely — this
      # prune branch targets legacy data that predates it, so the index is
      # dropped for the duration and restored after.
      Config.repo().query!("DROP INDEX IF EXISTS recollect_events_owner_content_hash_idx")

      on_exit(fn ->
        Config.repo().query!(
          "CREATE UNIQUE INDEX IF NOT EXISTS recollect_events_owner_content_hash_idx ON recollect_events (owner_id, content_hash)"
        )
      end)

      Config.repo().insert_all(EventRow, [
        %{
          id: Ecto.UUID.generate(),
          owner_id: owner_id,
          scope_id: scope_id,
          event_type: "message",
          content: "same content",
          occurred_at: now,
          content_hash: hash,
          created_at: DateTime.add(now, -60, :second)
        },
        %{
          id: Ecto.UUID.generate(),
          owner_id: owner_id,
          scope_id: scope_id,
          event_type: "message",
          content: "same content",
          occurred_at: now,
          content_hash: hash,
          created_at: now
        }
      ])

      assert {:ok, metrics} = Dream.Prune.run(scope_id, [])
      assert metrics.duplicate_events_deleted == 1

      remaining =
        Config.repo().all(from(e in EventRow, where: e.scope_id == ^scope_id and e.content_hash == ^hash))

      assert length(remaining) == 1
    end

    test "events past retention without references are pruned; referenced ones survive" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {:ok, old_free} =
        Recollect.Event.record(
          owner_id: owner_id,
          scope_id: scope_id,
          event_type: "message",
          content: "old unreferenced",
          occurred_at: DateTime.add(DateTime.utc_now(), -60 * 86_400, :second)
        )

      entry = Fixtures.entry(scope_id: scope_id, owner_id: owner_id)

      {:ok, old_referenced} =
        Recollect.Event.record(
          owner_id: owner_id,
          scope_id: scope_id,
          event_type: "message",
          content: "old referenced",
          occurred_at: DateTime.add(DateTime.utc_now(), -60 * 86_400, :second)
        )

      {:ok, _} =
        Recollect.Evidence.link(entry.id, "supports",
          event_id: old_referenced.id,
          source_type: "event",
          source_ref: "s:2"
        )

      assert {:ok, metrics} = Dream.Prune.run(scope_id, retention_days: 30)
      assert metrics.events_pruned == 1

      assert is_nil(Config.repo().get(EventRow, old_free.id))
      assert Config.repo().get(EventRow, old_referenced.id)
    end

    test "orphan summaries are tombstoned; derived summaries survive" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      orphan = Fixtures.entry(scope_id: scope_id, owner_id: owner_id, entry_type: "session_summary")

      derived = Fixtures.entry(scope_id: scope_id, owner_id: owner_id, entry_type: "session_summary")

      {:ok, _} =
        Recollect.Evidence.link(derived.id, "derived_from",
          source_type: "file",
          source_ref: "lib/source.ex"
        )

      assert {:ok, metrics} = Dream.Prune.run(scope_id, [])
      assert metrics.orphan_summaries_tombstoned == 1

      assert Config.repo().get!(Entry, orphan.id).deleted_at
      assert is_nil(Config.repo().get!(Entry, derived.id).deleted_at)
    end

    test "expired volatile claims are tombstoned, evidence-backed claims never hard-deleted" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {:ok, event} =
        Recollect.Event.record(owner_id: owner_id, scope_id: scope_id, event_type: "message", content: "x")

      volatile =
        Fixtures.entry(
          scope_id: scope_id,
          owner_id: owner_id,
          content: "volatile expired claim",
          stability: "volatile",
          valid_to: DateTime.add(DateTime.utc_now(), -3600, :second)
        )

      {:ok, _} =
        Recollect.Evidence.link(volatile.id, "supports",
          event_id: event.id,
          source_type: "event",
          source_ref: "s:5"
        )

      assert {:ok, metrics} = Dream.Prune.run(scope_id, [])
      assert metrics.expired_volatile_tombstoned == 1

      reloaded = Config.repo().get!(Entry, volatile.id)
      assert reloaded.deleted_at
      # still there — tombstone, never a hard delete
      assert reloaded.content == "volatile expired claim"
    end

    test "promote + prune run together in one dream" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()
      rule_candidate(scope_id, owner_id, "Combined-pipeline rule.")

      assert {:ok, result} = Dream.run(scope_id, stages: [:promote, :prune])
      assert result.status == "done"
      assert result.stages["promote"]["status"] == "completed"
      assert result.stages["prune"]["status"] == "completed"
      assert result.stages["promote"]["metrics"]["promoted"] == 1
    end
  end
end
