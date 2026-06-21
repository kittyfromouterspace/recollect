defmodule Recollect.Sleep do
  @moduledoc """
  The "sleep" phase: promote working-memory candidates into permanent memory.

  Working memory (`Recollect.WorkingMemory`, Tier 0) is an ephemeral, bounded
  buffer that accumulates raw — possibly noisy — notes during a session or a bulk
  ingest. Long-term knowledge lives in permanent memory (`recollect_entries`,
  embedded + decayable). This module is the bridge the two layers were missing:
  it reads working memory, **distills** it down to high-signal, durable memories,
  writes the survivors to permanent memory, and flushes the buffer.

  Distillation strategy (first that applies):

    1. `:distiller` option — `fn candidates, opts -> [item]` supplied by the host.
    2. LLM distiller — when `use_llm: true` (default) and an `llm_fn` is configured
       under `config :recollect, :extraction`. Asks the model to keep only durable
       lessons/decisions/gotchas and drop transient chatter.
    3. Heuristic — importance threshold + text-overlap dedup. Always available,
       no LLM required (used in tests and when the LLM call fails).

  A promoted `item` is a map with `:content` (required) and optional `:tags`,
  `:metadata`, `:confidence`, `:entry_type`.
  """

  alias Recollect.Config
  alias Recollect.Knowledge
  alias Recollect.Util
  alias Recollect.WorkingMemory

  require Logger

  @default_importance_threshold 0.0
  @default_merge_threshold 0.5
  @default_half_life_days 14.0
  @default_confidence 0.8

  @distill_prompt """
  You are the "sleep" consolidation step of a long-term memory system. You are
  given raw notes captured during a coding session. Keep ONLY durable, reusable
  knowledge: decisions, gotchas, traps, conventions, and facts that will still
  matter in future sessions. Drop transient chatter, one-off prompts, status
  updates, and anything specific to a single moment.

  Rewrite each survivor as a single concise, self-contained statement. Merge
  near-duplicates into one. It is correct to return fewer items than you were
  given — or an empty list if nothing is durable.

  Respond with ONLY a JSON array, each element:
    {"content": "the durable memory", "tags": ["optional", "tags"]}
  """

  @doc """
  Promote a scope's working memory into permanent memory.

  ## Options
    * `:scope_id` (required)
    * `:owner_id`
    * `:distiller` — `fn candidates, opts -> [item]`; overrides the built-in distiller
    * `:use_llm` — default `true`; use the configured LLM distiller when available
    * `:importance_threshold` — heuristic: min importance to keep (default `0.0`)
    * `:merge_threshold` — heuristic: text-overlap dedup threshold (default `0.5`)
    * `:half_life_days` — half-life for promoted entries (default `14.0`)
    * `:confidence` — confidence for promoted entries (default `0.8`)
    * `:tags`, `:metadata` — merged onto every promoted entry
    * `:dry_run` — distill and return counts, but write nothing and do not flush

  Returns `{:ok, %{candidates, distilled, promoted, flushed}}`.
  """
  def promote(opts) do
    scope_id = Keyword.fetch!(opts, :scope_id)
    dry_run = Keyword.get(opts, :dry_run, false)

    {:ok, candidates} = WorkingMemory.read(scope_id)
    distilled = distill(candidates, opts)

    promoted =
      if dry_run do
        []
      else
        Enum.flat_map(distilled, fn item ->
          case persist(item, scope_id, opts) do
            {:ok, entry} ->
              [entry]

            {:error, reason} ->
              Logger.warning("Recollect.Sleep: failed to promote a memory: #{inspect(reason)}")
              []
          end
        end)
      end

    flushed =
      if dry_run do
        0
      else
        {:ok, n} = WorkingMemory.clear(scope_id)
        n
      end

    {:ok,
     %{
       candidates: length(candidates),
       distilled: length(distilled),
       promoted: length(promoted),
       flushed: flushed
     }}
  end

  @doc """
  Distill working-memory candidates into a list of high-signal items, without
  persisting. Exposed for inspection/tests; `promote/1` calls it.
  """
  def distill([], _opts), do: []

  def distill(candidates, opts) do
    cond do
      distiller = Keyword.get(opts, :distiller) ->
        candidates |> distiller.(opts) |> normalize_items()

      Keyword.get(opts, :use_llm, true) && llm_fn() ->
        llm_distill(candidates, opts)

      true ->
        heuristic_distill(candidates, opts)
    end
  end

  defp persist(item, scope_id, opts) do
    metadata =
      item
      |> Map.get(:metadata, %{})
      |> Map.merge(stringify_keys(Keyword.get(opts, :metadata, %{})))
      |> Map.put("consolidated", true)
      |> Map.put("origin", "sleep")

    tags = Enum.uniq(Map.get(item, :tags, []) ++ Keyword.get(opts, :tags, []))

    Knowledge.remember(item.content,
      scope_id: scope_id,
      owner_id: Keyword.get(opts, :owner_id),
      entry_type: Map.get(item, :entry_type, "note"),
      tags: tags,
      metadata: metadata,
      confidence: Map.get(item, :confidence, @default_confidence),
      half_life_days: Keyword.get(opts, :half_life_days, @default_half_life_days),
      source: "system"
    )
  end

  # --- LLM distiller ---

  defp llm_distill(candidates, opts) do
    fun = llm_fn()

    numbered =
      candidates
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {c, i} -> "#{i}. #{c.content}" end)

    messages = [
      %{role: "system", content: @distill_prompt},
      %{role: "user", content: numbered}
    ]

    case fun.(messages, opts) do
      {:ok, content} when is_binary(content) ->
        case parse_json_items(content) do
          {:ok, items} -> normalize_items(items)
          :error -> heuristic_distill(candidates, opts)
        end

      other ->
        Logger.warning("Recollect.Sleep: LLM distill failed (#{inspect(other)}); using heuristic")
        heuristic_distill(candidates, opts)
    end
  end

  defp parse_json_items(content) do
    cleaned =
      content
      |> String.replace(~r/```json\n?/, "")
      |> String.replace(~r/```\n?/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, items} when is_list(items) -> {:ok, items}
      _ -> :error
    end
  end

  # --- Heuristic distiller: importance gate + overlap dedup ---

  defp heuristic_distill(candidates, opts) do
    threshold = Keyword.get(opts, :importance_threshold, @default_importance_threshold)
    merge_threshold = Keyword.get(opts, :merge_threshold, @default_merge_threshold)

    candidates
    |> Enum.filter(fn c -> Map.get(c, :importance, 0.0) >= threshold end)
    |> Enum.sort_by(fn c -> -Map.get(c, :importance, 0.0) end)
    |> dedup_by_overlap(merge_threshold)
    |> Enum.map(fn c ->
      %{
        content: c.content,
        tags: c |> Map.get(:metadata, %{}) |> Map.get("tags", []),
        metadata: Map.get(c, :metadata, %{})
      }
    end)
  end

  defp dedup_by_overlap(candidates, threshold) do
    Enum.reduce(candidates, [], fn candidate, kept ->
      if Enum.any?(kept, fn k -> Util.text_overlap(k.content, candidate.content) >= threshold end) do
        kept
      else
        kept ++ [candidate]
      end
    end)
  end

  # --- shared helpers ---

  defp normalize_items(items) do
    items
    |> Enum.map(&normalize_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_item(item) when is_map(item) do
    content = item[:content] || item["content"]

    if is_binary(content) and String.trim(content) != "" do
      %{
        content: content,
        tags: item[:tags] || item["tags"] || [],
        metadata: stringify_keys(item[:metadata] || item["metadata"] || %{}),
        confidence: item[:confidence] || item["confidence"] || @default_confidence,
        entry_type: item[:entry_type] || item["entry_type"] || "note"
      }
    end
  end

  defp normalize_item(_), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp llm_fn do
    Keyword.get(Config.extraction_opts(), :llm_fn)
  end
end
