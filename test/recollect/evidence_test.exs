defmodule Recollect.EvidenceTest do
  use Recollect.DataCase, async: false

  alias Recollect.Evidence

  describe "link/3" do
    test "links an entry to an event and for_entry/1 returns it with the event preloaded" do
      owner_id = Fixtures.owner_id()
      entry = Fixtures.entry(owner_id: owner_id)

      {:ok, event} =
        Recollect.Event.record(
          owner_id: owner_id,
          event_type: "message",
          content: "the flaky test is test_payment_retry, seen failing on CI"
        )

      {:ok, evidence} =
        Evidence.link(
          entry.id,
          "supports",
          event_id: event.id,
          source_type: "event",
          source_ref: "session:1:msg:7",
          excerpt: "test_payment_retry fails on CI"
        )

      assert evidence.entry_id == entry.id
      assert evidence.event_id == event.id
      assert evidence.relation == "supports"
      assert evidence.source_type == "event"

      assert {:ok, [row]} = Evidence.for_entry(entry.id)
      assert row.id == evidence.id
      assert row.event.id == event.id
      assert row.event.content =~ "test_payment_retry"
    end

    test "relinking the same evidence is idempotent (dedupe tuple)" do
      owner_id = Fixtures.owner_id()
      entry = Fixtures.entry(owner_id: owner_id)

      {:ok, event} =
        Recollect.Event.record(owner_id: owner_id, event_type: "commit", content: "abc123 fix flake")

      {:ok, first} =
        Evidence.link(entry.id, "supports",
          event_id: event.id,
          source_type: "event",
          source_ref: "session:1:msg:7"
        )

      {:ok, second} =
        Evidence.link(entry.id, "supports",
          event_id: event.id,
          source_type: "event",
          source_ref: "session:1:msg:7"
        )

      assert first.id == second.id
      assert {:ok, rows} = Evidence.for_entry(entry.id)
      assert length(rows) == 1
    end

    test "same ref with a different relation produces a separate row" do
      owner_id = Fixtures.owner_id()
      entry = Fixtures.entry(owner_id: owner_id)

      {:ok, _first} =
        Evidence.link(entry.id, "derived_from",
          source_type: "file",
          source_ref: "lib/recollect/event.ex"
        )

      {:ok, _second} =
        Evidence.link(entry.id, "supports",
          source_type: "file",
          source_ref: "lib/recollect/event.ex"
        )

      assert {:ok, rows} = Evidence.for_entry(entry.id)
      assert length(rows) == 2
    end

    test "rejects an invalid relation" do
      entry = Fixtures.entry()

      assert {:error, {:invalid_relation, "hates"}} = Evidence.link(entry.id, "hates")
    end

    test "rejects unknown entries and unknown events" do
      entry = Fixtures.entry()

      assert {:error, :entry_not_found} =
               Evidence.link(Ecto.UUID.generate(), "supports", source_ref: "x")

      assert {:error, :event_not_found} =
               Evidence.link(entry.id, "supports", event_id: Ecto.UUID.generate(), source_ref: "x")
    end

    test "deleting the event nullifies the evidence link but keeps the claim" do
      owner_id = Fixtures.owner_id()
      entry = Fixtures.entry(owner_id: owner_id)

      {:ok, event} =
        Recollect.Event.record(owner_id: owner_id, event_type: "message", content: "transient source")

      {:ok, _} =
        Evidence.link(entry.id, "supports",
          event_id: event.id,
          source_type: "event",
          source_ref: "session:1:msg:9"
        )

      Recollect.Config.repo().delete!(event)

      assert {:ok, [row]} = Evidence.for_entry(entry.id)
      assert is_nil(row.event_id)
      assert is_nil(row.event)
      assert row.entry_id == entry.id
    end
  end
end
