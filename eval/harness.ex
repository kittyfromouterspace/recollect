defmodule Recollect.Eval.Harness do
  @moduledoc """
  Memory-on/memory-off eval harness (MEM-034).

  Runs Q&A queries against search with memory on and off, computing
  recall@k, precision@k, and answer correctness deltas.

  Opt-in: tagged `:eval` so it doesn't run in default CI.
  """

  alias Recollect.Eval.Fixtures.QA
  alias Recollect.Eval.Metrics

  @doc """
  Run the full eval suite.

  Returns a map with per-metric results for memory_on and memory_off,
  plus the delta between them.
  """
  def run(opts \\ []) do
    qa_pairs = QA.all()
    results = Enum.map(qa_pairs, fn qa ->
      %{
        id: qa.id,
        question: qa.question,
        relevant_ids: qa.relevant_ids,
        expected_answer: qa.expected_answer,
        memory_off: run_query(qa.question, memory_on: false),
        memory_on: run_query(qa.question, memory_on: true)
      }
    end)

    summarize(results)
  end

  @doc "Run a single query and return result IDs and contents."
  defp run_query(question, memory_on: memory_on) do
    # Use Search.search to retrieve results for the question
    case Recollect.search(question, mode: :hybrid, limit: 10) do
      {:ok, context} ->
        result_ids = Enum.map(context.items, & &1.id)
        result_contents = Enum.map(context.items, & &1.content)
        %{ids: result_ids, contents: result_contents}

      {:error, _} ->
        %{ids: [], contents: []}
    end
  end

  defp summarize(results) do
    recall_off = Enum.map(results, & Metrics.recall_at_k(&1.relevant_ids, &1.memory_off.ids, 10))
    recall_on = Enum.map(results, & Metrics.recall_at_k(&1.relevant_ids, &1.memory_on.ids, 10))

    precision_off = Enum.map(results, & Metrics.precision_at_k(&1.relevant_ids, &1.memory_off.ids, 10))
    precision_on = Enum.map(results, & Metrics.precision_at_k(&1.relevant_ids, &1.memory_on.ids, 10))

    correctness_off = Enum.map(results, fn r ->
      Metrics.answer_correct?(r.expected_answer, r.memory_off.contents)
    end)
    correctness_on = Enum.map(results, fn r ->
      Metrics.answer_correct?(r.expected_answer, r.memory_on.contents)
    end)

    %{
      count: length(results),
      memory_off: %{
        recall_at_10: Metrics.mean(recall_off),
        precision_at_10: Metrics.mean(precision_off),
        answer_correct_rate: correctness_count(correctness_off) / length(results)
      },
      memory_on: %{
        recall_at_10: Metrics.mean(recall_on),
        precision_at_10: Metrics.mean(precision_on),
        answer_correct_rate: correctness_count(correctness_on) / length(results)
      },
      delta: %{
        recall_at_10: Metrics.mean(recall_on) - Metrics.mean(recall_off),
        precision_at_10: Metrics.mean(precision_on) - Metrics.mean(precision_off),
        answer_correct_rate: (correctness_count(correctness_on) - correctness_count(correctness_off)) / length(results)
      }
    }
  end

  defp correctness_count(booleans), do: Enum.count(booleans, &(&1))
end