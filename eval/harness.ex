defmodule Recollect.Eval.Harness do
  @moduledoc """
  Memory-on/memory-off eval harness (MEM-034).

  Runs the Q&A fixture set against two retrieval arms and reports
  recall@k, precision@k, and answer-correctness deltas:

    * **memory_off** — lexical-only retrieval (`Recollect.Search.Lexical`),
      the naive-keyword baseline a host would have without the memory pipeline.
    * **memory_on** — full hybrid retrieval (`Recollect.Search.search/2`
      with `mode: :hybrid`), i.e. vector + lexical + graph + recall anchors
      with keyword fallback.

  The delta between the two arms is the measured value of the memory
  pipeline over a naive keyword baseline.

  Ground truth matching uses each result entry's `source_id`, seeded via
  `Recollect.Eval.Fixtures.QA.seed/2` (test env).

  Opt-in: tests are tagged `:eval` so they don't run in default CI.
  """

  alias Recollect.Eval.Fixtures.QA
  alias Recollect.Eval.Metrics

  @doc """
  Run the full eval suite.

  ## Options

  - `:scope_id` — scope to query (required). Seed ground truth first with
    `Recollect.Eval.Fixtures.QA.seed/2` for meaningful recall numbers.
  - `:limit` — per-query result cap (default: 10)

  Returns a map with per-metric results for memory_on and memory_off,
  plus the delta between them.
  """
  def run(opts \\ []) do
    scope_id = Keyword.fetch!(opts, :scope_id)
    limit = Keyword.get(opts, :limit, 10)

    results =
      Enum.map(QA.all(), fn qa ->
        %{
          id: qa.id,
          question: qa.question,
          relevant_ids: qa.relevant_ids,
          expected_answer: qa.expected_answer,
          memory_off: run_query(qa.question, scope_id, limit, :lexical),
          memory_on: run_query(qa.question, scope_id, limit, :hybrid)
        }
      end)

    summarize(results)
  end

  # memory_off = lexical-only baseline; memory_on = full hybrid pipeline.
  defp run_query(question, scope_id, limit, :lexical) do
    case Recollect.Search.Lexical.search(question, scope_id, limit: limit) do
      {:ok, results} -> results_to_fields(results)
      {:error, _} -> %{ids: [], contents: []}
    end
  end

  defp run_query(question, scope_id, limit, :hybrid) do
    case Recollect.search(question, scope_id: scope_id, mode: :hybrid, limit: limit) do
      {:ok, context} -> results_to_fields(context.items)
      {:error, _} -> %{ids: [], contents: []}
    end
  end

  # Result maps may be string-keyed (row_to_map) or atom-keyed (fusion output).
  defp results_to_fields(results) do
    %{
      ids: Enum.map(results, &field(&1, "source_id")),
      contents: Enum.map(results, &field(&1, "content"))
    }
  end

  defp field(item, key) do
    Map.get(item, key) || Map.get(item, String.to_atom(key))
  end

  defp summarize(results) do
    recall_off = Enum.map(results, &Metrics.recall_at_k(&1.relevant_ids, &1.memory_off.ids, 10))
    recall_on = Enum.map(results, &Metrics.recall_at_k(&1.relevant_ids, &1.memory_on.ids, 10))

    precision_off = Enum.map(results, &Metrics.precision_at_k(&1.relevant_ids, &1.memory_off.ids, 10))
    precision_on = Enum.map(results, &Metrics.precision_at_k(&1.relevant_ids, &1.memory_on.ids, 10))

    correctness_off =
      Enum.map(results, fn r ->
        Metrics.answer_correct?(r.expected_answer, r.memory_off.contents)
      end)

    correctness_on =
      Enum.map(results, fn r ->
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

  defp correctness_count(booleans), do: Enum.count(booleans, & &1)
end
