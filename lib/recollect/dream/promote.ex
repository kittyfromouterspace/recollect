defmodule Recollect.Dream.Promote do
  @moduledoc """
  Dream stage: promote durable, useful claims into the brief's sections and
  demote/prune low-value ones (MEM-026). Promotion is TAG-based — the brief
  already reads `rule`/`gotcha` tags, so promoting means tagging, never a
  separate store.

  Score (all components 0..1, weights configurable via
  `dream.promote_weights`):

      0.35 * verification + 0.25 * retrieval_recency + 0.20 * outcome
      + 0.10 * stability + 0.10 * conflict_resolution

  * score ≥ `dream.promote_threshold` (default 0.65) ⇒ tag `rule`
    (or `gotcha` for negative-valence claims) so the brief picks it up;
  * stale / contradicted (open conflict) / never-retrieved claims lose
    their promote tags and get a `demoted_at` stamp;
  * after `dream.demote_grace_days` (default 14) in demoted state, the
    claim archives (`entry_type: "archived"`).

  Any promotion or demotion bumps the brief generation — the brief
  improves without manual curation.
  """

  import Ecto.Query

  alias Recollect.Brief
  alias Recollect.Config
  alias Recollect.Schema.Conflict
  alias Recollect.Schema.Entry
  alias Recollect.Schema.EntryTag
  alias Recollect.Telemetry
  alias Recollect.Util

  @promote_tags ~w(rule gotcha)
  @verification_score %{
    "user" => 1.0,
    "code_ref" => 1.0,
    "test" => 0.8,
    "cross_session" => 0.8,
    "llm" => 0.6,
    "none" => 0.0
  }
  @stability_score %{"stable" => 1.0, "evolving" => 0.6, "volatile" => 0.2}

  def run(scope_id, opts) do
    scope_id = Util.uuid_to_string(scope_id)
    repo = Config.repo()
    weights = weights(opts)
    threshold = Keyword.get(opts, :promote_threshold) || Config.dream()[:promote_threshold] || 0.65
    grace_days = Keyword.get(opts, :demote_grace_days) || Config.dream()[:demote_grace_days] || 14
    max_items = Keyword.get(opts, :max_items) || Config.dream()[:max_items] || 500

    entries =
      from(e in Entry, where: e.scope_id == ^scope_id, limit: ^max_items)
      |> Entry.live()
      |> repo.all()

    tags_by_entry = tags_by_entry(repo, scope_id)
    conflict_state = conflict_state(repo, scope_id)
    now = DateTime.utc_now()

    {promoted, demoted, archived} =
      Enum.reduce(entries, {[], [], []}, fn entry, {p, d, a} ->
        score = score_entry(entry, weights, conflict_state)
        tags = Map.get(tags_by_entry, entry.id, [])
        has_promote_tag? = Enum.any?(tags, &(&1 in @promote_tags))

        cond do
          score >= threshold and not has_promote_tag? ->
            tag = if entry.emotional_valence == "negative", do: "gotcha", else: "rule"
            add_tag(repo, entry, tag, scope_id)
            {[Map.put(entry, :dream_score, score) | p], d, a}

          demotion_worthy?(entry, score, threshold, conflict_state) ->
            if has_promote_tag? do
              remove_promote_tags(repo, entry)
              stamp_demoted(repo, entry, now)
            end

            if demoted_long_ago?(entry, now, grace_days) do
              archive(repo, entry)
              {p, d, [entry | a]}
            else
              {p, [Map.put(entry, :dream_score, score) | d], a}
            end

          true ->
            {p, d, a}
        end
      end)

    promoted = Enum.reverse(promoted)
    demoted = Enum.reverse(demoted)
    archived = Enum.reverse(archived)

    if promoted != [] or demoted != [] or archived != [] do
      # the brief's sections read tags — promotion/demotion must be visible
      Brief.invalidate(scope_id)
    end

    Telemetry.event(
      [:recollect, :dream, :promote, :stop],
      %{
        promoted: length(promoted),
        demoted: length(demoted),
        archived: length(archived)
      },
      %{scope_id: scope_id}
    )

    {:ok,
     %{
       scored: length(entries),
       promoted: length(promoted),
       demoted: length(demoted),
       archived: length(archived)
     }}
  end

  @doc "The configurable promotion weights (default per the MEM-026 formula)."
  def weights(opts \\ []) do
    Keyword.get(opts, :promote_weights) || Config.dream()[:promote_weights] ||
      [
        verification: 0.35,
        retrieval_recency: 0.25,
        outcome: 0.20,
        stability: 0.10,
        conflict_resolution: 0.10
      ]
  end

  # Private

  defp score_entry(entry, weights, conflict_state) do
    get = fn key -> Keyword.get(weights, key) end

    get.(:verification) * verification_score(entry.verification) +
      get.(:retrieval_recency) * retrieval_recency(entry) +
      get.(:outcome) * outcome_score(entry.outcome_score) +
      get.(:stability) * Map.get(@stability_score, entry.stability, 0.6) +
      get.(:conflict_resolution) * conflict_score(conflict_state, entry.id)
  end

  defp verification_score(verification), do: Map.get(@verification_score, verification, 0.0)

  # full credit when accessed today, zero after 30 idle days
  defp retrieval_recency(entry) do
    case entry.last_accessed_at do
      nil ->
        0.0

      dt ->
        days = DateTime.diff(DateTime.utc_now(), dt, :second) / 86_400
        max(0.0, 1.0 - days / 30)
    end
  end

  # outcome_score is an integer in [-5, 5]; nil is neutral
  defp outcome_score(nil), do: 0.5

  defp outcome_score(score) when is_integer(score) do
    score |> max(-5) |> min(5) |> Kernel.+(5) |> Kernel./(10)
  end

  defp outcome_score(_), do: 0.5

  # resolved conflicts prove the claim survived scrutiny; open ones hurt
  defp conflict_score(conflict_state, entry_id) do
    case Map.get(conflict_state, entry_id) do
      :resolved -> 1.0
      :open -> 0.0
      _ -> 0.5
    end
  end

  defp demotion_worthy?(entry, score, threshold, conflict_state) do
    stale? = Recollect.Confidence.resolve_state(entry) == "stale"
    contradicted? = Map.get(conflict_state, entry.id) == :open
    never_retrieved? = (entry.access_count || 0) == 0

    score < threshold or stale? or contradicted? or never_retrieved?
  end

  defp demoted_long_ago?(entry, now, grace_days) do
    case entry.metadata["demoted_at"] do
      iso when is_binary(iso) ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _offset} -> DateTime.diff(now, dt, :second) >= grace_days * 86_400
          _ -> false
        end

      _ ->
        false
    end
  end

  defp tags_by_entry(repo, scope_id) do
    from(t in EntryTag,
      join: e in Entry,
      on: e.id == t.entry_id,
      where: e.scope_id == ^scope_id,
      select: {t.entry_id, t.tag}
    )
    |> repo.all()
    |> Enum.group_by(
      fn {id, _tag} -> id end,
      fn {_id, tag} -> tag end
    )
    |> Map.new()
  end

  defp conflict_state(repo, scope_id) do
    from(c in Conflict, where: c.scope_id == ^scope_id)
    |> repo.all()
    |> Enum.reduce(%{}, fn conflict, acc ->
      default = if conflict.status == "open", do: :open, else: :resolved

      acc
      |> Map.update(conflict.entry_a_id, default, &merge_state(&1, default))
      |> Map.update(conflict.entry_b_id, default, &merge_state(&1, default))
    end)
  end

  defp merge_state(:open, _other), do: :open
  defp merge_state(_existing, :open), do: :open
  defp merge_state(_existing, _other), do: :resolved

  defp add_tag(repo, entry, tag, scope_id) do
    repo.insert_all(
      EntryTag,
      [%{entry_id: entry.id, tag: tag, scope_id: scope_id, owner_id: entry.owner_id}],
      on_conflict: :nothing,
      conflict_target: [:entry_id, :tag]
    )
  end

  defp remove_promote_tags(repo, entry) do
    repo.delete_all(
      from(t in EntryTag,
        where: t.entry_id == ^entry.id and t.tag in @promote_tags
      )
    )
  end

  defp stamp_demoted(repo, entry, now) do
    metadata =
      Map.merge(entry.metadata || %{}, %{
        "demoted_at" => DateTime.to_iso8601(now),
        "dream_score" => "demoted"
      })

    repo.update_all(
      from(e in Entry, where: e.id == ^entry.id),
      set: [metadata: metadata, updated_at: now]
    )
  end

  defp archive(repo, entry) do
    repo.update_all(
      from(e in Entry, where: e.id == ^entry.id),
      set: [entry_type: "archived", updated_at: DateTime.utc_now()]
    )
  end
end
