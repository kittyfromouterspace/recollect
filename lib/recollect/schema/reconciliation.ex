defmodule Recollect.Schema.Reconciliation do
  @moduledoc """
  The record of a dialectic reconciliation (MEM-025): thesis and antithesis
  claims, the synthesis that resolved them (when one was reachable), the
  reasoning, and whether the question remains open. Persisted even when
  unresolved, so contradictions stay visible.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Recollect.Schema.Entry

  @statuses ~w(reconciled unresolved)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "recollect_reconciliations" do
    field(:scope_id, :binary_id)
    belongs_to(:thesis_entry, Entry, type: :binary_id)
    belongs_to(:antithesis_entry, Entry, type: :binary_id)
    belongs_to(:synthesis_entry, Entry, type: :binary_id)
    field(:reasoning, :string)
    field(:unresolved, :boolean, default: true)
    field(:status, :string, default: "unresolved")

    field(:created_at, :utc_datetime_usec)
  end

  def changeset(reconciliation, attrs) do
    reconciliation
    |> cast(attrs, [
      :scope_id,
      :thesis_entry_id,
      :antithesis_entry_id,
      :synthesis_entry_id,
      :reasoning,
      :unresolved,
      :status,
      :created_at
    ])
    |> validate_required([:scope_id, :thesis_entry_id, :antithesis_entry_id])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:scope_id, :thesis_entry_id, :antithesis_entry_id],
      name: :recollect_reconciliations_pair_unique_idx
    )
  end

  @doc "Allowed reconciliation statuses."
  def statuses, do: @statuses
end
