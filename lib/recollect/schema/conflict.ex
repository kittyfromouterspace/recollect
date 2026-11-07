defmodule Recollect.Schema.Conflict do
  @moduledoc "A detected contradiction between two entries."
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "recollect_conflicts" do
    field(:owner_id, :binary_id)
    field(:scope_id, :binary_id)
    field(:entry_a_id, :binary_id)
    field(:entry_b_id, :binary_id)
    field(:reason, :string)
    field(:score, :float)
    field(:status, :string, default: "open")
    field(:resolved_by, :binary_id)
    field(:detected_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @doc false
  def changeset(conflict, attrs) do
    conflict
    |> cast(attrs, [
      :owner_id,
      :scope_id,
      :entry_a_id,
      :entry_b_id,
      :reason,
      :score,
      :status,
      :resolved_by,
      :detected_at,
      :updated_at
    ])
    |> validate_required([:owner_id, :scope_id, :entry_a_id, :entry_b_id, :reason, :score])
  end
end
