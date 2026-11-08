defmodule Recollect.Repo.Migrations.AddStaging do
  @moduledoc false
  use Ecto.Migration

  # MEM-040: durable staging tier between ephemeral working memory and the
  # entry store — the engine-level replacement for ops_center's and
  # AgentForge's bespoke `*_memory_staging` tables.
  def change do
    create table(:recollect_staging, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:owner_id, :binary_id, null: false)
      add(:scope_id, :binary_id, null: false)
      add(:content, :text, null: false)
      add(:metadata, :map, default: %{})
      add(:source, :string)
      add(:priority, :float, default: 0.5, null: false)
      add(:status, :string, default: "staged", null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:drained_at, :utc_datetime_usec)
    end

    create(index(:recollect_staging, [:scope_id, :status, :inserted_at], name: :recollect_staging_scope_idx))

    create(index(:recollect_staging, [:status, :drained_at], name: :recollect_staging_retention_idx))
  end
end
