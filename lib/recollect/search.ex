defmodule Recollect.Search do
  @moduledoc """
  Unified search combining vector similarity, graph traversal, edge following,
  lexical search, and recall anchors via Reciprocal Rank Fusion (RRF).

  ## Modes

  - `:vector` — legacy behavior, vector search only (default)
  - `:lexical` — lexical search only
  - `:hybrid` — vector + lexical + graph + recall anchors, fused via RRF

  ## Options
  - `:tier` — `:full`, `:lightweight`, `:both`, or `:auto`
  - `:mode` — `:vector` (default), `:lexical`, or `:hybrid`
  - `:limit` — Max results (default: 10)
  - `:min_score` — Minimum similarity score (default: 0.0)
  - `:include_superseded` — include entries superseded via a `"supersedes"`
    edge (default: false)
  - `:include_pages` — include page results (default: false)
  - `:budget` — token budget for result truncation (default: no budget)
  - `:dedupe` — dedupe results by {kind, id} (default: true in hybrid mode)
  - `:diversity` — max items per entry_type (default: 2); pass `false` to disable
  - `:debug` — include per-source ranks in result metadata
  """
  require Logger

  @diagnostic_words ~w(why how debug trace depends caused broken failing)

  alias Recollect.Page
  alias Recollect.Recall
  alias Recollect.Search.Fusion
  alias Recollect.Search.Graph
  alias Recollect.Search.Vector

  def search(query_text, opts \\ []) do
    tier = Keyword.get(opts, :tier, :both)
    resolved_tier = if tier == :auto, do: resolve_tier(query_text), else: tier
    mode = Keyword.get(opts, :mode, :vector)
    opts = Keyword.put(opts, :tier, resolved_tier)
    opts = Keyword.put(opts, :mode, mode)

    metadata = %{
      tier: resolved_tier,
      mode: mode,
      scope_id: Keyword.get(opts, :scope_id),
      owner_id: Keyword.get(opts, :owner_id)
    }

      Recollect.Telemetry.span([:recollect, :search], metadata, fn -> do_search(query_text, opts) end)
  end

  defp do_search(query_text, opts) do
    hops = Keyword.get(opts, :hops, 1)
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)
    budget = Keyword.get(opts, :budget)
    diversity = Keyword.get(opts, :diversity, 2)
    debug = Keyword.get(opts, :debug, false)
    mode = Keyword.get(opts, :mode, :vector)
    resolved_tier = Keyword.get(opts, :tier, :both)

    # MEM-033: reranker config
    retrieval_cfg = Application.get_env(:recollect, :retrieval, [])
    rerank_enabled = Keyword.get(opts, :rerank, Keyword.get(retrieval_cfg, :rerank, false))
    reranker_module = Keyword.get(opts, :reranker, Keyword.get(retrieval_cfg, :reranker, Recollect.Reranker))
    rerank_max_items = Keyword.get(opts, :rerank_max_items, Keyword.get(retrieval_cfg, :rerank_max_items, 50))

    # Candidate generation: vector search
    {:ok, vector_results} = Vector.search(query_text, opts)

    # Separate by type
    chunks = Enum.filter(vector_results, &(&1[:result_type] == :chunk))
    entries = Enum.filter(vector_results, &(&1[:result_type] == :entry))

    # MEM-021: `anchors: [path: ...]` gives anchored entries a modest
    # score boost and appends anchored entries the vector search missed.
    entries =
      case Keyword.get(opts, :anchors) do
        kw when is_list(kw) ->
          case kw[:path] do
            nil -> entries
            path -> Recall.boost_entries(entries, path, opts[:scope_id])
          end

        _ ->
          entries
      end

      # MEM-030: page search results, deduped against entries by citation
      pages =
        if Keyword.get(opts, :include_pages, false) do
          case Page.search(query_text, opts[:scope_id], limit: limit, min_score: min_score) do
            {:ok, page_results} ->
              # Dedupe pages against entries by citation (slug)
              entry_ids = MapSet.new(entries |> Enum.map(& &1["id"]) |> Enum.reject(&is_nil/1))
              page_results
              |> Enum.reject(fn p -> MapSet.member?(entry_ids, p[:id]) end)
            {:error, _} -> []
          end
        else
          []
        end

      # Candidate sources for fusion
      candidate_sources = [%{source: :vector, results: vector_results}]
      candidate_sources =
        if mode in [:lexical, :hybrid] do
          [%{source: :lexical, results: []} | candidate_sources]
        else
          candidate_sources
        end

      # MEM-021: recall anchors for the current path/symbol
      anchor_results =
        case Keyword.get(opts, :anchors) do
          kw when is_list(kw) ->
            case kw[:path] do
              nil -> []
              path ->
                case Recall.for_path(path, opts[:scope_id], limit: limit) do
                  {:ok, hits} ->
                    Enum.map(hits, fn h ->
                      %{
                        id: h.entry_id,
                        content: h.excerpt || "",
                        entry_type: h.entry_type || "note",
                        score: h.confidence || 0.0,
                        source: :recall_anchor
                      }
                    end)
                  {:error, _} -> []
                end
              end
            _ -> []
        end

      candidate_sources =
        if anchor_results != [] do
          [%{source: :recall_anchor, results: anchor_results} | candidate_sources]
        else
          candidate_sources
        end

      # Graph expansion for Tier 1 entities
      {entities, graph_relations} =
        if resolved_tier?(opts) && Keyword.has_key?(opts, :owner_id) do
          expand_graph(query_text, opts, hops)
        else
          {[], []}
        end

      # Edge following for Tier 2 entries
      related_entries =
        if resolved_tier?(opts) && mode in [:lightweight, :both] do
          entry_ids = entries |> Enum.map(& &1["id"]) |> Enum.reject(&is_nil/1)

          follow_opts = [
            hops: hops,
            include_superseded: Keyword.get(opts, :include_superseded, false)
          ]

          case Graph.follow_edges(entry_ids, follow_opts) do
            {:ok, related} -> related
            _ -> []
          end
        else
          []
        end

      # MEM-032: fuse candidates across sources using RRF
      graph_candidates = []
      all_candidates =
        if mode == :vector do
          # Legacy behavior: vector results only, no fusion
          vector_results
        else
          # Build candidate list for fusion: each source contributes its results
          fusion_sources =
            [%{source: :vector, results: vector_results} | candidate_sources]

          # Add graph entities as a candidate source
          graph_candidates =
            Enum.map(entities, fn e ->
              %{
                id: e["id"] || e[:id],
                content: e["content"] || e[:content] || "",
                entry_type: e["entry_type"] || e[:entry_type] || "entity",
                score: e["score"] || e[:score] || 0.0,
                source: :graph
              }
            end)

          fusion_sources =
            [%{source: :graph, results: graph_candidates} | fusion_sources]

          # Fuse
          {:ok, fusion_result} = Fusion.fuse(fusion_sources, k: 60, diversity: diversity, limit: limit)

          fusion_result.items
        end

        # MEM-033: optional reranker applied to top rerank_max_items before budget
        all_candidates =
          if rerank_enabled do
            {top, rest} = Enum.split(all_candidates, rerank_max_items)
            case reranker_module.rerank(query_text, top, []) do
              {:ok, reranked_top} -> reranked_top ++ rest
              {:error, _reason} -> all_candidates
            end
          else
            all_candidates
          end

        # Apply budget if specified
        final_results =
          if budget do
            # Use Budget.fit for token budget
            budget_result = Recollect.Budget.fit(all_candidates, budget)
            budget_result.items
          else
            all_candidates
          end

      context_pack = %{
        chunks: chunks,
        entries: entries,
        pages: pages,
        related_entries: related_entries,
        entities: entities,
        relations: graph_relations,
        query: query_text,
        resolved_tier: resolved_tier,
        mode: mode,
        items: final_results,
        candidates_considered:
          length(vector_results) + length(anchor_results) + length(graph_candidates)
      }

      # Add debug info if requested
      context_pack =
        if debug do
          Map.put(context_pack, :debug, %{
            vector_count: length(vector_results),
            lexical_candidate_count: length(candidate_sources),
            graph_count: length(graph_candidates),
            anchor_count: length(anchor_results),
            fused_count: length(final_results)
          })
        else
          context_pack
        end

      {:ok, context_pack}
    end

  defp resolved_tier?(opts) do
    Keyword.get(opts, :tier, :both) in [:full, :both]
  end

  @doc """
  Resolve `tier: :auto` to a concrete tier using a word heuristic — no LLM.

  Note the tier semantics: `:full` is documents/graph only and skips Tier-2
  entries, so auto-routing never picks it — diagnostic questions are exactly
  the ones that must not miss past lessons. `:full` stays available for
  callers that explicitly want document/graph-only retrieval.

    - 6 words or fewer and no diagnostic word (`#{Enum.join(@diagnostic_words, ", ")}`,
      case-insensitive) → `:lightweight`
    - anything else (long or diagnostic queries) → `:both`
  """
  def resolve_tier(query_text) when is_binary(query_text) do
    words = query_text |> String.downcase() |> String.split(~r/[^\w]+/, trim: true)
    diagnostic? = Enum.any?(words, &(&1 in @diagnostic_words))

    if not diagnostic? and length(words) <= 6 do
      :lightweight
    else
      :both
    end
  end

  def resolve_tier(_), do: :both

  defp expand_graph(query_text, opts, hops) do
    owner_id = Keyword.fetch!(opts, :owner_id)

    case Vector.search_entities_vec(query_text, owner_id, limit: 5) do
      {:ok, entity_results} ->
        # Expand top 3 entities via graph
        {expanded_entities, expanded_relations} =
          entity_results
          |> Enum.take(3)
          |> Enum.reduce({[], []}, fn entity, {ents, rels} ->
            entity_id = entity["id"]

            if entity_id do
              neighbors =
                case Graph.neighborhood(entity_id, owner_id: owner_id, hops: hops) do
                  {:ok, n} -> n
                  _ -> []
                end

              relations =
                case Graph.relations(entity_id, owner_id: owner_id) do
                  {:ok, r} -> r
                  _ -> []
                end

              {ents ++ neighbors, rels ++ relations}
            else
              {ents, rels}
            end
          end)

        all_entities =
          Enum.uniq_by(entity_results ++ expanded_entities, fn e -> e["id"] || e[:id] end)

        all_relations =
          Enum.uniq_by(expanded_relations, fn r -> {r[:from_id], r[:to_id], r[:relation_type]} end)

        {all_entities, all_relations}

      _ ->
        {[], []}
    end
  end
end