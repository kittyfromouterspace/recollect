defmodule Recollect.Schema.PageSource do
  @moduledoc """
  A citation from a page to the entry/event/file behind it (MEM-027).
  A page without sources is rejected at creation — every statement in the
  representation layer traces back.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @source_types ~w(entry event url file)
  @roles ~w(primary supporting contradicting)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "recollect_page_sources" do
    belongs_to(:page, Recollect.Schema.Page, type: :binary_id)
    belongs_to(:entry, Recollect.Schema.Entry, type: :binary_id)
    belongs_to(:event, Recollect.Schema.Event, type: :binary_id)
    field(:source_type, :string)
    field(:source_ref, :string)
    field(:role, :string, default: "supporting")

    field(:created_at, :utc_datetime_usec)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:page_id, :entry_id, :event_id, :source_type, :source_ref, :role, :created_at])
    |> validate_required([:page_id, :source_type])
    |> validate_inclusion(:source_type, @source_types)
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:page_id, :source_type, :source_ref],
      name: :recollect_page_sources_unique_idx
    )
  end

  @doc "Allowed source types."
  def source_types, do: @source_types

  @doc "Allowed citation roles."
  def roles, do: @roles
end
