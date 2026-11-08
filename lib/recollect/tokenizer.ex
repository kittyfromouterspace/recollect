defmodule Recollect.Tokenizer do
  @moduledoc """
  Token estimation shared by every budget-aware consumer (MEM-018).

  The default model is the cheap `ceil(chars / 4)` heuristic — good enough
  for budgeting. Hosts that need exact counts can plug a real tokenizer via
  `config :recollect, tokenizer_fn: &MyTokenizer.count/1`. Whatever is
  configured, every module budgets through THIS module so the injected
  layer shares one token model.
  """

  alias Recollect.Config

  @doc """
  Estimated token count for `text` (0 for nil/empty).

  Deterministic: the same text always estimates the same, under the same
  configuration.
  """
  def estimate(text)

  def estimate(nil), do: 0

  def estimate(text) when is_binary(text) do
    case Config.tokenizer_fn() do
      fun when is_function(fun, 1) -> fun.(text)
      _ -> default_estimate(text)
    end
  end

  def estimate(_other), do: 0

  @doc "The cheap default model: `ceil(String.length(text) / 4)`."
  def default_estimate(text) when is_binary(text) do
    text
    |> String.length()
    |> ceil_div4()
  end

  @doc "Estimate a list of texts, in order."
  @spec estimate_many([binary()]) :: [non_neg_integer()]
  def estimate_many(texts) when is_list(texts) do
    Enum.map(texts, &estimate/1)
  end

  defp ceil_div4(0), do: 0
  defp ceil_div4(n), do: div(n + 3, 4)
end
