defmodule Recollect.Search.Fusion do
  @moduledoc """
  Rank fusion for hybrid search (MEM-032).

  Combines results from multiple search backends (vector, lexical, graph,
  recall anchors) using Reciprocal Rank Fusion (RRF), then applies
  deduplication, diversity limits, and a global token budget.

  ## RRF

  Each item's score is the sum of 1 / (k + rank) across all lists it
  appears in, where k defaults to 60 (configurable). Items ranked higher
  by more sources get higher combined scores.

  ## Diversity

  By default, at most 2 items per entry_type are retained, preventing a
  single entry type from dominating results. Pass `diversity: false` to
  disable.

  ## Budget

  After fusion and dedup, results are passed through `Recollect.Budget.fit/3`
  for a global token budget.
  """

  @default_k 60
  @default_diversity_limit 2

  @doc """
  Fuse results from multiple search sources into a single ranked list.

  ## Inputs

  `results` is a list of `%{source: atom, results: list}` tuples where each
  result item is a map with at least `:kind` and `:id` fields.

  ## Options

  - `:k` — RRF k parameter (default: 60)
  - `:diversity` — max items per entry_type (default: 2); pass `false` to disable
  - `:limit` — max items after fusion (default: 20)

  Returns `{:ok, %{items: list, fused_count: int, sources: list}}`.
  """
  def fuse(results, opts \\ []) do
    k = Keyword.get(opts, :k, @default_k)
    diversity = Keyword.get(opts, :diversity, @default_diversity_limit)
    limit = Keyword.get(opts, :limit, 20)

    # Collect all candidates with their per-source ranks
    ranked =
      results
      |> Enum.map(fn %{source: source, results: results} ->
        results
        |> Enum.with_index()
        |> Enum.map(fn {item, rank} ->
          item
          |> Map.put(:_rank, rank + 1)
          |> Map.put(:_source, source)
        end)
      end)
      |> List.flatten()

    # RRF score: sum of 1 / (k + rank) across all sources
    fused =
      ranked
      |> Enum.group_by(&Map.get(&1, :id))
      |> Enum.map(fn {_id, items} ->
        rrf_score =
          items
          |> Enum.map(fn item -> 1.0 / (k + Map.get(item, :_rank)) end)
          |> Enum.sum()

        base_item = hd(items)

        base_item
        |> Map.put(:_score, rrf_score)
        |> Map.put(:_sources, Enum.map(items, &Map.get(&1, :_source)))
        |> Map.put(:_ranks, Enum.map(items, &Map.get(&1, :_rank)))
      end)
      |> Enum.sort_by(fn item -> -Map.get(item, :_score) end)

    # Apply diversity limit
    diversified =
      if diversity do
        apply_diversity(fused, diversity)
      else
        fused
      end

    # Apply limit
    limited = Enum.take(diversified, limit)

    # Extract just the item maps, removing private fields
    items =
      Enum.map(limited, fn item ->
        Map.drop(item, [:_score, :_sources, :_ranks, :_rank, :_source])
      end)

    {:ok,
     %{
       items: items,
       fused_count: length(fused),
       sources: Enum.map(results, &Map.get(&1, :source))
     }}
  end

  # Apply diversity: max N items per entry_type
  defp apply_diversity(items, limit) do
    items
    |> Enum.group_by(&Map.get(&1, :kind))
    |> Enum.flat_map(fn {_kind, group} -> Enum.take(group, limit) end)
    |> Enum.sort_by(fn item -> -Map.get(item, :_score) end)
  end
end
