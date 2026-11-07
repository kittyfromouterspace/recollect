defmodule Recollect.Conflicts do
  @moduledoc """
  Conflict management for contradictory memories.

  List open conflicts, resolve them by keeping one entry and weakening
  the other, or delete the losing entry entirely.
  """

  alias Recollect.Config

  @doc "List open conflicts for a scope."
  def list(scope_id) do
    repo = Config.repo()

    case repo.query(
           """
             SELECT id, entry_a_id, entry_b_id, reason, score, status, detected_at
             FROM recollect_conflicts
             WHERE scope_id = $1 AND status = 'open'
             ORDER BY score DESC
           """,
           [Recollect.Util.uuid_to_bin(scope_id)]
         ) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> Recollect.Util.row_to_map(columns, row) end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Get a single conflict by ID."
  def get(conflict_id) do
    repo = Config.repo()

    case repo.query(
           """
             SELECT id, entry_a_id, entry_b_id, reason, score, status, resolved_by, detected_at
             FROM recollect_conflicts
             WHERE id = $1
           """,
           [conflict_id]
         ) do
      {:ok, %{rows: [[]], columns: _}} ->
        {:error, :not_found}

      {:ok, %{rows: [row], columns: columns}} ->
        {:ok, Recollect.Util.row_to_map(columns, row)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resolve a conflict by keeping one entry and weakening the other.
  The loser's half-life is halved.
  """
  def resolve(conflict_id, keep_entry_id) do
    repo = Config.repo()
    now = DateTime.utc_now()

    try do
      case repo.query(
             """
               SELECT entry_a_id, entry_b_id FROM recollect_conflicts WHERE id = $1
             """,
             [Recollect.Util.uuid_to_bin(conflict_id)]
           ) do
        {:ok, %{rows: [[a_id, b_id]]}} ->
          # Row ids come back as 16-byte binaries; compare in string space so
          # the loser is actually the entry the caller did NOT keep.
          loser_id = if Ecto.UUID.load!(a_id) == keep_entry_id, do: b_id, else: a_id

          repo.transaction(fn ->
            repo.query(
              """
                UPDATE recollect_conflicts
                SET status = 'resolved', resolved_by = $1, updated_at = $2
                WHERE id = $3
              """,
              [Recollect.Util.uuid_to_bin(keep_entry_id), now, Recollect.Util.uuid_to_bin(conflict_id)]
            )

            repo.query(
              """
                UPDATE recollect_entries
                SET half_life_days = GREATEST(1, half_life_days / 2), updated_at = $1
                WHERE id = $2
              """,
              [now, loser_id]
            )
          end)

          {:ok, %{conflict_id: conflict_id, loser_id: Ecto.UUID.load!(loser_id), kept_id: keep_entry_id}}

        _ ->
          {:error, :conflict_not_found}
      end
    rescue
      _ -> {:error, :failed}
    end
  end

  @doc "Resolve a conflict by deleting the losing entry."
  def resolve_and_forget(conflict_id, keep_entry_id) do
    repo = Config.repo()
    now = DateTime.utc_now()

    try do
      case repo.query(
             """
               SELECT entry_a_id, entry_b_id FROM recollect_conflicts WHERE id = $1
             """,
             [Recollect.Util.uuid_to_bin(conflict_id)]
           ) do
        {:ok, %{rows: [[a_id, b_id]]}} ->
          loser_id = if Ecto.UUID.load!(a_id) == keep_entry_id, do: b_id, else: a_id

          repo.transaction(fn ->
            repo.query(
              """
                UPDATE recollect_conflicts
                SET status = 'resolved', resolved_by = $1, updated_at = $2
                WHERE id = $3
              """,
              [Recollect.Util.uuid_to_bin(keep_entry_id), now, Recollect.Util.uuid_to_bin(conflict_id)]
            )

            repo.query("DELETE FROM recollect_entries WHERE id = $1", [loser_id])
          end)

          {:ok, %{conflict_id: conflict_id, deleted_id: Ecto.UUID.load!(loser_id), kept_id: keep_entry_id}}

        _ ->
          {:error, :conflict_not_found}
      end
    rescue
      _ -> {:error, :failed}
    end
  end

  @doc "Persist new conflicts to the database."
  def persist(scope_id, owner_id, conflicts) when is_list(conflicts) do
    repo = Config.repo()
    now = DateTime.utc_now()

    for %{entry_a_id: a, entry_b_id: b, reason: reason, score: score} <- conflicts do
      # Upsert: refresh reason/score and REOPEN a previously resolved conflict
      # when the contradiction is detected again. DO NOTHING silently hid
      # recurring contradictions behind a resolved status.
      repo.query(
        """
          INSERT INTO recollect_conflicts (id, scope_id, owner_id, entry_a_id, entry_b_id, reason, score, status, detected_at, updated_at)
          VALUES ($1, $2, $3, $4, $5, $6, $7, 'open', $8, $9)
          ON CONFLICT (entry_a_id, entry_b_id) DO UPDATE
            SET reason = EXCLUDED.reason,
                score = EXCLUDED.score,
                status = 'open',
                updated_at = EXCLUDED.updated_at
        """,
        [
          Ecto.UUID.bingenerate(),
          Recollect.Util.uuid_to_bin(scope_id),
          Recollect.Util.uuid_to_bin(owner_id),
          Recollect.Util.uuid_to_bin(a),
          Recollect.Util.uuid_to_bin(b),
          reason,
          score,
          now,
          now
        ]
      )
    end

    {:ok, length(conflicts)}
  end

  @doc "List all conflicts for a scope (including resolved)."
  def list_all(scope_id) do
    repo = Config.repo()

    case repo.query(
           """
             SELECT id, entry_a_id, entry_b_id, reason, score, status, resolved_by, detected_at
             FROM recollect_conflicts
             WHERE scope_id = $1
             ORDER BY detected_at DESC
           """,
           [Recollect.Util.uuid_to_bin(scope_id)]
         ) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> Recollect.Util.row_to_map(columns, row) end)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
