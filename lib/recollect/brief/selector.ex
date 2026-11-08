defmodule Recollect.Brief.Selector do
  @moduledoc """
  Picks `Recollect.Brief` items per section (MEM-019).

  Sections, in precedence order:

  * `:rules` — entries tagged `rule`/`convention`, ranked by verification,
    stability, retrieval, recency
  * `:focus` — the latest handoff plus recent session summaries
  * `:traps` — entries tagged `gotcha`/`trap`/`incident`
  * `:open_questions` — entries with `epistemic: "held"`
  * `:index` — summarized entries rendered as summaries, not full bodies
    (grows page entries when MEM-027 lands)

  An entry qualifying for several sections appears once — earliest
  precedence wins. Items are plain maps carrying `:citation` (`e1`, `h1`,
  `p1`), section, text, token estimate, and a budget priority.
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Schema.Entry
  alias Recollect.Schema.EntryTag
  alias Recollect.Tokenizer
  alias Recollect.Util

  @sections [:rules, :focus, :traps, :open_questions, :index]

  @section_priorities %{rules: 40, traps: 35, focus: 30, open_questions: 25, index: 20}
  @section_titles %{
    rules: "Rules (stable)",
    focus: "Focus",
    traps: "Traps",
    open_questions: "Open questions",
    index: "Index"
  }

  @rule_tags ~w(rule convention)
  @trap_tags ~w(gotcha trap incident)

  @verification_ranks %{
    "user" => 5,
    "code_ref" => 5,
    "cross_session" => 4,
    "test" => 4,
    "llm" => 3,
    "none" => 0
  }

  @stability_ranks %{"stable" => 3, "evolving" => 2, "volatile" => 1}

  @doc "Selected items across all sections, ranked within each section."
  def select(scope_id, opts \\ []) do
    scope_id = Util.uuid_to_string(scope_id)
    per_section = Keyword.get(opts, :per_section, 5)
    repo = Config.repo()

    selected =
      %{
        rules: tagged_entries(repo, scope_id, @rule_tags, per_section),
        focus: focus_items(repo, scope_id, per_section),
        traps: tagged_entries(repo, scope_id, @trap_tags, per_section),
        open_questions: held_entries(repo, scope_id, per_section),
        index: summarized_entries(repo, scope_id, per_section)
      }

    {items, _seen} =
      Enum.map_reduce(@sections, MapSet.new(), fn section, seen ->
        section_items =
          selected[section]
          |> rank_desc()
          |> Enum.take(per_section)
          |> Enum.reject(&MapSet.member?(seen, item_id(&1)))
          |> Enum.with_index()
          |> Enum.map(fn {row, position} ->
            build_item(section, row, position, per_section)
          end)

        new_seen =
          Enum.reduce(section_items, seen, fn item, acc -> MapSet.put(acc, item.id) end)

        {section_items, new_seen}
      end)

    Enum.concat(items)
  end

  @doc "The canonical section titles, e.g. \"Rules (stable)\"."
  def section_titles, do: @section_titles

  @doc "Sections in precedence order."
  def sections, do: @sections

  # Queries

  defp tagged_entries(repo, scope_id, tags, limit) do
    from(e in Entry,
      join: t in EntryTag,
      on: t.entry_id == e.id,
      where: e.scope_id == ^scope_id and t.tag in ^tags,
      distinct: e.id,
      order_by: [desc: e.inserted_at],
      limit: ^limit
    )
    |> Entry.live()
    |> repo.all()
    |> Enum.map(&{:entry, &1})
  end

  defp held_entries(repo, scope_id, limit) do
    from(e in Entry,
      where: e.scope_id == ^scope_id and e.epistemic == "held",
      order_by: [desc: e.inserted_at],
      limit: ^limit
    )
    |> Entry.live()
    |> repo.all()
    |> Enum.map(&{:entry, &1})
  end

  defp summarized_entries(repo, scope_id, limit) do
    from(e in Entry,
      where: e.scope_id == ^scope_id and not is_nil(e.summary),
      order_by: [desc: e.access_count, desc: e.inserted_at],
      limit: ^limit
    )
    |> Entry.live()
    |> repo.all()
    |> Enum.map(&{:entry, &1})
  end

  defp focus_items(repo, scope_id, limit) do
    session_notes =
      from(e in Entry,
        where: e.scope_id == ^scope_id and e.entry_type == "session_summary",
        order_by: [desc: e.inserted_at],
        limit: ^max(1, limit - 1)
      )
      |> Entry.live()
      |> repo.all()
      |> Enum.map(&{:entry, &1})

    handoff =
      case Recollect.Handoff.get(scope_id) do
        {:ok, %{} = h} when is_map_key(h, :what) ->
          [{:handoff, h}]

        _ ->
          []
      end

    Enum.concat([handoff | session_notes])
  end

  # Ranking + item shape

  # verification dominates, then stability, then retrieval, then recency.
  defp rank_desc(rows) do
    now = DateTime.utc_now()

    Enum.sort_by(rows, fn {kind, row} ->
      {base, recency_dt} = rank_parts(kind, row)

      recency_days =
        if recency_dt, do: DateTime.diff(now, recency_dt, :second), else: 0

      -(base - div(recency_days, 86_400))
    end)
  end

  defp rank_parts(:entry, row) do
    base =
      Map.get(@verification_ranks, row.verification, 0) * 1000 +
        Map.get(@stability_ranks, row.stability, 1) * 100 +
        min(row.access_count || 0, 50)

    {base, row.inserted_at}
  end

  defp rank_parts(:handoff, row), do: {50, row[:created_at] || row[:updated_at]}

  defp item_id({:entry, %Entry{id: id}}), do: id
  defp item_id({:handoff, %{id: id}}), do: id

  defp build_item(section, {kind, row}, position, per_section) do
    {id, citation_prefix, text, title, recency, meta} = describe(kind, row)

    %{
      id: id,
      citation: "#{citation_prefix}#{position + 1}",
      section: section,
      title: title,
      text: text,
      estimated_tokens: Tokenizer.estimate(text),
      priority: @section_priorities[section] + (per_section - position),
      score: rank_score(row),
      recency: recency,
      meta: meta
    }
  end

  defp describe(:entry, %Entry{} = e) do
    summary? = is_binary(e.summary) and e.summary != ""

    text =
      if summary? and e.entry_type != "session_summary" do
        e.content
      else
        e.summary || first_line(e.content)
      end

    meta =
      if e.verified_at,
        do: %{verified_at: e.verified_at},
        else: %{}

    {e.id, "e", text, nil, e.inserted_at, meta}
  end

  defp describe(:handoff, %{} = h) do
    text = "Where we left off: #{h.what}"

    text =
      case h[:next] do
        next when is_list(next) and next != [] -> text <> ". Next: " <> Enum.join(next, "; ")
        _ -> text
      end

    {h.id, "h", text, nil, h[:created_at] || h[:updated_at], %{}}
  end

  defp first_line(nil), do: ""
  defp first_line(content), do: content |> String.split("\n", parts: 2) |> List.first()

  defp rank_score(%Entry{} = e) do
    Map.get(@verification_ranks, e.verification, 0) * 100 +
      Map.get(@stability_ranks, e.stability, 1) * 10 +
      min(e.access_count || 0, 50)
  end

  defp rank_score(%{} = _handoff), do: 50
end
