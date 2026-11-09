defmodule Recollect.Repo.Migrations.AddLexicalIndexes do
  use Ecto.Migration

  # MEM-031: lexical search indexes for exact keyword/symbol matching.
  #
  # PostgreSQL: adds a generated tsvector column on content + summary,
  # plus a GIN index for fast full-text search.
  # SQLite/libSQL: creates an FTS5 virtual table keyed by entry_id.
  def up do
    if Code.ensure_loaded?(Pgvector) do
      execute("ALTER TABLE recollect_entries ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english', coalesce(content, '') || ' ' || coalesce(summary, ''))) STORED")
      execute("CREATE INDEX recollect_entries_search_idx ON recollect_entries USING GIN (search_vector)")
    else
      create table(:recollect_entries_fts) do
        add(:entry_id, :binary_id, null: false)
        add(:content, :text)
        add(:summary, :text)
      end

      create index(:recollect_entries_fts_entry_id_idx, on: :entry_id, unique: true)
    end
  end

  def down do
    if Code.ensure_loaded?(Pgvector) do
      execute("DROP INDEX IF EXISTS recollect_entries_search_idx")
      execute("ALTER TABLE recollect_entries DROP COLUMN IF EXISTS search_vector")
    else
      drop table(:recollect_entries_fts)
    end
  end
end
