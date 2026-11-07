defmodule Recollect.Strength do
  @moduledoc """
  Memory strength calculation based on hippocampal-inspired mechanics.

  strength(t) = decay_factor × retrieval_boost × emotional_multiplier × confidence

  - Decay: exponential decay based on half-life
  - Retrieval: boost increases with access count
  - Emotional: negative/critical memories encode stronger
  - Pinned memories always return 1.0
  """

  @doc """
  Calculate current strength of an entry at a given time.
  """
  def calculate(%{pinned: true}), do: 1.0

  def calculate(entry, at_time \\ DateTime.utc_now()) do
    decay = decay_factor(entry, at_time)
    retrieval = retrieval_boost(entry)
    emotional = emotional_multiplier(entry)
    confidence = if is_number(entry.confidence), do: entry.confidence * 1.0, else: 1.0

    min(1.0, max(0.0, decay * retrieval * emotional * confidence))
  end

  defp decay_factor(entry, now) do
    last = entry.last_accessed_at || entry.inserted_at || now
    days = max(DateTime.diff(now, last, :second) / 86_400.0, 0.0)

    half_life = normalize_half_life(entry.half_life_days)

    :math.pow(0.5, days / half_life)
  end

  # A nil or non-positive half-life would raise ArithmeticError (division by
  # zero) or produce NaN; fall back to the same 7-day default the schema uses.
  defp normalize_half_life(h) when is_number(h) and h > 0, do: h * 1.0
  defp normalize_half_life(_), do: 7.0

  defp retrieval_boost(%{access_count: count}) when is_integer(count) do
    1 + 0.1 * :math.log2(count + 1)
  end

  defp retrieval_boost(_), do: 1.0

  defp emotional_multiplier(entry) do
    valence = entry.emotional_valence || "neutral"

    multipliers =
      :persistent_term.get({:recollect, :emotional_multipliers}, %{
        "neutral" => 1.0,
        "positive" => 1.3,
        "negative" => 1.5,
        "critical" => 2.0
      })

    Map.get(multipliers, valence, 1.0)
  end

  @doc """
  Calculate half-life adjustment for schema fit (from Enhancement 06).
  """
  def adjust_for_schema_fit(half_life_days, schema_fit) when is_float(schema_fit) do
    cond do
      schema_fit > 0.7 -> half_life_days * 1.5
      schema_fit < 0.3 -> half_life_days * 0.5
      true -> half_life_days
    end
  end
end
