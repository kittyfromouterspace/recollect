defmodule Recollect.Repo.Migrations.AddRecallAnchors do
  @moduledoc false
  use Ecto.Migration

  # MEM-021: path/symbol anchor index for just-in-time recall. The §5.2
  # DDL also carries a page_id FK to recollect_pages — that table ships
  # with MEM-027, so the column joins there.
  def change do
    create table(:recollect_recall_anchors, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:entry_id, references(:recollect_entries, type: :binary_id, on_delete: :delete_all))
      add(:anchor_type, :string, null: false)
      add(:anchor_value, :string, null: false)
      add(:confidence, :float, default: 0.5, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(index(:recollect_recall_anchors, [:anchor_type, :anchor_value], name: :recollect_recall_anchors_lookup_idx))

    create(index(:recollect_recall_anchors, [:entry_id]))

    create(
      unique_index(:recollect_recall_anchors, [:entry_id, :anchor_type, :anchor_value],
        name: :recollect_recall_anchors_unique_idx
      )
    )
  end
end
