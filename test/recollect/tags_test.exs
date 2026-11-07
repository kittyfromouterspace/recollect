defmodule Recollect.TagsTest do
  use Recollect.DataCase, async: false

  import Ecto.Query

  alias Mix.Tasks.Recollect.BackfillTags
  alias Recollect.Knowledge
  alias Recollect.MigrationGenerator
  alias Recollect.Schema.EntryTag
  alias Recollect.Search.Vector

  defp remember(content, opts) do
    {:ok, entry} =
      Recollect.remember(
        content,
        Keyword.merge([owner_id: Fixtures.owner_id(), scope_id: Fixtures.scope_id()], opts)
      )

    entry
  end

  describe "remember/2 with :tags (MEM-005)" do
    test "stores normalized tags and returns them on the entry" do
      entry =
        remember("Billing retries are capped at 60s.",
          tags: ["Billing", " billing ", "", "RETRY"]
        )

      assert entry.tags == ["billing", "retry"]
      assert Knowledge.tags(entry.id) == ["billing", "retry"]
    end

    test "remember without tags stores none" do
      entry = remember("plain note", [])
      assert entry.tags == []
      assert Knowledge.tags(entry.id) == []
    end

    test "tags survive a nil scope_id" do
      {:ok, entry} = Recollect.remember("scopeless but tagged", tags: ["global"])

      assert Knowledge.tags(entry.id) == ["global"]
    end

    test "tags are capped and length-bounded" do
      long = String.duplicate("x", 100)
      many = for i <- 1..25, do: "tag#{i}"

      entry = remember("over-tagged", tags: [long | many])
      tags = Knowledge.tags(entry.id)

      assert length(tags) == 20
      assert Enum.all?(tags, &(String.length(&1) <= 64))
    end

    test "validation failure returns {:error, changeset} and stores nothing" do
      assert {:error, %Ecto.Changeset{}} =
               Recollect.remember(nil,
                 owner_id: Fixtures.owner_id(),
                 scope_id: Fixtures.scope_id(),
                 tags: ["billing"]
               )
    end
  end

  describe "set_tags/2" do
    test "replaces the tag set atomically" do
      entry = remember("tag me", tags: ["old"])

      assert {:ok, ["new", "tags"]} = Knowledge.set_tags(entry.id, ["New", "TAGS"])
      assert Knowledge.tags(entry.id) == ["new", "tags"]
    end

    test "set_tags to [] clears the entry's tags" do
      entry = remember("clear me", tags: ["gone"])
      assert {:ok, []} = Knowledge.set_tags(entry.id, [])
      assert Knowledge.tags(entry.id) == []
    end
  end

  describe "cascade" do
    test "deleting an entry deletes its tags" do
      entry = remember("delete me", tags: ["ephemeral"])
      entry_id = entry.id

      assert {:ok, _} = Knowledge.forget(entry_id)

      assert Config.repo().all(from(t in EntryTag, where: t.entry_id == ^entry_id)) == []
    end
  end

  describe "search filters" do
    defp embedded_entry(content, opts) do
      {:ok, embedding} = Recollect.Embedding.Mock.embed(content, [])

      entry = Fixtures.entry(Keyword.merge([content: content, embedding: embedding], opts))

      if tags = opts[:tags] do
        {:ok, _} = Knowledge.set_tags(entry.id, tags)
      end

      entry
    end

    test "tags: filter returns only entries carrying ALL tags" do
      scope_id = Fixtures.scope_id()

      billing =
        embedded_entry("Billing retries use exponential backoff.",
          scope_id: scope_id,
          tags: ["billing", "ops"]
        )

      embedded_entry("Billing UI uses a table.",
        scope_id: scope_id,
        tags: ["billing"]
      )

      embedded_entry("Kubernetes drains nodes.", scope_id: scope_id, tags: ["k8s"])

      {:ok, results} =
        Vector.search_entries("billing", scope_id,
          min_score: -1.0,
          filters: %{tags: ["billing", "ops"]}
        )

      ids = Enum.map(results, & &1["id"])
      assert ids != []
      assert Enum.all?(ids, fn id -> Ecto.UUID.load!(id) == billing.id end)
    end

    test "tags_any: filter returns the union of matching entries" do
      scope_id = Fixtures.scope_id()

      a = embedded_entry("Note A about billing.", scope_id: scope_id, tags: ["billing"])
      b = embedded_entry("Note B about kubernetes.", scope_id: scope_id, tags: ["k8s"])
      _c = embedded_entry("Note C about gardening.", scope_id: scope_id, tags: ["plants"])

      {:ok, results} =
        Vector.search_entries("notes", scope_id,
          min_score: -1.0,
          filters: %{tags_any: ["billing", "k8s"]}
        )

      ids = Enum.map(results, &Ecto.UUID.load!(&1["id"]))
      assert a.id in ids
      assert b.id in ids
      assert length(ids) == 2
    end

    test "tags combine with entry_type filter (placeholder arithmetic)" do
      scope_id = Fixtures.scope_id()

      embedded_entry("A decision about billing alerts.",
        scope_id: scope_id,
        entry_type: "decision",
        tags: ["billing"]
      )

      embedded_entry("A billing observation.",
        scope_id: scope_id,
        entry_type: "observation",
        tags: ["billing"]
      )

      {:ok, results} =
        Vector.search_entries("billing", scope_id,
          min_score: -1.0,
          filters: %{tags: ["billing"], entry_type: "decision"}
        )

      assert length(results) == 1
      assert hd(results)["entry_type"] == "decision"
    end

    test "tag filters respect scope isolation" do
      scope_id = Fixtures.scope_id()
      other_scope = Fixtures.scope_id()

      embedded_entry("Scoped billing note.", scope_id: scope_id, tags: ["billing"])
      embedded_entry("Other-scope billing note.", scope_id: other_scope, tags: ["billing"])

      {:ok, results} =
        Vector.search_entries("billing", scope_id,
          min_score: -1.0,
          filters: %{tags: ["billing"]}
        )

      assert length(results) == 1
    end
  end

  describe "conflict detection tag gate (MEM-005 follow-through)" do
    test "tag overlap feeds the conflict score" do
      a = Fixtures.entry(content: "Deploys are enabled for everyone on Fridays.")
      {:ok, _} = Knowledge.set_tags(a.id, ["deploys", "friday"])

      b =
        Fixtures.entry(
          content: "Deploys are disabled for everyone on Fridays.",
          scope_id: a.scope_id,
          owner_id: a.owner_id
        )

      {:ok, _} = Knowledge.set_tags(b.id, ["deploys", "friday"])

      conflicts = Recollect.ConflictDetection.detect(a.scope_id)
      assert [%{reason: "enabled/disabled mismatch"}] = conflicts
    end
  end

  describe "migration generator" do
    test "generated up migration contains the entry_tags table and indexes" do
      sql = MigrationGenerator.generate_up()

      assert sql =~ "create table(:recollect_entry_tags"
      assert sql =~ "create index(:recollect_entry_tags, [:scope_id, :tag])"
      assert MigrationGenerator.generate_down() =~ "drop table(:recollect_entry_tags)"
    end
  end

  describe "backfill task" do
    test "copies metadata[\"tags\"] into recollect_entry_tags, idempotently" do
      entry = Fixtures.entry(content: "legacy", metadata: %{"tags" => ["Legacy", " billing "]})

      BackfillTags.run(["--batch", "10"])
      assert Knowledge.tags(entry.id) == ["billing", "legacy"]

      # idempotent
      BackfillTags.run(["--batch", "10"])
      assert Knowledge.tags(entry.id) == ["billing", "legacy"]
    end
  end
end
