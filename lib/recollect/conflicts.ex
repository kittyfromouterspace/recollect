defmodule Recollect.Conflicts do
  @moduledoc """
  Conflict management for contradictory memories.

  List open conflicts, resolve them by keeping one entry and weakening
  the other, or delete the losing entry entirely.
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Schema.Conflict
  alias Recollect.Schema.Entry

  @doc "List open conflicts for a scope, highest score first."
  def list(scope_id) do
    {:ok,
     Config.repo().all(
       from(c in Conflict,
         where: c.scope_id == ^scope_id and c.status == "open",
         order_by: [desc: c.score]
       )
     )}
  end

  @doc "Get a single conflict by ID."
  def get(conflict_id) do
    case Config.repo().get(Conflict, conflict_id) do
      nil -> {:error, :not_found}
      conflict -> {:ok, conflict}
    end
  end

  @doc """
  Resolve a conflict by keeping one entry and weakening the other.
  The loser's half-life is halved.
  """
  def resolve(conflict_id, keep_entry_id) do
    with_pair(conflict_id, keep_entry_id, fn repo, conflict, loser_id ->
      repo.transaction(fn ->
        mark_resolved(repo, conflict.id, keep_entry_id)
        halve_half_life(repo, loser_id)
      end)

      {:ok, %{conflict_id: conflict_id, loser_id: loser_id, kept_id: keep_entry_id}}
    end)
  end

  @doc "Resolve a conflict by deleting the losing entry."
  def resolve_and_forget(conflict_id, keep_entry_id) do
    with_pair(conflict_id, keep_entry_id, fn repo, conflict, loser_id ->
      repo.transaction(fn ->
        mark_resolved(repo, conflict.id, keep_entry_id)
        repo.delete_all(from(e in Entry, where: e.id == ^loser_id))
      end)

      {:ok, %{conflict_id: conflict_id, deleted_id: loser_id, kept_id: keep_entry_id}}
    end)
  end

  @doc "Persist new conflicts to the database."
  def persist(scope_id, owner_id, conflicts) when is_list(conflicts) do
    repo = Config.repo()
    now = DateTime.utc_now()

    rows =
      Enum.map(conflicts, fn %{entry_a_id: a, entry_b_id: b, reason: reason, score: score} ->
        %{
          id: Ecto.UUID.generate(),
          scope_id: scope_id,
          owner_id: owner_id,
          entry_a_id: a,
          entry_b_id: b,
          reason: reason,
          score: score,
          status: "open",
          detected_at: now,
          updated_at: now
        }
      end)

    # Upsert: refresh reason/score and REOPEN a previously resolved conflict
    # when the contradiction is detected again. DO NOTHING silently hid
    # recurring contradictions behind a resolved status.
    repo.insert_all(Conflict, rows,
      on_conflict: {:replace, [:reason, :score, :status, :updated_at]},
      conflict_target: [:entry_a_id, :entry_b_id]
    )

    {:ok, length(conflicts)}
  end

  @doc "List all conflicts for a scope (including resolved)."
  def list_all(scope_id) do
    {:ok,
     Config.repo().all(
       from(c in Conflict,
         where: c.scope_id == ^scope_id,
         order_by: [desc: c.detected_at]
       )
     )}
  end

  # Private

  # Both resolve paths need the (entry_a_id, entry_b_id) pair to find the
  # loser — the entry the caller did NOT keep.
  defp with_pair(conflict_id, keep_entry_id, fun) do
    repo = Config.repo()

    case repo.get(Conflict, conflict_id) do
      nil ->
        {:error, :conflict_not_found}

      conflict ->
        loser_id =
          if conflict.entry_a_id == keep_entry_id,
            do: conflict.entry_b_id,
            else: conflict.entry_a_id

        fun.(repo, conflict, loser_id)
    end
  rescue
    _ -> {:error, :failed}
  end

  defp mark_resolved(repo, conflict_id, keep_entry_id) do
    repo.update_all(
      from(c in Conflict, where: c.id == ^conflict_id),
      set: [status: "resolved", resolved_by: keep_entry_id, updated_at: DateTime.utc_now()]
    )
  end

  # MEM-011: GREATEST is spelled MAX() on SQLite/libSQL; a CASE floor is
  # identical on both dialects, so no dialect branch is needed.
  defp halve_half_life(repo, loser_id) do
    now = DateTime.utc_now()

    repo.update_all(
      from(e in Entry,
        where: e.id == ^loser_id,
        update: [
          set: [
            half_life_days: fragment("CASE WHEN half_life_days / 2 > 1 THEN half_life_days / 2 ELSE 1 END"),
            updated_at: ^now
          ]
        ]
      ),
      []
    )
  end
end
