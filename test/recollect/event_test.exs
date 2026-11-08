defmodule Recollect.EventTest do
  use Recollect.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Recollect.Event
  alias Recollect.Schema.Event, as: EventRow

  describe "record/1" do
    test "records an event with a stable 64-char content_hash" do
      owner_id = Fixtures.owner_id()

      {:ok, event} =
        Event.record(
          owner_id: owner_id,
          event_type: "message",
          role: "user",
          content: "The deploy checklist lives in docs/deploy.md"
        )

      assert event.id
      assert event.event_type == "message"
      assert event.role == "user"

      assert event.content_hash ==
               Base.encode16(:crypto.hash(:sha256, "The deploy checklist lives in docs/deploy.md"), case: :lower)

      assert String.length(event.content_hash) == 64
      assert event.content == "The deploy checklist lives in docs/deploy.md"
      assert event.owner_id == owner_id
    end

    test "records the same event twice and returns the existing row (one logical event)" do
      owner_id = Fixtures.owner_id()
      scope_id = Fixtures.scope_id()

      opts = [
        owner_id: owner_id,
        scope_id: scope_id,
        event_type: "tool_call",
        content: "git status",
        source_ref: "session:1:tool:42"
      ]

      {:ok, first} = Event.record(opts)
      {:ok, second} = Event.record(opts)

      assert first.id == second.id
      assert first.content_hash == second.content_hash

      count = Recollect.Config.repo().aggregate(from(e in EventRow, where: e.owner_id == ^owner_id), :count, :id)

      assert count == 1
    end

    test "different content within the same owner produces different rows" do
      owner_id = Fixtures.owner_id()

      {:ok, a} = Event.record(owner_id: owner_id, event_type: "message", content: "alpha")
      {:ok, b} = Event.record(owner_id: owner_id, event_type: "message", content: "beta")

      assert a.id != b.id
    end

    test "source_uri alone is verifiable — no content needed" do
      {:ok, event} =
        Event.record(
          owner_id: Fixtures.owner_id(),
          event_type: "file_change",
          source_uri: "file:///home/lenz/code/recollect/mix.exs",
          content: nil
        )

      assert event.source_uri
      assert event.content_hash
    end

    test "rejects unknown event types" do
      assert {:error, {:invalid_event_type, "nonsense"}} =
               Event.record(owner_id: Fixtures.owner_id(), event_type: "nonsense", content: "x")
    end

    test "rejects events with neither content nor source_uri" do
      assert {:error, :missing_content} =
               Event.record(owner_id: Fixtures.owner_id(), event_type: "message", source_ref: "r:1")
    end

    test "rejects a missing owner" do
      assert {:error, :owner_id_required} = Event.record(event_type: "message", content: "x")
    end
  end

  describe "list/2" do
    test "filters by session, event_type, since/until, limit and order" do
      owner_id = Fixtures.owner_id()
      scope_id = Fixtures.scope_id()
      session_a = Fixtures.scope_id()
      session_b = Fixtures.scope_id()

      hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)
      now = DateTime.utc_now()
      future = DateTime.add(now, 3600, :second)

      {:ok, older} =
        Event.record(
          owner_id: owner_id,
          scope_id: scope_id,
          session_id: session_a,
          event_type: "message",
          content: "older session-a message",
          occurred_at: hour_ago
        )

      {:ok, _newer_a2} =
        Event.record(
          owner_id: owner_id,
          scope_id: scope_id,
          session_id: session_a,
          event_type: "tool_call",
          content: "session-a tool call",
          occurred_at: now
        )

      {:ok, other_scope} =
        Event.record(
          owner_id: owner_id,
          scope_id: session_b,
          event_type: "message",
          content: "session-b message",
          occurred_at: now
        )

      {:ok, future_event} =
        Event.record(
          owner_id: owner_id,
          scope_id: scope_id,
          session_id: session_a,
          event_type: "message",
          content: "just before until",
          occurred_at: future
        )

      assert {:ok, all} = Event.list(scope_id)
      assert length(all) == 3
      assert [newest, _middle, oldest] = all
      assert DateTime.after?(newest.occurred_at, oldest.occurred_at)

      assert {:ok, asc} = Event.list(scope_id, order: :asc)
      assert [first_asc | _] = asc
      assert first_asc.id == oldest.id

      assert {:ok, session_a_msgs} = Event.list(scope_id, session_id: session_a, event_type: "message")
      ids = Enum.map(session_a_msgs, & &1.id)
      assert older.id in ids
      assert future_event.id in ids
      refute other_scope.id in ids

      assert {:ok, since_now} = Event.list(scope_id, since: now)
      assert length(since_now) == 2

      assert {:ok, windowed} = Event.list(scope_id, since: hour_ago, until: now)
      assert length(windowed) == 2

      assert {:ok, [only_one]} = Event.list(scope_id, limit: 1)
      assert only_one.id == newest.id
    end
  end

  describe "prune/1" do
    test "deletes old unreferenced events, keeps fresh and evidence-referenced ones" do
      owner_id = Fixtures.owner_id()
      scope_id = Fixtures.scope_id()
      retro_expiry = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)

      {:ok, stale} =
        Event.record(
          owner_id: owner_id,
          scope_id: scope_id,
          event_type: "message",
          content: "old unlinked message",
          occurred_at: retro_expiry
        )

      {:ok, referenced} =
        Event.record(
          owner_id: owner_id,
          scope_id: scope_id,
          event_type: "test_run",
          content: "old but cited by a claim",
          occurred_at: retro_expiry
        )

      {:ok, fresh} =
        Event.record(
          owner_id: owner_id,
          scope_id: scope_id,
          event_type: "message",
          content: "fresh message"
        )

      entry = Fixtures.entry(owner_id: owner_id, scope_id: scope_id)

      {:ok, _} =
        Recollect.Evidence.link(
          entry.id,
          "supports",
          event_id: referenced.id,
          source_type: "event",
          source_ref: "session:1"
        )

      assert {:ok, %{pruned: 1}} = Event.prune(retention_days: 30)

      repo = Recollect.Config.repo()
      assert is_nil(repo.get(EventRow, stale.id))
      assert repo.get(EventRow, referenced.id)
      assert repo.get(EventRow, fresh.id)
    end
  end
end
