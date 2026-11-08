defmodule Recollect.Brief do
  @moduledoc """
  The budgeted, cited, stable injected-context view — the article's L3
  (MEM-019). A session starts with `Brief.build/2` instead of a search
  dump: a fixed structure of Rules / Focus / Traps / Open questions /
  Index sections, every item cited (`[e12]`, `[h1]`), everything fitted
  to a hard token budget.

  ## Options for `build/2`

  - `:budget` — token cap (default: 1500)
  - `:format` — `:markdown | :text | :json` (default: `:markdown`)
  - `:per_section` — candidate cap per section before budgeting (default: 5)
  - `:workspace` — label shown in the header (default: short scope id)

  ## Cache

  Results are cached per `(scope_id, generation, budget)`. The generation
  counter bumps on every write (`Knowledge.remember/forget/supersede`)
  and on dream runs, so a cached brief can never outlive the facts it
  cites. `invalidate/1` forces the bump explicitly.

  If the budget is too small for even one item, `text` is `""` with
  `truncated: true` — never a partial sentence.
  """

  alias Recollect.Brief.Renderer
  alias Recollect.Brief.Selector
  alias Recollect.Budget
  alias Recollect.Util

  @table :recollect_brief_cache
  @default_budget 1_500

  @doc "Create the cache table (idempotent)."
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])
    end

    :ok
  end

  @doc """
  Build the brief for a scope. Returns `{:ok, brief}` — a map with
  `:text`, `:format`, `:used`, `:budget`, `:truncated`, `:dropped`,
  `:items`, plus the scope/generation bookkeeping.
  """
  def build(scope_id, opts \\ []) do
    init()
    scope_id = Util.uuid_to_string(scope_id)
    budget = Keyword.get(opts, :budget, @default_budget)
    format = Keyword.get(opts, :format, :markdown)

    gen = generation(scope_id)

    brief =
      case cached(scope_id, gen, budget) do
        {:ok, brief} ->
          brief

        :miss ->
          brief =
            Map.merge(
              %{
                scope_id: scope_id,
                scope_label: Keyword.get(opts, :workspace) || short_label(scope_id),
                budget: budget,
                generation: gen
              },
              budgeted_items(scope_id, opts, budget)
            )

          :ets.insert(@table, {{:brief, scope_id, gen, budget}, brief})
          brief
      end

    text = Renderer.render(format, brief)

    {:ok,
     %{
       scope_id: brief.scope_id,
       scope_label: brief.scope_label,
       budget: brief.budget,
       used: brief.used,
       truncated: brief.truncated,
       dropped: brief.dropped,
       items: brief.items,
       generation: brief.generation,
       format: format,
       text: text
     }}
  end

  @doc """
  Re-render an already-built brief in another format (`:markdown`,
  `:text`, `:json`).
  """
  def render(%{} = brief, format) do
    Renderer.render(format, brief)
  end

  @doc """
  Bump the scope's generation, dropping cached briefs. Called on writes
  and dream runs.
  """
  def invalidate(scope_id)

  def invalidate(nil), do: :ok

  def invalidate(scope_id) do
    init()
    scope_id = Util.uuid_to_string(scope_id)
    next = generation(scope_id) + 1
    :ets.insert(@table, {{:generation, scope_id}, next})
    :ets.match_delete(@table, {{:brief, scope_id, :_, :_}, :_})
    :ok
  rescue
    _ -> :ok
  end

  # Private

  defp budgeted_items(scope_id, opts, budget) do
    items = Selector.select(scope_id, opts)
    fit = Budget.fit(items, budget)

    %{
      items: fit.items,
      used: fit.used,
      truncated: fit.truncated,
      dropped: fit.dropped
    }
  end

  defp generation(scope_id) do
    case :ets.lookup(@table, {:generation, scope_id}) do
      [{_, gen}] -> gen
      [] -> 1
    end
  rescue
    _ -> 1
  end

  defp cached(scope_id, gen, budget) do
    case :ets.lookup(@table, {:brief, scope_id, gen, budget}) do
      [{_, brief}] -> {:ok, brief}
      [] -> :miss
    end
  rescue
    _ -> :miss
  end

  defp short_label(scope_id) do
    scope_id
    |> String.split("-")
    |> List.first()
  end
end
