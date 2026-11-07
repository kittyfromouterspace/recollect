defmodule Recollect.Outcome do
  @moduledoc """
  Outcome feedback for closing the learning loop.

  After recalling memories, the agent can signal whether they were helpful
  (outcome_good) or irrelevant (outcome_bad), which adjusts half-life.
  """

  alias Recollect.Config
  alias Recollect.OutcomeTracker

  @positive_delta 5
  @negative_delta -3

  @doc "Apply positive outcome to the last-retrieved entries for a scope."
  def good(scope_id) do
    entry_ids = OutcomeTracker.get(scope_id)
    apply_outcome(entry_ids, :good)
  end

  @doc "Apply negative outcome to the last-retrieved entries for a scope."
  def bad(scope_id) do
    entry_ids = OutcomeTracker.get(scope_id)
    apply_outcome(entry_ids, :bad)
  end

  @doc "Apply outcome to specific entry IDs."
  def apply(entry_ids, :good) when is_list(entry_ids) do
    apply_outcome(entry_ids, :good)
  end

  def apply(entry_ids, :bad) when is_list(entry_ids) do
    apply_outcome(entry_ids, :bad)
  end

  defp apply_outcome([], _direction), do: {:ok, 0}

  defp apply_outcome(entry_ids, :good) do
    delta =
      :recollect
      |> Application.get_env(:outcome_feedback, [])
      |> Keyword.get(:positive_half_life_delta, @positive_delta)

    do_update(entry_ids, delta, 1)
  end

  defp apply_outcome(entry_ids, :bad) do
    delta =
      -(:recollect
        |> Application.get_env(:outcome_feedback, [])
        |> Keyword.get(:negative_half_life_delta, abs(@negative_delta)))

    do_update(entry_ids, delta, -1)
  end

  defp do_update(entry_ids, delta, score) do
    import Ecto.Query

    repo = Config.repo()
    now = DateTime.utc_now()

    confidence_state =
      if score > 0, do: "verified", else: "active"

    # MEM-011: GREATEST is spelled MAX() on SQLite/libSQL; a CASE floor is
    # identical on both dialects, so no dialect branch is needed. NULL
    # half_life_days falls to the floor, matching GREATEST(1, NULL) on PG.
    # Callers hand over raw binaries from search rows / trackers; :binary_id
    # wants string UUIDs.
    ids = Enum.map(entry_ids, &Recollect.Util.uuid_to_string/1)

    try do
      {count, _} =
        repo.update_all(
          from(e in Recollect.Schema.Entry,
            where: e.id in ^ids,
            update: [
              set: [
                half_life_days:
                  fragment(
                    "CASE WHEN half_life_days + ? > 1 THEN half_life_days + ? ELSE 1 END",
                    ^delta,
                    ^delta
                  ),
                outcome_score: ^score,
                confidence_state: ^confidence_state,
                updated_at: ^now
              ]
            ]
          ),
          []
        )

      {:ok, count}
    rescue
      _ -> {:ok, 0}
    end
  end
end
