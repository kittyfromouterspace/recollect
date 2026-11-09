defmodule Recollect.Dream.Synthesize do
  @moduledoc """
  Dream stage: synthesize cited pages from claim clusters (MEM-028).

  Clustering uses BLOCKING to avoid O(n²): entries group by their primary
  tag first, then only entries within a block are compared (text overlap).
  Clusters need `dream.min_cluster_size` (default 3) claims from at least
  two distinct sources to become a page.

  Page bodies come from an LLM synthesis prompt (`synthesis_fn` override,
  configured extraction llm_fn default) or a deterministic fallback
  template — bullets quoting each claim VERBATIM with `[e:<id>]`
  citations. The page slug is derived from the cluster's stable identity
  (tag + sorted entry ids), so the same cluster updates one page
  incrementally (`source_hash` skips no-op rewrites, `version` bumps on
  body changes) instead of duplicating.

  Gated by `pages.enabled`; emits pages_created / pages_updated /
  clusters_skipped.
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Page
  alias Recollect.Schema.Entry
  alias Recollect.Schema.EntryTag
  alias Recollect.Schema.Page, as: PageRow
  alias Recollect.Schema.PageSource
  alias Recollect.Telemetry
  alias Recollect.Util

  @overlap_threshold 0.3

  def run(scope_id, opts) do
    scope_id = Util.uuid_to_string(scope_id)

    if Config.pages()[:enabled] == false do
      {:ok, %{enabled: false, pages_created: 0, pages_updated: 0, clusters_skipped: 0}}
    else
      Telemetry.span([:recollect, :dream, :synthesize], %{scope_id: scope_id}, fn ->
        {:ok, synthesize(scope_id, opts)}
      end)
    end
  end

  # Private

  defp synthesize(scope_id, opts) do
    repo = Config.repo()
    max_items = Keyword.get(opts, :max_items) || Config.dream()[:max_items] || 500
    min_size = Keyword.get(opts, :min_cluster_size) || Config.dream()[:min_cluster_size] || 3

    entries =
      from(e in Entry, where: e.scope_id == ^scope_id, limit: ^max_items)
      |> Entry.live()
      |> repo.all()

    tags = tags_by_entry(repo, scope_id)

    blocks =
      entries
      |> Enum.filter(&(Map.has_key?(tags, &1.id) and tags[&1.id] != []))
      |> Enum.group_by(fn e -> hd(Enum.sort(tags[e.id])) end)

    metrics =
      Enum.reduce(blocks, %{pages_created: 0, pages_updated: 0, clusters_skipped: 0}, fn {tag, block_entries}, acc ->
        block_entries
        |> cluster_by_overlap()
        |> Enum.reduce(acc, fn cluster, acc ->
          cond do
            length(cluster) < min_size ->
              Map.update(acc, :clusters_skipped, 1, &(&1 + 1))

            distinct_sources(cluster) < 2 ->
              Map.update(acc, :clusters_skipped, 1, &(&1 + 1))

            true ->
              write_cluster_page(scope_id, owner_id(opts), tag, cluster, opts, acc)
          end
        end)
      end)

    %{
      enabled: true,
      pages_created: metrics.pages_created,
      pages_updated: metrics.pages_updated,
      clusters_skipped: metrics.clusters_skipped
    }
  end

  defp owner_id(opts), do: opts[:owner_id]

  # Greedy overlap clustering within a tag block: a claim joins the first
  # cluster it overlaps; otherwise it opens a new one.
  defp cluster_by_overlap(entries) do
    Enum.reduce(entries, [], fn entry, clusters ->
      idx =
        Enum.find_index(clusters, fn cluster ->
          Enum.any?(cluster, fn member ->
            Util.text_overlap(member.content, entry.content) >= @overlap_threshold
          end)
        end)

      if idx do
        List.update_at(clusters, idx, &[entry | &1])
      else
        clusters ++ [[entry]]
      end
    end)
  end

  defp distinct_sources(cluster) do
    cluster |> Enum.map(& &1.source) |> Enum.uniq() |> length()
  end

  defp write_cluster_page(scope_id, owner_id, tag, cluster, opts, acc) do
    entries = Enum.sort_by(cluster, & &1.inserted_at)
    ids = Enum.map(entries, & &1.id)
    slug = cluster_slug(tag, ids)
    new_hash = cluster_hash(ids)
    existing = Config.repo().get_by(PageRow, slug: slug, scope_id: scope_id)

    cond do
      existing && existing.source_hash == new_hash ->
        # the cluster's membership hasn't changed — nothing to rewrite
        acc

      existing ->
        # incremental: cite the union, regenerate the body, bump version
        cited_ids = page_cited_entry_ids(existing.id)
        all_entries = merge_cited(entries, cited_ids)

        body = body_for(tag, all_entries, opts)

        {:ok, _} = Page.update(existing.id, body_md: body, summary: summary_line(tag, length(all_entries)))

        ensure_sources(existing.id, all_entries)

        Config.repo().update_all(
          from(p in PageRow, where: p.id == ^existing.id),
          set: [source_hash: new_hash]
        )

        Map.update(acc, :pages_updated, 1, &(&1 + 1))

      is_nil(existing) ->
        body = body_for(tag, entries, opts)

        attrs = [
          owner_id: owner_id || scope_id,
          scope_id: scope_id,
          slug: slug,
          title: String.capitalize(tag) <> " — synthesized",
          kind: "topic",
          body_md: body,
          summary: summary_line(tag, length(entries)),
          source_hash: new_hash
        ]

        sources = Enum.map(entries, fn e -> %{source_type: "entry", entry_id: e.id, role: "supporting"} end)

        case Page.create(attrs, sources) do
          {:ok, _page} ->
            Map.update(acc, :pages_created, 1, &(&1 + 1))

          {:error, _changeset_or_reason} ->
            # lost a slug race to a concurrent synthesizer — the other
            # writer's page is the canonical one
            Map.update(acc, :clusters_skipped, 1, &(&1 + 1))
        end
    end
  end

  # Deterministic fallback (always): verbatim bullets with [e:<id>]
  # citations. When an LLM is available its synthesis goes on top, but the
  # quoted claims stay — critical evidence is never paraphrased away.
  defp body_for(tag, entries, opts) do
    bullets =
      Enum.map_join(entries, "\n", fn e -> "- #{e.content} [e:#{e.id}]" end)

    llm_part =
      if synthesis_fn = opts[:synthesis_fn] || Config.extraction_opts()[:llm_fn] do
        llm_synthesis(synthesis_fn, tag, entries)
      end

    header = "# #{String.capitalize(tag)} — synthesized\n"

    intro =
      if llm_part,
        do: llm_part <> "\n\n",
        else: ""

    header <> "\n" <> intro <> "## Cited claims\n\n" <> bullets <> "\n"
  end

  defp llm_synthesis(llm_fn, tag, entries) do
    numbered =
      entries
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {e, i} -> "#{i}. (e:#{e.id}) #{e.content}" end)

    messages = [
      {:system,
       "Synthesize the claims below into 2-3 sentences of markdown. Cite each claim inline as [e:<id>] " <>
         "exactly as given. Do not invent claims."},
      {:user, "Tag: #{tag}\n\n#{numbered}"}
    ]

    llm_opts = Keyword.put(Config.extraction_opts(), :max_tokens, 300)

    messages
    |> llm_fn.(llm_opts)
    |> case do
      {:ok, text} when is_binary(text) and text != "" -> String.trim(text)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp summary_line(tag, count), do: "Synthesized from #{count} #{tag} claims."

  # The slug keys on the TAG BLOCK — the stable blocking identity — so a
  # growing cluster updates the same page instead of spawning a new one.
  defp cluster_slug(tag, _ids) do
    "cluster/#{String.replace(tag, "/", "-")}"
  end

  defp cluster_hash(ids) do
    :sha256
    |> :crypto.hash(Enum.join(Enum.sort(ids), "|"))
    |> Base.encode16(case: :lower)
  end

  defp page_cited_entry_ids(page_id) do
    Config.repo().all(
      from(s in PageSource,
        where: s.page_id == ^page_id and not is_nil(s.entry_id),
        select: s.entry_id
      )
    )
  end

  # Cite the union of old + new cluster members so incremental updates
  # never drop existing citations.
  defp merge_cited(entries, cited_ids) do
    known = MapSet.new(Enum.map(entries, & &1.id))

    previously_cited =
      cited_ids
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.map(&Config.repo().get(Entry, &1))
      |> Enum.reject(&is_nil/1)

    entries ++ previously_cited
  end

  defp ensure_sources(page_id, entries) do
    existing =
      from(s in PageSource,
        where: s.page_id == ^page_id and not is_nil(s.entry_id),
        select: s.entry_id
      )
      |> Config.repo().all()
      |> MapSet.new()

    missing = Enum.reject(entries, &MapSet.member?(existing, &1.id))

    Enum.each(missing, fn e ->
      %PageSource{}
      |> PageSource.changeset(%{
        page_id: page_id,
        entry_id: e.id,
        source_type: "entry",
        role: "supporting",
        created_at: DateTime.utc_now()
      })
      |> Config.repo().insert(on_conflict: :nothing)
    end)

    :ok
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
    |> Map.new(fn {id, tags} -> {id, Enum.sort(tags)} end)
  end
end
