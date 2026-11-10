defmodule Recollect.EvalTest do
  use Recollect.DataCase, async: false

  alias Recollect.Eval.Fixtures.QA
  alias Recollect.Eval.Harness
  alias Recollect.Eval.Metrics

  describe "QA fixtures" do
    test "has Q&A pairs with relevant IDs" do
      qa_pairs = QA.all()
      assert length(qa_pairs) > 0

      qa_pairs
      |> hd()
      |> then(fn qa ->
        assert is_binary(qa.question)
        assert is_list(qa.relevant_ids)
        assert is_binary(qa.expected_answer)
      end)
    end
  end

  describe "Metrics" do
    test "recall_at_k returns 1.0 when all relevant found" do
      assert Metrics.recall_at_k(["1", "2"], ["1", "2", "3"], 10) == 1.0
    end

    test "recall_at_k returns 0.0 when none found" do
      assert Metrics.recall_at_k(["1", "2"], ["3", "4", "5"], 10) == 0.0
    end

    test "recall_at_k partial credit" do
      assert Metrics.recall_at_k(["1", "2", "3"], ["1", "4"], 10) == 1.0 / 3.0
    end

    test "recall_at_k respects k cutoff" do
      assert Metrics.recall_at_k(["1", "2"], ["2", "3", "1"], 1) == 0.5
    end

    test "recall_at_k empty relevant returns 1.0" do
      assert Metrics.recall_at_k([], ["1", "2"], 10) == 1.0
    end

    test "precision_at_k returns 1.0 when all retrieved relevant" do
      assert Metrics.precision_at_k(["1", "2"], ["1", "2"], 10) == 1.0
    end

    test "precision_at_k returns 0.0 when none relevant" do
      assert Metrics.precision_at_k(["1", "2"], ["3", "4"], 10) == 0.0
    end

    test "answer_correct? finds substring" do
      assert Metrics.answer_correct?("deploy", ["The deploy script is deploy.sh"])
    end

    test "answer_correct? no match" do
      refute Metrics.answer_correct?("deploy", ["The script runs migrations"])
    end

    test "mean of empty list is 0.0" do
      assert Metrics.mean([]) == 0.0
    end

    test "mean of numbers" do
      assert Metrics.mean([1.0, 2.0, 3.0]) == 2.0
    end
  end

  describe "Harness" do
    setup do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()
      QA.seed(scope_id, owner_id)
      {:ok, scope_id: scope_id, owner_id: owner_id}
    end

    test "run returns baseline structure", %{scope_id: scope_id} do
      result = Harness.run(scope_id: scope_id)

      assert is_map(result)
      assert is_integer(result.count)
      assert result.count > 0
      assert is_map(result.memory_off)
      assert is_map(result.memory_on)
      assert is_map(result.delta)
      assert is_number(result.delta.recall_at_10)
      assert is_number(result.delta.precision_at_10)
    end

    test "seeded ground truth yields non-zero recall on at least one arm", %{scope_id: scope_id} do
      result = Harness.run(scope_id: scope_id)

      # With ground-truth entries seeded, the hybrid arm should retrieve
      # some of them (keyword fallback works without embeddings).
      assert result.memory_on.recall_at_10 > 0.0
      # Answer correctness should be non-zero on the hybrid arm too.
      assert result.memory_on.answer_correct_rate > 0.0
    end
  end
end
