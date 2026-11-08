defmodule Recollect.Schema.RecallAnchor do
  @moduledoc """
  A pointer from an anchor (file path, symbol, route, ...) to the entry
  that documents it (MEM-021). Anchors are how an agent touching a file
  gets a cited memory block without searching.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @anchor_types ~w(path symbol module function route table config_key error)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "recollect_recall_anchors" do
    belongs_to(:entry, Recollect.Schema.Entry, type: :binary_id)
    field(:anchor_type, :string)
    field(:anchor_value, :string)
    field(:confidence, :float, default: 0.5)

    field(:created_at, :utc_datetime_usec)
  end

  def changeset(anchor, attrs) do
    anchor
    |> cast(attrs, [:entry_id, :anchor_type, :anchor_value, :confidence, :created_at])
    |> validate_required([:anchor_type, :anchor_value])
    |> validate_inclusion(:anchor_type, @anchor_types)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end

  @doc "Allowed anchor types."
  def anchor_types, do: @anchor_types
end
