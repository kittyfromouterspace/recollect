defmodule Recollect.RetrievalCounter do
  @moduledoc """
  GenServer that owns an ETS :counter table for retrieval bumps.

  - bump/1: O(1) :ets.update_counter call
  - Periodic flush: single bulk UPDATE to DB
  - terminate/2: final flush on shutdown

  This replaces the previous pattern of one async UPDATE per search result.
  """

  use GenServer

  alias Recollect.Config

  @table :recollect_retrieval_counters
  @default_flush_interval 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Increment retrieval counter for an entry. O(1) operation."
  def bump(entry_id) do
    # The {pos, incr, threshold, setvalue} tuple form FAILS on a missing key
    # (and the old rescue swallowed it, so every first bump was silently
    # dropped). The 4-arg form inserts the default object when missing.
    :ets.update_counter(@table, entry_id, 1, {entry_id, 0})
  rescue
    _ -> :ok
  end

  @doc "Increment retrieval counters for multiple entries."
  def bump_many(entry_ids) when is_list(entry_ids) do
    for id <- entry_ids, do: bump(id)
  end

  @doc false
  def count(entry_id) do
    case :ets.lookup(@table, entry_id) do
      [{^entry_id, count}] -> count
      [] -> 0
    end
  end

  @doc """
  Flush buffered retrieval counts to the database immediately.

  Useful for maintenance tasks and tests; the GenServer also flushes on its
  configured interval and on shutdown.
  """
  def flush do
    do_flush()
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    interval =
      :recollect
      |> Application.get_env(:retrieval_strengthening, [])
      |> Keyword.get(:flush_interval_ms, @default_flush_interval)

    schedule_flush(interval)
    {:ok, %{flush_interval: interval}}
  end

  @impl true
  def handle_info(:flush, state) do
    do_flush()
    schedule_flush(state.flush_interval)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    do_flush()
  end

  defp do_flush do
    entries = :ets.tab2list(@table)

    if entries != [] do
      now = DateTime.utc_now()

      strengthening = Application.get_env(:recollect, :retrieval_strengthening, [])

      boost_days = Keyword.get(strengthening, :half_life_boost_days, 2)
      max_half_life = Keyword.get(strengthening, :max_half_life_days, 365)

      case apply_counts(entries, boost_days, max_half_life, now) do
        :ok ->
          # Clear only after a successful flush so a failed attempt retries
          # with the counts still buffered.
          :ets.delete_all_objects(@table)

        {:error, reason} ->
          require Logger

          Logger.warning(
            "Recollect.RetrievalCounter: flush failed (#{inspect(reason)}); retaining #{length(entries)} counters"
          )
      end
    end
  end

  # Postgres-first (MEM-007): one bulk UPDATE joining unnest arrays. The
  # previous query ignored the buffered count (+1 per flush) and encoded ids
  # as strings, so the encode error was rescued away and the counters were
  # then cleared — counts were silently lost. SQLite/libSQL parity lands with
  # the backend-parity ticket; until then we fail loudly instead of dropping.
  defp apply_counts(entries, boost_days, max_half_life, now) do
    adapter = Config.adapter()

    if adapter.dialect() == :postgres do
      # Order pairs so ETS clearing and the UPDATE stay consistent.
      pairs =
        entries
        |> Enum.map(fn {id, count} -> {Recollect.Util.uuid_to_bin(id), count} end)
        |> Enum.sort()

      ids = Enum.map(pairs, fn {id, _count} -> id end)
      counts = Enum.map(pairs, fn {_id, count} -> count end)

      case Config.repo().query(
             """
               UPDATE recollect_entries AS e
               SET access_count = e.access_count + v.count,
                   half_life_days = LEAST($4, COALESCE(e.half_life_days, 7.0) + $1 * v.count),
                   last_accessed_at = $2,
                   updated_at = $2
               FROM unnest($3::uuid[], $5::int[]) AS v(id, count)
               WHERE e.id = v.id
             """,
             [boost_days, now, ids, max_half_life, counts]
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unsupported_backend}
    end
  end

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush, interval)
  end
end
