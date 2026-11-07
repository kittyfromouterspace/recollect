defmodule Recollect.Schema.EntryTag do
  @moduledoc """
  A single normalized tag on a knowledge entry.

  Tags are stored trimmed and downcased; the composite primary key
  (entry_id, tag) makes tag assignment naturally idempotent.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  schema "recollect_entry_tags" do
    belongs_to(:entry, Recollect.Schema.Entry, primary_key: true, type: :binary_id)
    field(:tag, :string, primary_key: true)
    field(:scope_id, :binary_id)
    field(:owner_id, :binary_id)
  end

  @doc false
  def changeset(entry_tag, attrs) do
    entry_tag
    |> cast(attrs, [:entry_id, :tag, :scope_id, :owner_id])
    |> validate_required([:entry_id, :tag])
    |> validate_length(:tag, min: 1, max: 64)
    |> foreign_key_constraint(:entry_id)
  end
end
