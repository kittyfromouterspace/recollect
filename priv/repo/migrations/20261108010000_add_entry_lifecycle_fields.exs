defmodule Recollect.Repo.Migrations.AddEntryLifecycleFields do
  @moduledoc false
  use Ecto.Migration

  # MEM-014: lifecycle fields on recollect_entries (§5.2). Defaults are safe
  # for existing rows (Postgres fast defaults; SQLite stores the default on
  # the column). The live partial index powers search/recent excluding
  # soft-deleted and archived rows.
  def change do
    alter table(:recollect_entries) do
      add(:memory_level, :string, default: "workspace", null: false)
      add(:stability, :string, default: "evolving", null: false)
      add(:epistemic, :string, default: "inferred", null: false)
      add(:valid_from, :utc_datetime_usec)
      add(:valid_to, :utc_datetime_usec)
      add(:verified_at, :utc_datetime_usec)
      add(:verification, :string, default: "none", null: false)
      add(:version, :integer, default: 1, null: false)
      add(:deleted_at, :utc_datetime_usec)
    end

    create(index(:recollect_entries, [:scope_id, :memory_level, :stability]))

    create(
      index(:recollect_entries, [:scope_id, :inserted_at],
        name: :recollect_entries_live_idx,
        where: "deleted_at IS NULL AND entry_type != 'archived'"
      )
    )
  end
end
