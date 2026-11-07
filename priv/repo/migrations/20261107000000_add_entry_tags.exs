defmodule Recollect.Repo.Migrations.AddEntryTags do
  use Ecto.Migration

  # MEM-005: normalized tags for knowledge entries. Tags were accepted by
  # remember/2 and silently dropped for the library's entire life; this table
  # makes them real. Composite primary key (entry_id, tag); scope_id is
  # denormalized onto each row so scope-scoped tag queries (SchemaIndex,
  # search filters, review) never need to join back to entries.
  def change do
    create table(:recollect_entry_tags, primary_key: false) do
      add(:entry_id, references(:recollect_entries, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:tag, :string, primary_key: true)
      add(:scope_id, :binary_id)
      add(:owner_id, :binary_id)
    end

    create(index(:recollect_entry_tags, [:scope_id, :tag]))
    create(index(:recollect_entry_tags, [:tag]))
  end
end
