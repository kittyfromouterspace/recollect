defmodule Recollect.Eval.Metrics do
  @moduledoc """
  Evaluation metrics for MEM-034.

  Computes recall@k, precision@k, and answer correctness for eval runs.
  """

  @doc """
  Recall@k: fraction of relevant items found in top-k results.

  relevant_ids: ground truth entry IDs
  result_ids: retrieved entry IDs (top-k)
  k: cutoff
  """
  def recall_at_k(relevant_ids, result_ids, k) do
    relevant = MapSet.new(relevant_ids)
    retrieved = MapSet.new(Enum.take(result_ids, k) |> Enum.map(& &1))

    if MapSet.size(relevant) == 0, do: 1.0, else: MapSet.size(MapSet.intersection(relevant, retrieved)) / MapSet.size(relevant)
  end

  @doc """
  Precision@k: fraction of top-k results that are relevant.

  relevant_ids: ground truth entry IDs
  result_ids: retrieved entry IDs (top-k)
  k: cutoff
  """
  def precision_at_k(relevant_ids, result_ids, k) do
    relevant = MapSet.new(relevant_ids)
    retrieved = MapSet.new(Enum.take(result_ids, k) |> Enum.map(& &1))

    if MapSet.size(retrieved) == 0, do: 0.0, else: MapSet.size(MapSet.intersection(relevant, retrieved)) / MapSet.size(retrieved)
  end

  @doc """
  Answer correctness: checks if expected answer substring appears in results.

  expected_answer: expected answer substring
  result_contents: list of result content strings
  """
  def answer_correct?(expected_answer, result_contents) do
    Enum.any?(result_contents, &String.contains?(&1, expected_answer))
  end

  @doc """
  Mean of a list of numbers.
  """
  def mean(numbers) do
    if length(numbers) == 0, do: 0.0, else: Enum.sum(numbers) / length(numbers)
  end
end