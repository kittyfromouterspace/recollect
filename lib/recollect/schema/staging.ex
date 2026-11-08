defmodule Recollect.Schema.Staging do
  @moduledoc """
  A durable staged candidate note (MEM-040) — the persistent tier between
  ephemeral working memory and the entry store. `status` moves `staged` →
  `drained` when a distiller claims the row; failures restage.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(staged drained)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "recollect_staging" do
    field(:owner_id, :binary_id)
    field(:scope_id, :binary_id)
    field(:content, :string)
    field(:metadata, :map, default: %{})
    field(:source, :string)
    field(:priority, :float, default: 0.5)
    field(:status, :string, default: "staged")
    field(:drained_at, :utc_datetime_usec)

    field(:inserted_at, :utc_datetime_usec)
  end

  def changeset(staging, attrs) do
    staging
    |> cast(attrs, [
      :owner_id,
      :scope_id,
      :content,
      :metadata,
      :source,
      :priority,
      :status,
      :drained_at,
      :inserted_at
    ])
    |> validate_required([:owner_id, :scope_id, :content])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:priority, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end

  @doc "Allowed staging statuses."
  def statuses, do: @statuses
end
