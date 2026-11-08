defmodule Recollect.Schema.DreamRun do
  @moduledoc """
  One dream attempt (MEM-023). `stages` tracks per-stage completion so a
  failed run can resume; the partial unique index on `(scope_id,
  input_hash) WHERE status = 'done'` makes a successful rerun a no-op
  while never blocking retries of failed or aborted runs.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(pending running done failed aborted)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "recollect_dream_runs" do
    field(:owner_id, :binary_id)
    field(:scope_id, :binary_id)
    field(:input_hash, :string)
    field(:status, :string, default: "pending")
    field(:stages, :map, default: %{})
    field(:metrics, :map, default: %{})
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:error, :string)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :owner_id,
      :scope_id,
      :input_hash,
      :status,
      :stages,
      :metrics,
      :started_at,
      :finished_at,
      :error
    ])
    |> validate_required([:scope_id, :input_hash, :status])
    |> validate_inclusion(:status, @statuses)
  end

  @doc "Allowed dream-run statuses."
  def statuses, do: @statuses
end
