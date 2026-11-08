defmodule Recollect.Search.ContextFormatter do
  @moduledoc """
  Formats search results as text suitable for LLM system prompt injection.

  `format/1` is the legacy un-budgeted renderer (kept byte-identical).
  `format/2` and `format_with_meta/2` (MEM-020) convert the pack into one
  unified item list, dedupe by id, rank by score, and fit it through
  `Recollect.Budget` with a hard `:max_tokens` cap — every emitted line
  carries a citation (`[e3]` entry, `[c2]` chunk, `[p1]` pack entity).
  """

  alias Recollect.Budget
  alias Recollect.Tokenizer

  @entity_cap 20
  @relation_cap 20

  @doc "Format a context pack into readable text for LLM consumption (legacy, un-budgeted)."
  def format(%{} = pack) do
    sections =
      []
      |> maybe_add_chunks(pack[:chunks])
      |> maybe_add_entries(pack[:entries])
      |> maybe_add_related(pack[:related_entries])
      |> maybe_add_entities(pack[:entities])
      |> maybe_add_relations(pack[:relations])

    if sections == [] do
      ""
    else
      Enum.join(sections, "\n\n")
    end
  end

  @doc """
  Format a context pack under a hard token budget (MEM-020).

  ## Options

  - `:max_tokens` — hard cap (default: 1500); a 10% reserve covers section
    headers and citation markers
  - `:dedupe` — drop entries that appear in both `:entries` and
    `:related_entries` (default: true)
  - `:citations` — append `[e3]`-style citations (default: true)
  - `:format` — `:text` (default) or `:markdown` section headers
  """
  def format(pack, opts) when is_map(pack) and is_list(opts) do
    {text, _meta} = build(pack, opts)
    text
  end

  @doc """
  Like `format/2` but returns `{:ok, text, metadata}` where metadata
  carries `:used_tokens`, `:truncated`, and `:dropped`.
  """
  def format_with_meta(pack, opts \\ []) when is_map(pack) and is_list(opts) do
    {text, meta} = build(pack, opts)
    {:ok, text, meta}
  end

  # Private — budgeted path (MEM-020)

  defp build(pack, opts) do
    max_tokens = Keyword.get(opts, :max_tokens, 1_500)
    dedupe? = Keyword.get(opts, :dedupe, true)
    citations? = Keyword.get(opts, :citations, true)
    format = Keyword.get(opts, :format, :text)

    items = unified_items(pack, dedupe?)

    fit = Budget.fit(items, max_tokens)

    text = render_fit(fit, citations?, format)

    meta = %{
      used_tokens: fit.used,
      budget: fit.budget,
      truncated: fit.truncated,
      dropped: fit.dropped,
      items: fit.items
    }

    {text, meta}
  end

  # One unified item list; entries (including graph-related entries) carry
  # priority 30, chunks 25, pack entities 15, relations 10 — the structured
  # tail is what gets dropped first when the budget is tight. Citations are
  # assigned after dedupe, so numbering stays stable (e1.., c1.., p1.., r1..).
  defp unified_items(pack, dedupe?) do
    entries =
      pack[:entries]
      |> List.wrap()
      |> Enum.map(&entry_item/1)

    related =
      pack[:related_entries]
      |> List.wrap()
      |> Enum.map(&entry_item/1)

    {entries, related} =
      if dedupe? do
        seen = MapSet.new(Enum.map(entries, & &1.id))
        related = Enum.reject(related, &MapSet.member?(seen, &1.id))
        {entries, related}
      else
        {entries, related}
      end

    chunks =
      pack[:chunks]
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.map(fn {chunk, idx} ->
        text = get(chunk, :content)
        id = get(chunk, :id) || "chunk:#{idx}"
        score = get(chunk, :score) || 0.0

        %{
          id: id,
          kind: :chunk,
          text: text,
          score: score,
          priority: 25,
          estimated_tokens: Tokenizer.estimate(text || "")
        }
      end)

    entities =
      pack[:entities]
      |> List.wrap()
      |> Enum.uniq_by(&get(&1, :name))
      |> Enum.take(@entity_cap)
      |> Enum.map(fn entity ->
        name = get(entity, :name) || "unknown"
        type = get(entity, :entity_type) || "unknown"
        desc = get(entity, :description) || ""
        text = "#{name} (#{type}): #{desc}"

        %{
          id: "entity:#{name}",
          kind: :entity,
          text: text,
          score: 0.0,
          priority: 15,
          estimated_tokens: Tokenizer.estimate(text)
        }
      end)

    relations =
      pack[:relations]
      |> List.wrap()
      |> Enum.take(@relation_cap)
      |> Enum.map(fn r ->
        from = get(r, :from_id)
        to = get(r, :to_id)
        type = get(r, :relation_type)
        text = "#{from} --[#{type}]--> #{to}"

        %{
          id: "relation:#{from}:#{to}:#{type}",
          kind: :relation,
          text: text,
          score: 0.0,
          priority: 10,
          estimated_tokens: Tokenizer.estimate(text)
        }
      end)

    (entries ++ related ++ chunks ++ entities ++ relations)
    |> Enum.reject(&(is_nil(&1.text) or &1.text == ""))
    |> assign_citations()
  end

  @citation_prefixes %{:entry => "e", :chunk => "c", :entity => "p", :relation => "r"}

  defp assign_citations(items) do
    {items, _} =
      Enum.map_reduce(items, %{}, fn item, counters ->
        prefix = Map.fetch!(@citation_prefixes, item.kind)
        n = Map.get(counters, prefix, 0) + 1

        item =
          item
          |> Map.put(:citation, "#{prefix}#{n}")
          |> Map.put(:estimated_tokens, Tokenizer.estimate(item.text))

        {item, Map.put(counters, prefix, n)}
      end)

    items
  end

  defp entry_item(raw) do
    id = get(raw, :id) || content_key(raw)
    score = get(raw, :score) || 0.0
    type = get(raw, :entry_type) || "note"
    summary = get(raw, :summary)
    content = get(raw, :content) || ""

    # Summary first; the full content only rides along when there is no
    # summary to stand in for it.
    text = if present?(summary), do: summary, else: content

    %{
      id: id,
      kind: :entry,
      text: "[#{type}] (score: #{Float.round(score / 1, 3)}) #{text}",
      score: score,
      priority: 30,
      estimated_tokens: 0
    }
  end

  defp render_fit(fit, citations?, format) do
    lines =
      Enum.map(fit.items, fn item ->
        citation = if citations?, do: "[#{item.citation}] ", else: ""
        "#{citation}#{item.text}"
      end)

    cond do
      lines == [] ->
        ""

      format == :markdown and Enum.any?(fit.items, &(&1.kind == :entry)) ->
        entry_lines =
          fit.items
          |> Enum.filter(&(&1.kind in [:entry, :chunk]))
          |> Enum.map(fn item ->
            citation = if citations?, do: "[#{item.citation}] ", else: ""
            "#{citation}#{item.text}"
          end)

        graph_lines =
          fit.items
          |> Enum.filter(&(&1.kind in [:entity, :relation]))
          |> Enum.map(fn item ->
            citation = if citations?, do: "[#{item.citation}] ", else: ""
            "- #{citation}#{item.text}"
          end)

        sections =
          [entry_lines, graph_lines]
          |> Enum.reject(&(&1 == []))
          |> Enum.map(fn lines -> Enum.join(lines, "\n") end)

        Enum.join(sections, "\n\n## Known Graph\n")

      true ->
        Enum.join(lines, "\n")
    end
  end

  # Legacy helpers — kept verbatim for format/1.

  defp maybe_add_chunks(acc, chunks) when is_list(chunks) and chunks != [] do
    text =
      chunks
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {chunk, idx} ->
        score = chunk["score"] || chunk[:score] || 0.0
        content = chunk["content"] || chunk[:content] || ""
        "[Chunk #{idx} (score: #{Float.round(score / 1, 3)})] #{content}"
      end)

    acc ++ ["## Relevant Memory Chunks\n#{text}"]
  end

  defp maybe_add_chunks(acc, _), do: acc

  defp maybe_add_entries(acc, entries) when is_list(entries) and entries != [] do
    text =
      entries
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {entry, idx} ->
        score = entry["score"] || entry[:score] || 0.0
        content = entry["content"] || entry[:content] || ""
        summary = entry["summary"] || entry[:summary]
        type = entry["entry_type"] || entry[:entry_type] || "note"
        display = summary || String.slice(content, 0, 200)
        "[#{idx}] [#{type}] (score: #{Float.round(score / 1, 3)}) #{display}"
      end)

    acc ++ ["## Relevant Knowledge\n#{text}"]
  end

  defp maybe_add_entries(acc, _), do: acc

  defp maybe_add_related(acc, related) when is_list(related) and related != [] do
    text =
      Enum.map_join(related, "\n", fn entry ->
        content = entry["content"] || entry[:content] || ""
        type = entry["entry_type"] || entry[:entry_type] || "note"
        summary = entry["summary"] || entry[:summary]
        display = summary || String.slice(content, 0, 200)
        "[Related] [#{type}] #{display}"
      end)

    acc ++ ["## Related Knowledge\n#{text}"]
  end

  defp maybe_add_related(acc, _), do: acc

  defp maybe_add_entities(acc, entities) when is_list(entities) and entities != [] do
    text =
      entities
      |> Enum.uniq_by(fn e -> e["name"] || e[:name] end)
      |> Enum.take(20)
      |> Enum.map_join("\n", fn e ->
        name = e["name"] || e[:name] || "unknown"
        type = e["entity_type"] || e[:entity_type] || "unknown"
        desc = e["description"] || e[:description] || ""
        "- #{name} (#{type}): #{desc}"
      end)

    acc ++ ["## Known Entities\n#{text}"]
  end

  defp maybe_add_entities(acc, _), do: acc

  defp maybe_add_relations(acc, relations) when is_list(relations) and relations != [] do
    text =
      relations
      |> Enum.take(20)
      |> Enum.map_join("\n", fn r ->
        from = r[:from_id] || r["from_id"]
        to = r[:to_id] || r["to_id"]
        type = r[:relation_type] || r["relation_type"]
        "- #{from} --[#{type}]--> #{to}"
      end)

    acc ++ ["## Known Relationships\n#{text}"]
  end

  defp maybe_add_relations(acc, _), do: acc

  # Accessors: packs arrive with string keys (raw SQL rows) or atom keys.

  defp get(map, key) when is_map(map) do
    map[key] || map[to_string(key)]
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  # Entries without ids (hand-built packs) dedupe on normalized content.
  defp content_key(raw) do
    content = get(raw, :content) || ""
    "content:" <> String.slice(String.downcase(String.trim(content)), 0, 120)
  end
end
