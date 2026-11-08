defmodule Recollect.Schema.Page do
  @moduledoc """
  A cited wiki page (L4, MEM-027): cross-document synthesis with a slug,
  a source hash for incremental updates, a token count, and sources
  (`Recollect.Schema.PageSource`) that cite the entries/events behind it.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @kinds ~w(topic project person runbook index)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "recollect_pages" do
    field(:owner_id, :binary_id)
    field(:scope_id, :binary_id)
    field(:slug, :string)
    field(:title, :string)
    field(:kind, :string, default: "topic")
    field(:body_md, :string)
    field(:summary, :string)
    field(:token_count, :integer)
    field(:version, :integer, default: 1)
    field(:source_hash, :string)

    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)

    has_many(:sources, Recollect.Schema.PageSource, on_delete: :delete_all)
  end

  def changeset(page, attrs) do
    page
    |> cast(attrs, [
      :owner_id,
      :scope_id,
      :slug,
      :title,
      :kind,
      :body_md,
      :summary,
      :token_count,
      :version,
      :source_hash,
      :created_at,
      :updated_at
    ])
    |> validate_required([:owner_id, :slug, :title, :body_md, :token_count, :source_hash])
    |> update_change(:slug, &String.trim/1)
    |> validate_format(:slug, ~r/^[a-z0-9\-\/]+$/, message: "only lowercase letters, digits, dashes and slashes")
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:token_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:scope_id, :slug], name: :recollect_pages_scope_slug_idx)
  end

  @doc "Allowed page kinds."
  def kinds, do: @kinds
end
