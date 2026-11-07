defmodule Recollect.Confidence do
  @moduledoc """
  Confidence lifecycle management.

  Memories that haven't been retrieved in 30+ days are automatically
  marked "stale". If they're recalled again, they wake back up to
  "observed" so they can earn trust again.
  """

  alias Recollect.Config
  alias Recollect.Schema.Entry

  @stale_threshold_days 30

  @doc """
  Resolve the effective confidence state for an entry.
  Computed on-read, no DB write.
  """
  def resolve_state(%{confidence_state: "verified"}), do: "verified"

  def resolve_state(%{confidence_state: "stale"} = entry) do
    if recently_retrieved?(entry), do: "observed", else: "stale"
  end

  def resolve_state(entry) do
    if days_since_last_access(entry) > @stale_threshold_days do
      "stale"
    else
      entry.confidence_state || "active"
    end
  end

  @doc """
  Wake up stale entries when retrieved.
  Returns {:ok, count} of entries woken up.
  """
  def wake_up_stale_entries(entry_ids) when is_list(entry_ids) do
    if entry_ids == [] do
      {:ok, 0}
    else
      import Ecto.Query

      # Callers hand over raw binaries from search rows; :binary_id wants
      # string UUIDs.
      ids = Enum.map(entry_ids, &Recollect.Util.uuid_to_string/1)

      {count, _} =
        Config.repo().update_all(
          from(e in Entry,
            where: e.id in ^ids and e.confidence_state == "stale"
          ),
          set: [confidence_state: "observed", updated_at: DateTime.utc_now()]
        )

      {:ok, count}
    end
  end

  @doc """
  Mark an entry as verified (e.g., after positive outcome feedback).
  """
  def verify(entry_id) do
    import Ecto.Query

    {count, _} =
      Config.repo().update_all(
        from(e in Entry, where: e.id == ^entry_id),
        set: [confidence_state: "verified", updated_at: DateTime.utc_now()]
      )

    {:ok, count}
  end

  defp days_since_last_access(%{last_accessed_at: nil, inserted_at: inserted_at}) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :day)
  end

  defp days_since_last_access(%{last_accessed_at: at}) do
    DateTime.diff(DateTime.utc_now(), at, :day)
  end

  defp recently_retrieved?(entry) do
    days_since_last_access(entry) < @stale_threshold_days
  end
end
