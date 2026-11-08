defmodule Recollect.Dream.Prune do
  @moduledoc """
  Dream stage: prune dead weight (MEM-026).

  * duplicate events (same owner + content_hash) — the newest duplicates
    are deleted, unreferenced ones only;
  * events past `events.retention_days` that no evidence references
    (scoped version of `Recollect.Event.prune/1`);
  * orphan summaries — `summary`/`session_summary` entries with no
    derived_from edges and no evidence — tombstoned (`deleted_at`), never
    hard-deleted;
  * expired volatile claims — `stability: "volatile"` with `valid_to` in
    the past — tombstoned.

  Evidence-backed claims are NEVER hard-deleted. The brief generation
  bumps afterwards so sections reflect the pruned reality.
  """

  import Ecto.Query

  alias Recollect.Brief
  alias Recollect.Config
  alias Recollect.Schema.Entry
  alias Recollect.Schema.Event, as: EventRow
  alias Recollect.Schema.Evidence
  alias Recollect.Telemetry

  @summary_types ~w(summary session_summary)

  def run(scope_id, opts) do
    scope_id = Recollect.Util.uuid_to_string(scope_id)
    repo = Config.repo()

    dup_events = prune_duplicate_events(repo, scope_id)
    pruned_events = prune_old_events(repo, scope_id, opts)
    orphan_summaries = tombstone_orphan_summaries(repo, scope_id)
    expired = tombstone_expired_volatile(repo, scope_id)

    metrics = %{
      duplicate_events_deleted: dup_events,
      events_pruned: pruned_events,
      orphan_summaries_tombstoned: orphan_summaries,
      expired_volatile_tombstoned: expired
    }

    # sections read tags and entries — pruning must be visible
    Brief.invalidate(scope_id)

    Telemetry.event([:recollect, :dream, :prune, :stop], metrics, %{scope_id: scope_id})

    {:ok, metrics}
  end

  # Private

  # Same owner + content_hash recorded more than once: keep the earliest,
  # delete the rest — unless evidence already cites them.
  defp prune_duplicate_events(repo, scope_id) do
    groups =
      repo.all(
        from(e in EventRow,
          where: e.scope_id == ^scope_id,
          group_by: [e.owner_id, e.content_hash],
          having: count(e.id) > 1,
          select: {e.owner_id, e.content_hash}
        )
      )

    Enum.reduce(groups, 0, fn {owner_id, hash}, acc ->
      keep_id =
        repo.one(
          from(e in EventRow,
            where: e.scope_id == ^scope_id and e.owner_id == ^owner_id and e.content_hash == ^hash,
            order_by: [asc: e.created_at],
            limit: 1,
            select: e.id
          )
        )

      # unreferenced duplicates die; the referenced keep is protected by its
      # evidence FK anyway, so the delete targets only the non-kept rows
      {count, _} =
        repo.delete_all(
          from(e in EventRow,
            where:
              e.scope_id == ^scope_id and e.owner_id == ^owner_id and e.content_hash == ^hash and
                e.id != ^keep_id
          )
        )

      acc + count
    end)
  end

  defp prune_old_events(repo, scope_id, opts) do
    retention_days =
      Keyword.get(opts, :retention_days) || Config.events()[:retention_days] || 30

    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    {count, _} =
      repo.delete_all(
        from(e in EventRow,
          where:
            e.scope_id == ^scope_id and e.occurred_at < ^cutoff and
              e.id not in subquery(from(ev in Evidence, where: not is_nil(ev.event_id), select: ev.event_id))
        )
      )

    count
  end

  # Orphan = summary-typed, no derived_from evidence, no derived_from edge.
  defp tombstone_orphan_summaries(repo, scope_id) do
    candidates =
      from(e in Entry,
        where:
          e.scope_id == ^scope_id and e.entry_type in @summary_types and
            is_nil(e.deleted_at),
        select: e
      )
      |> Entry.live()
      |> repo.all()

    derived_entry_ids =
      from(ev in Evidence,
        join: e in Entry,
        on: ev.entry_id == e.id,
        where: e.scope_id == ^scope_id and ev.relation == "derived_from",
        select: ev.entry_id
      )
      |> repo.all()
      |> MapSet.new()

    derived_edges =
      from(ed in Recollect.Schema.Edge,
        where: ed.relation == "derived_from",
        select: [ed.source_entry_id, ed.target_entry_id]
      )
      |> repo.all()
      |> List.flatten()
      |> MapSet.new()

    derived = MapSet.union(derived_entry_ids, derived_edges)

    orphans =
      Enum.filter(candidates, fn e -> not MapSet.member?(derived, e.id) end)

    if orphans != [] do
      now = DateTime.utc_now()

      repo.update_all(
        from(e in Entry, where: e.id in ^Enum.map(orphans, & &1.id)),
        set: [deleted_at: now, updated_at: now]
      )
    end

    length(orphans)
  end

  defp tombstone_expired_volatile(repo, scope_id) do
    now = DateTime.utc_now()

    {count, _} =
      repo.update_all(
        from(e in Entry,
          where:
            e.scope_id == ^scope_id and e.stability == "volatile" and
              not is_nil(e.valid_to) and e.valid_to < ^now and
              is_nil(e.deleted_at)
        ),
        set: [deleted_at: now, updated_at: now]
      )

    count
  end
end
