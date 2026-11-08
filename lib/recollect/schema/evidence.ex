defmodule Recollect.Schema.Evidence do
  @moduledoc """
  Binds an entry (a claim, L1) to the event or file reference (L0) that
  justifies it. `Recollect.Evidence.for_entry/1` walks these rows to answer
  "why is this here?" — a claim without evidence is unverifiable.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @relations ~w(supports contradicts derived_from supersedes)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "recollect_evidence" do
    belongs_to(:entry, Recollect.Schema.Entry, type: :binary_id)
    belongs_to(:event, Recollect.Schema.Event, type: :binary_id)
    field(:relation, :string)
    field(:excerpt, :string)
    field(:source_type, :string)
    field(:source_ref, :string)
    field(:weight, :float, default: 1.0)

    field(:created_at, :utc_datetime_usec)
  end

  @doc false
  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [
      :entry_id,
      :event_id,
      :relation,
      :excerpt,
      :source_type,
      :source_ref,
      :weight,
      :created_at
    ])
    |> validate_required([:entry_id, :relation])
    |> validate_inclusion(:relation, @relations)
    |> validate_number(:weight, greater_than_or_equal_to: 0.0)
    |> validate_length(:source_type, max: 32)
  end

  @doc "Allowed evidence relations."
  def relations, do: @relations
end
