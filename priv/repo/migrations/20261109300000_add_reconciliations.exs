defmodule Recollect.Repo.Migrations.AddReconciliations do
  @moduledoc false
  use Ecto.Migration

  # MEM-025: dialectic reconciliation records — the contradiction and its
  # resolution (or its unresolved question) persist with provenance.
  # The unique canonical-pair index makes the stage single-flight.
  def change do
    create table(:recollect_reconciliations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:scope_id, :binary_id, null: false)
      add(:thesis_entry_id, references(:recollect_entries, type: :binary_id, on_delete: :delete_all), null: false)
      add(:antithesis_entry_id, references(:recollect_entries, type: :binary_id, on_delete: :delete_all), null: false)
      add(:synthesis_entry_id, references(:recollect_entries, type: :binary_id, on_delete: :nilify_all))
      add(:reasoning, :text)
      add(:unresolved, :boolean, default: true, null: false)
      add(:status, :string, default: "unresolved", null: false)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(index(:recollect_reconciliations, [:scope_id, :status]))

    create(
      unique_index(:recollect_reconciliations, [:scope_id, :thesis_entry_id, :antithesis_entry_id],
        name: :recollect_reconciliations_pair_unique_idx
      )
    )
  end
end
