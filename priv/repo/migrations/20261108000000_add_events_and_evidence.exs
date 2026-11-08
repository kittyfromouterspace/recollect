defmodule Recollect.Repo.Migrations.AddEventsAndEvidence do
  @moduledoc false
  use Ecto.Migration

  # MEM-013: the event ledger (raw, append-only, not embedded by default)
  # and the link table binding entries (claims) to the events or file
  # references that justify them.
  def change do
    create table(:recollect_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:owner_id, :binary_id, null: false)
      add(:scope_id, :binary_id)
      add(:session_id, :binary_id)
      add(:agent, :string)
      add(:event_type, :string, null: false)
      add(:role, :string)
      add(:content, :text)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:source_uri, :string)
      add(:source_ref, :string)
      add(:parent_event_id, references(:recollect_events, type: :binary_id, on_delete: :nilify_all))
      add(:metadata, :map, default: %{})
      add(:content_hash, :string, null: false)

      # The DDL names it created_at (handoffs/consolidation_runs already use
      # that name); events are append-only, so no updated_at.
      timestamps(inserted_at: :created_at, updated_at: false)
    end

    create(index(:recollect_events, [:owner_id, :occurred_at]))
    create(index(:recollect_events, [:scope_id, :occurred_at]))
    create(index(:recollect_events, [:session_id, :occurred_at]))
    create(unique_index(:recollect_events, [:owner_id, :content_hash], name: :recollect_events_owner_content_hash_idx))

    create table(:recollect_evidence, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:entry_id, references(:recollect_entries, type: :binary_id, on_delete: :delete_all), null: false)
      add(:event_id, references(:recollect_events, type: :binary_id, on_delete: :nilify_all))
      add(:relation, :string, null: false)
      add(:excerpt, :text)
      add(:source_type, :string)
      add(:source_ref, :string)
      add(:weight, :float, default: 1.0, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(index(:recollect_evidence, [:entry_id]))
    create(index(:recollect_evidence, [:event_id]))

    create(
      unique_index(:recollect_evidence, [:entry_id, :relation, :source_type, :source_ref],
        name: :recollect_evidence_unique_idx,
        where: "source_ref IS NOT NULL"
      )
    )
  end
end
