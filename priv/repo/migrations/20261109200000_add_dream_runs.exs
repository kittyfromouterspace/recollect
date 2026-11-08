defmodule Recollect.Repo.Migrations.AddDreamRuns do
  @moduledoc false
  use Ecto.Migration

  # MEM-023: one row per dream attempt. The idempotency index is PARTIAL
  # (WHERE status = 'done') so failed and aborted runs never block a retry.
  def change do
    create table(:recollect_dream_runs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:owner_id, :binary_id)
      add(:scope_id, :binary_id, null: false)
      add(:input_hash, :string, null: false)
      add(:status, :string, default: "pending", null: false)
      add(:stages, :map, default: %{})
      add(:metrics, :map, default: %{})
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      add(:error, :text)
    end

    create(index(:recollect_dream_runs, [:scope_id, :status]))

    create(
      unique_index(:recollect_dream_runs, [:scope_id, :input_hash],
        name: :recollect_dream_runs_done_unique_idx,
        where: "status = 'done'"
      )
    )
  end
end
