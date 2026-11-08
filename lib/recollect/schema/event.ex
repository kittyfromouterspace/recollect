defmodule Recollect.Schema.Event do
  @moduledoc """
  A raw event in the ledger (L0). Append-only, NOT embedded by default —
  events are the verifiable substrate; `Recollect.Schema.Entry` (L1) claims
  are what search reads.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @event_types ~w(message tool_call tool_result file_change test_run commit state custom)
  @roles ~w(user assistant tool system)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "recollect_events" do
    field(:owner_id, :binary_id)
    field(:scope_id, :binary_id)
    field(:session_id, :binary_id)
    field(:agent, :string)
    field(:event_type, :string)
    field(:role, :string)
    field(:content, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:source_uri, :string)
    field(:source_ref, :string)
    field(:parent_event_id, :binary_id)
    field(:metadata, :map, default: %{})
    field(:content_hash, :string)

    field(:created_at, :utc_datetime_usec)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :id,
      :owner_id,
      :scope_id,
      :session_id,
      :agent,
      :event_type,
      :role,
      :content,
      :occurred_at,
      :source_uri,
      :source_ref,
      :parent_event_id,
      :metadata,
      :content_hash,
      :created_at
    ])
    |> validate_required([:owner_id, :event_type, :occurred_at, :content_hash])
    |> validate_inclusion(:event_type, @event_types)
    |> validate_inclusion(:role, @roles)
    |> validate_length(:content_hash, is: 64)
  end

  @doc "Allowed event types."
  def event_types, do: @event_types
end
