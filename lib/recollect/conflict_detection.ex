defmodule Recollect.ConflictDetection do
  @moduledoc """
  Automatic conflict detection for contradictory memories.

  Uses Task.async_stream for parallel pairwise comparison.
  """

  import Ecto.Query

  alias Recollect.Schema.Entry

  @conflict_threshold 0.55

  @doc "Detect conflicts among entries in a scope."
  def detect(scope_id) do
    entries = get_active_entries(scope_id)

    if length(entries) < 2 do
      []
    else
      pairs = generate_pairs(entries)

      pairs
      |> Task.async_stream(
        fn {a, b} -> check_conflict(a, b) end,
        max_concurrency: System.schedulers_online(),
        timeout: 30_000
      )
      |> Enum.flat_map(fn
        {:ok, result} -> if result, do: [result], else: []
        {:exit, _reason} -> []
      end)
    end
  end

  # Tuple-ize once: Enum.at/2 on a list inside the pair loop is O(n^3).
  defp generate_pairs(entries) do
    entries_t = List.to_tuple(entries)
    n = tuple_size(entries_t)

    for i <- 0..(n - 2),
        j <- (i + 1)..(n - 1) do
      {elem(entries_t, i), elem(entries_t, j)}
    end
  end

  defp check_conflict(entry_a, entry_b) do
    stripped_overlap =
      Recollect.Util.text_overlap(
        strip_polarity(entry_a.content),
        strip_polarity(entry_b.content)
      )

    overlap_score = max(stripped_overlap, tag_overlap(entry_a.tags, entry_b.tags) * 0.75)

    if overlap_score < @conflict_threshold do
      nil
    else
      case classify_conflict(entry_a.content, entry_b.content) do
        nil ->
          nil

        reason ->
          # Canonical pair order so the (entry_a_id, entry_b_id) unique index
          # sees one stable row per pair regardless of input order.
          {a_id, b_id} =
            if entry_a.id <= entry_b.id, do: {entry_a.id, entry_b.id}, else: {entry_b.id, entry_a.id}

          %{
            entry_a_id: a_id,
            entry_b_id: b_id,
            reason: reason,
            score: overlap_score
          }
      end
    end
  end

  # Two entries with no tags share nothing, not everything: empty tag lists
  # must score 0, or every untagged pair inherits a 0.75 floor.
  defp tag_overlap(a, b) when is_list(a) and is_list(b) and a != [] and b != [], do: Recollect.Util.jaccard(a, b)

  defp tag_overlap(_, _), do: 0.0

  defp classify_conflict(text_a, text_b) do
    a = String.downcase(text_a)
    b = String.downcase(text_b)

    cond do
      enabled_disabled?(a, b) -> "enabled/disabled mismatch"
      true_false?(a, b) -> "true/false mismatch"
      always_never?(a, b) -> "always/never mismatch"
      true -> nil
    end
  end

  defp enabled_disabled?(a, b) do
    (contains_any?(a, ["enabled", "enable", "on"]) and
       contains_any?(b, ["disabled", "disable", "off"])) or
      (contains_any?(b, ["enabled", "enable", "on"]) and
         contains_any?(a, ["disabled", "disable", "off"]))
  end

  defp true_false?(a, b) do
    (contains_any?(a, ["true", "yes"]) and contains_any?(b, ["false", "no"])) or
      (contains_any?(b, ["true", "yes"]) and contains_any?(a, ["false", "no"]))
  end

  defp always_never?(a, b) do
    (contains_any?(a, ["always", "must"]) and contains_any?(b, ["never", "must not"])) or
      (contains_any?(b, ["always", "must"]) and contains_any?(a, ["never", "must not"]))
  end

  defp strip_polarity(text) do
    text
    |> String.downcase()
    |> String.replace(
      ~r/\b(not|never|no|don't|doesn't|cannot|shouldn't|enabled|enable|disabled|disable|on|off|true|false|always|must|works?|missing|broken|failed|available|present)\b/,
      " "
    )
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Word-boundary matching: substring checks made "backoff" match "off" and
  # "exponential" match "on", manufacturing conflicts from innocent text.
  defp contains_any?(text, needles) do
    Enum.any?(needles, fn needle ->
      Regex.match?(~r/\b#{Regex.escape(needle)}\b/i, text)
    end)
  end

  defp get_active_entries(scope_id) do
    # Query through the schema: the previous raw SELECT named a nonexistent
    # tags_json column and bound the scope as a string, so the query errored
    # on every call and detect/1 silently returned [] forever.
    repo = Recollect.Config.repo()

    from(e in Entry,
      left_join: t in assoc(e, :entry_tags),
      where: e.scope_id == ^scope_id and e.entry_type != "archived",
      order_by: [asc: e.id, asc: t.tag],
      select: %{id: e.id, content: e.content, tag: t.tag}
    )
    |> repo.all()
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {id, rows} ->
      %{
        id: id,
        content: hd(rows).content,
        tags: rows |> Enum.map(& &1.tag) |> Enum.reject(&is_nil/1)
      }
    end)
    |> Enum.sort_by(& &1.id)
  end
end
