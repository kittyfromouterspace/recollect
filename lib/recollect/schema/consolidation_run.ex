defmodule Recollect.Schema.ConsolidationRun do
  @moduledoc "Recorded consolidation pass for a scope."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "recollect_consolidation_runs" do
    field(:owner_id, :binary_id)
    field(:scope_id, :binary_id)
    field(:timestamp, :utc_datetime_usec)
    field(:decayed, :integer, default: 0)
    field(:removed, :integer, default: 0)
    field(:merged, :integer, default: 0)
    field(:semantic_created, :integer, default: 0)
    field(:conflicts_detected, :integer, default: 0)
    field(:duration_ms, :integer)
  end
end
