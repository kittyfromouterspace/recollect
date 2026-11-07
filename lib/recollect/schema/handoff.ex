defmodule Recollect.Schema.Handoff do
  @moduledoc """
  Session handoff row. The list fields (`next`, `artifacts`, `blockers`) are
  JSON-encoded text columns — kept as strings at the schema level to preserve
  the on-disk contract; `Recollect.Handoff` does the encode/decode.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "recollect_handoffs" do
    field(:scope_id, :binary_id)
    field(:session_id, :binary_id)
    field(:what, :string)
    field(:next, :string)
    field(:artifacts, :string)
    field(:blockers, :string)

    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end
end
