defmodule Recollect.Review do
  @moduledoc """
  The hygiene loop (MEM-017): review candidates with reasons and a
  suggested action, and per-entry "why is this here?" explanations.

  A host builds its review UI from `candidates/2` (what deserves a look and
  why) and `explain/1` (the full story of one entry: evidence, usage,
  verification, supersession).

  ## Reasons and suggested actions

  | Reason | Fires when | Suggested |
  |---|---|---|
  | `:never_retrieved` | `access_count == 0` and older than N days | `:archive` |
  | `:stale` | `Confidence.resolve_state/1 == "stale"` | `:archive` |
  | `:unverified` | `verification == "none"` and `epistemic != "observed"` | `:verify` |
  | `:duplicate` | same `source_id` across sources, or identical content | `:merge` |
  | `:orphan_summary` | summary-type entry with no `derived_from` edge or evidence | `:delete` |
  | `:expired` | `valid_to < now` | `:archive` |

  Precedence for `:suggested`: merge > archive (expired) > delete >
  verify > archive (stale/never-retrieved) > keep.
  """

  import Ecto.Query

  alias Recollect.Confidence
  alias Recollect.Config
  alias Recollect.Schema.Edge
  alias Recollect.Schema.Entry
  alias Recollect.Schema.Evidence
  alias Recollect.Telemetry
  alias Recollect.Util

  @never_retrieved_days_default 30
  # The plan names entry_type "summary"; this engine's summary type is
  # "session_summary" — both are treated as summaries.
  @summary_types ~w(summary session_summary)

  @doc """
  Review candidates for a scope, most-flagged first.

  ## Options

  - `:limit` — max candidates (default: 50)
  - `:never_retrieved_days` — age threshold for `:never_retrieved` (default: 30)

  Returns `{:ok, [%{entry: %Entry{}, reasons: [atom], suggested: atom}]}` —
  entries with no reasons are not candidates.
  """
  def candidates(scope_id, opts \\ []) do
    Telemetry.span([:recollect, :review, :query], %{scope_id: scope_id}, fn ->
      scope_id = Util.uuid_to_string(scope_id)
      repo = Config.repo()
      limit = Keyword.get(opts, :limit, 50)
      never_days = Keyword.get(opts, :never_retrieved_days, @never_retrieved_days_default)
      now = DateTime.utc_now()

      entries = from(e in Entry, where: e.scope_id == ^scope_id) |> Entry.live() |> repo.all()

      dup_source_ids = duplicated(Enum.map(entries, & &1.source_id))
      dup_contents = duplicated(Enum.map(entries, &content_key/1))
      derived_ids = derived_entry_ids(repo, Enum.map(entries, & &1.id))
      live_ids = MapSet.new(Enum.map(entries, & &1.id))
      orphan_ids = MapSet.difference(live_ids, derived_ids)

      candidates =
        entries
        |> Enum.map(fn entry ->
          reasons = reasons_for(entry, now, never_days, dup_source_ids, dup_contents, orphan_ids)
          %{entry: entry, reasons: reasons, suggested: suggested_action(reasons)}
        end)
        |> Enum.reject(&(&1.reasons == []))
        |> Enum.sort_by(&{-length(&1.reasons), &1.entry.id})
        |> Enum.take(limit)

      {:ok, candidates}
    end)
  end

  @doc """
  Explain why an entry exists: evidence, usage, verification, supersession
  links, and a human-readable `:why`.

  Returns `{:error, :not_found}` for unknown ids.
  """
  def explain(entry_id) do
    Telemetry.span([:recollect, :review, :explain], %{entry_id: entry_id}, fn ->
      entry_id = Util.uuid_to_string(entry_id)
      repo = Config.repo()

      case repo.get(Entry, entry_id) do
        nil ->
          {:error, :not_found}

        entry ->
          evidence =
            from(ev in Evidence,
              where: ev.entry_id == ^entry_id,
              order_by: [desc: ev.created_at]
            )
            |> repo.all()
            |> Enum.map(fn link ->
              %{
                relation: link.relation,
                source_type: link.source_type,
                source_ref: link.source_ref,
                excerpt: link.excerpt,
                event_id: link.event_id,
                at: link.created_at
              }
            end)

          usage = %{access_count: entry.access_count || 0, last_accessed_at: entry.last_accessed_at}

          # connect(new, old, "supersedes"): the source is the newer claim.
          superseded_by =
            repo.all(
              from(ed in Edge,
                where: ed.relation == "supersedes" and ed.target_entry_id == ^entry_id,
                select: ed.source_entry_id
              )
            )

          supersedes =
            repo.all(
              from(ed in Edge,
                where: ed.relation == "supersedes" and ed.source_entry_id == ^entry_id,
                select: ed.target_entry_id
              )
            )

          {:ok,
           %{
             entry: entry,
             evidence: evidence,
             usage: usage,
             verification: %{
               marker: entry.verification,
               verified_at: entry.verified_at,
               epistemic: entry.epistemic
             },
             supersedes: supersedes,
             superseded_by: superseded_by,
             why: build_why(entry, evidence, usage)
           }}
      end
    end)
  end

  # Private

  defp reasons_for(entry, now, never_days, dup_source_ids, dup_contents, orphan_ids) do
    reasons = []

    reasons =
      if entry.access_count in [nil, 0] and days_old(entry.inserted_at, now) >= never_days,
        do: [:never_retrieved | reasons],
        else: reasons

    reasons = if Confidence.resolve_state(entry) == "stale", do: [:stale | reasons], else: reasons

    reasons =
      if entry.verification in [nil, "none"] and entry.epistemic != "observed",
        do: [:unverified | reasons],
        else: reasons

    reasons =
      if is_binary(entry.source_id) and MapSet.member?(dup_source_ids, entry.source_id),
        do: [:duplicate | reasons],
        else: reasons

    reasons =
      if is_binary(entry.content) and MapSet.member?(dup_contents, content_key(entry)),
        do: [:duplicate | reasons],
        else: reasons

    reasons =
      if entry.entry_type in @summary_types and MapSet.member?(orphan_ids, entry.id),
        do: [:orphan_summary | reasons],
        else: reasons

    reasons =
      if entry.valid_to && DateTime.before?(entry.valid_to, now),
        do: [:expired | reasons],
        else: reasons

    Enum.reverse(reasons)
  end

  defp suggested_action(reasons) do
    cond do
      :duplicate in reasons -> :merge
      :expired in reasons -> :archive
      :orphan_summary in reasons -> :delete
      :unverified in reasons -> :verify
      :never_retrieved in reasons or :stale in reasons -> :archive
      true -> :keep
    end
  end

  defp duplicated(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Map.filter(fn {_value, count} -> count > 1 end)
    |> Map.keys()
    |> MapSet.new()
  end

  defp content_key(entry) when is_binary(entry.content), do: String.trim(String.downcase(entry.content))
  defp content_key(_entry), do: nil

  # An entry is "derived" when a derived_from edge touches it on either end
  # or derived_from evidence points at it.
  defp derived_entry_ids(repo, entry_ids) do
    from_edges =
      repo.all(
        from(ed in Edge,
          where: ed.relation == "derived_from" and ed.source_entry_id in ^entry_ids,
          select: ed.source_entry_id
        )
      )

    to_edges =
      repo.all(
        from(ed in Edge,
          where: ed.relation == "derived_from" and ed.target_entry_id in ^entry_ids,
          select: ed.target_entry_id
        )
      )

    evidence_ids =
      repo.all(
        from(ev in Evidence,
          where: ev.relation == "derived_from" and ev.entry_id in ^entry_ids,
          select: ev.entry_id
        )
      )

    MapSet.new(from_edges ++ to_edges ++ evidence_ids)
  end

  defp days_old(nil, _now), do: 0

  defp days_old(dt, now) do
    max(0, now |> DateTime.diff(dt, :second) |> div(86_400))
  end

  defp build_why(entry, evidence, usage) do
    parts = [
      "recorded #{days_old(entry.inserted_at, DateTime.utc_now())} day(s) ago",
      evidence_clause(evidence),
      "retrieved #{usage.access_count} time(s)",
      verification_clause(entry)
    ]

    Enum.join(Enum.reject(parts, &is_nil/1), "; ")
  end

  defp evidence_clause([]), do: "no evidence attached"

  defp evidence_clause(evidence) do
    refs =
      Enum.map(evidence, fn e ->
        ref = e.source_ref || (e.event_id && "event:#{e.event_id}") || "unknown"

        "#{e.relation} #{e.source_type || "event"}:#{ref}"
      end)

    "evidence: " <> Enum.join(refs, ", ")
  end

  defp verification_clause(entry) do
    if entry.verification in [nil, "none"] do
      "unverified (#{entry.epistemic || "inferred"})"
    else
      "verified via #{entry.verification}"
    end
  end
end
