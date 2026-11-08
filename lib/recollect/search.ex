defmodule Recollect.Search do
  @moduledoc """
  Unified search combining vector similarity, graph traversal, and edge following.
  """

  alias Recollect.Recall
  alias Recollect.Search.Graph
  alias Recollect.Search.Vector

  require Logger

  @diagnostic_words ~w(why how debug trace depends caused broken failing)

  @doc """
  Hybrid search combining vector and graph results.

  Returns `{:ok, context_pack}` with chunks, entries, entities, relations,
  and the `:resolved_tier` actually searched.

  ## Options
  - `:tier` — `:full`, `:lightweight`, `:both`, or `:auto`. `:auto` routes
    heuristically (no LLM): short factual queries → `:lightweight`,
    diagnostic/long queries → `:full`, otherwise `:both`.
  - `:include_superseded` — include entries superseded via a `"supersedes"`
    edge (default: false).
  """
  def search(query_text, opts \\ []) do
    tier = Keyword.get(opts, :tier, :both)
    resolved_tier = if tier == :auto, do: resolve_tier(query_text), else: tier
    opts = Keyword.put(opts, :tier, resolved_tier)

    metadata = %{
      tier: resolved_tier,
      scope_id: Keyword.get(opts, :scope_id),
      owner_id: Keyword.get(opts, :owner_id)
    }

    Recollect.Telemetry.span([:recollect, :search], metadata, fn ->
      hops = Keyword.get(opts, :hops, 1)

      with {:ok, vector_results} <- Vector.search(query_text, opts) do
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

        # Graph expansion for Tier 1 entities
        {entities, graph_relations} =
          if resolved_tier in [:full, :both] && Keyword.has_key?(opts, :owner_id) do
            expand_graph(query_text, opts, hops)
          else
            {[], []}
          end

        # Edge following for Tier 2 entries
        related_entries =
          if resolved_tier in [:lightweight, :both] do
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

        context_pack = %{
          chunks: chunks,
          entries: entries,
          related_entries: related_entries,
          entities: entities,
          relations: graph_relations,
          query: query_text,
          resolved_tier: resolved_tier
        }

        {:ok, context_pack}
      end
    end)
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
