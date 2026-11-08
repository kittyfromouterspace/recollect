defmodule Recollect.KnowledgeTest do
  use Recollect.DataCase, async: false

  alias Recollect.Schema.Entry

  describe "remember/2" do
    test "stores an entry with content" do
      owner_id = Fixtures.owner_id()
      scope_id = Fixtures.scope_id()

      {:ok, entry} =
        Recollect.remember("Deploy scripts are in /app/scripts",
          owner_id: owner_id,
          scope_id: scope_id,
          entry_type: "observation"
        )

      assert entry.content == "Deploy scripts are in /app/scripts"
      assert entry.entry_type == "observation"
      assert entry.owner_id == owner_id
      assert entry.scope_id == scope_id
    end

    test "returns error for missing content" do
      result = Recollect.remember("")
      assert {:error, _} = result
    end

    test "accepts optional fields" do
      owner_id = Fixtures.owner_id()
      scope_id = Fixtures.scope_id()

      {:ok, entry} =
        Recollect.remember("Important note",
          owner_id: owner_id,
          scope_id: scope_id,
          entry_type: "decision",
          summary: "Key decision",
          source: "agent",
          confidence: 0.9
        )

      assert entry.entry_type == "decision"
      assert entry.summary == "Key decision"
      assert entry.source == "agent"
      assert entry.confidence == 0.9
    end
  end

  describe "forget/1" do
    test "soft-deletes an existing entry (row kept, tombstone set)" do
      entry = Fixtures.entry()

      result = Recollect.forget(entry.id)
      assert {:ok, softened} = result
      assert softened.deleted_at

      # MEM-014: the row stays for audit/undo...
      assert Config.repo().get(Entry, entry.id)
    end

    test "hard: true removes the row" do
      entry = Fixtures.entry()
      assert {:ok, _} = Recollect.forget(entry.id, hard: true)

      assert Config.repo().get(Entry, entry.id) == nil
    end

    test "returns error for non-existent entry" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Recollect.forget(fake_id)
    end
  end

  describe "connect/4" do
    test "creates an edge between two entries" do
      entry1 = Fixtures.entry()
      entry2 = Fixtures.entry()

      {:ok, edge} = Recollect.connect(entry1.id, entry2.id, "supports", weight: 0.8)

      assert edge.source_entry_id == entry1.id
      assert edge.target_entry_id == entry2.id
      assert edge.relation == "supports"
      assert edge.weight == 0.8
    end

    test "accepts different relation types" do
      entry1 = Fixtures.entry()

      for rel <- ~w(leads_to supports contradicts derived_from supersedes related_to) do
        entry2 = Fixtures.entry()

        {:ok, edge} = Recollect.connect(entry1.id, entry2.id, rel)

        assert edge.relation == rel
      end
    end
  end

  describe "recent/2" do
    test "returns recent entries for a scope" do
      scope_id = Fixtures.scope_id()

      for i <- 1..5 do
        Fixtures.entry(scope_id: scope_id, content: "Entry #{i}")
      end

      entries = Recollect.Knowledge.recent(scope_id)
      assert length(entries) == 5
    end

    test "excludes archived entries" do
      scope_id = Fixtures.scope_id()

      Fixtures.entry(scope_id: scope_id, content: "Active entry", entry_type: "note")
      Fixtures.entry(scope_id: scope_id, content: "Archived entry", entry_type: "archived")

      entries = Recollect.Knowledge.recent(scope_id)
      assert length(entries) == 1
      assert hd(entries).content == "Active entry"
    end

    test "respects limit option" do
      scope_id = Fixtures.scope_id()

      for i <- 1..10 do
        Fixtures.entry(scope_id: scope_id, content: "Entry #{i}")
      end

      entries = Recollect.Knowledge.recent(scope_id, limit: 3)
      assert length(entries) == 3
    end
  end

  describe "supersede/4" do
    test "demotes entries matching the pattern" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      Fixtures.entry(
        scope_id: scope_id,
        owner_id: owner_id,
        content: "The deploy script is at /app/scripts/deploy.sh",
        confidence: 1.0
      )

      Fixtures.entry(
        scope_id: scope_id,
        owner_id: owner_id,
        content: "Another deploy note",
        confidence: 1.0
      )

      Recollect.Knowledge.supersede(scope_id, "deploy", "deploy", "new value")

      entries = Recollect.Knowledge.recent(scope_id)
      demoted = Enum.filter(entries, &(&1.confidence < 1.0))
      assert length(demoted) == 1
    end
  end
end
