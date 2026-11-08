defmodule Recollect.Budget do
  @moduledoc """
  Greedy token budget fitting (MEM-018).

  Items carry `:estimated_tokens`, plus optional `:priority`, `:score`, and
  `:recency` (DateTime, integer, or nil — higher/newer wins ties). `fit/3`
  ranks them (priority, then score, then recency) and includes items until
  the effective budget is exhausted.

  Two rules make the output safe to render:

  * an item is never sliced — one that doesn't fit is dropped whole;
  * a configurable reserve (default 10%) is held back for the renderer's
    scaffolding (headers, citation markers), so the rendered result stays
    under the caller's cap.

  Smaller items further down the ranking can still fit after a big one is
  dropped — greedy packing continues past a non-fitting item.
  """

  @reserve_fraction 0.1

  @type item :: map()

  @type t :: %{
          items: [item()],
          used: non_neg_integer(),
          budget: non_neg_integer(),
          truncated: boolean(),
          dropped: [item()]
        }

  @doc """
  Fit `items` into `max_tokens`.

  ## Options

  - `:reserve` — fraction of `max_tokens` held back for scaffolding
    (default: 0.1)
  - `:tokens_key` — the item key carrying the token count
    (default: `:estimated_tokens`)

  Kept items are returned in ranked order (priority desc, score desc,
  recency desc) so renderers can emit highest-value first.
  """
  @spec fit([item()], non_neg_integer(), keyword()) :: t()
  def fit(items, max_tokens, opts \\ []) when is_list(items) and is_integer(max_tokens) do
    reserve = Keyword.get(opts, :reserve, @reserve_fraction)
    tokens_key = Keyword.get(opts, :tokens_key, :estimated_tokens)

    budget =
      max_tokens
      |> Kernel.*(1 - reserve)
      |> trunc()
      |> max(0)

    {kept, dropped, used} =
      items
      |> Enum.sort_by(&rank_key/1)
      |> Enum.reduce({[], [], 0}, fn item, {kept, dropped, used} ->
        tokens = item_tokens(item, tokens_key)

        if used + tokens <= budget do
          {[item | kept], dropped, used + tokens}
        else
          {kept, [item | dropped], used}
        end
      end)

    %{
      items: Enum.reverse(kept),
      used: used,
      budget: budget,
      truncated: dropped != [],
      dropped: Enum.reverse(dropped)
    }
  end

  # Priority first, then score, then recency — all descending. Missing
  # fields rank lowest.
  defp rank_key(item) do
    {-priority(item), -score(item), -recency_rank(item)}
  end

  defp priority(%{priority: p}) when is_number(p), do: p
  defp priority(_), do: 0

  defp score(%{score: s}) when is_number(s), do: s
  defp score(_), do: 0.0

  # Recency may be a DateTime, an integer rank, or absent. Normalize to a
  # single comparable integer (unix seconds for DateTimes).
  defp recency_rank(%{recency: %DateTime{} = dt}), do: DateTime.to_unix(dt)
  defp recency_rank(%{recency: r}) when is_integer(r), do: r
  defp recency_rank(_), do: 0

  defp item_tokens(item, tokens_key) do
    case Map.get(item, tokens_key) do
      t when is_integer(t) and t >= 0 ->
        t

      other ->
        raise ArgumentError,
              "Budget.fit items need a non-negative integer #{inspect(tokens_key)}, got: #{inspect(other)}"
    end
  end
end
