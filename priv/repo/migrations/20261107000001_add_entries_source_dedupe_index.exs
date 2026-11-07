defmodule Recollect.Repo.Migrations.AddEntriesSourceDedupeIndex do
  use Ecto.Migration

  # MEM-012: learning/harvest imports ran with no dedupe key, so every run
  # re-inserted every event. The partial unique index makes (source,
  # source_id) idempotent wherever a stable source_id exists; remember/2's
  # :dedupe option decides how a conflict resolves.
  def change do
    create(
      index(:recollect_entries, [:source, :source_id],
        unique: true,
        name: :recollect_entries_source_source_id_unique,
        where: "source_id IS NOT NULL"
      )
    )
  end
end
