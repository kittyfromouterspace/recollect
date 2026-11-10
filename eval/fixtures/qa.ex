defmodule Recollect.Eval.Fixtures.QA do
  @moduledoc """
  Project Q&A fixture set for MEM-034 eval harness.

  Each entry has a question, a list of relevant entry IDs (ground truth),
  and an expected answer substring. Used to measure recall@k and answer
  correctness across memory-on/memory-off ablations.
  """

  @qa [
    %{
      id: "qa-001",
      question: "What is the deploy script?",
      relevant_ids: ["deploy-script-entry"],
      expected_answer: "deploy.sh"
    },
    %{
      id: "qa-002",
      question: "How do you run database migrations?",
      relevant_ids: ["migration-entry"],
      expected_answer: "migrate"
    },
    %{
      id: "qa-003",
      question: "Who owns the mark_mesh project?",
      relevant_ids: ["project-owner-entry"],
      expected_answer: "owner"
    },
    %{
      id: "qa-004",
      question: "What is the compression ratio for pages?",
      relevant_ids: ["pages-config-entry"],
      expected_answer: "ratio"
    },
    %{
      id: "qa-005",
      question: "Which entities are related to authentication?",
      relevant_ids: ["auth-entity-1", "auth-entity-2"],
      expected_answer: "auth"
    }
  ]

  @doc "All Q&A pairs in the fixture set."
  def all, do: @qa

  @doc "Count of Q&A pairs."
  def count, do: length(@qa)

  @doc """
  Seed the ground-truth entries for this Q&A set (test-only).

  Creates one entry per `relevant_id` in the given scope/owner, with the
  entry's `source_id` set to that id so recall@k can match results back to
  the ground truth. Content includes the question keywords and expected
  answer so both lexical and hybrid retrieval can find it.

  Returns the created entries. Uses `Recollect.Fixtures` (test env only).
  """
  def seed(scope_id, owner_id) do
    Enum.flat_map(all(), fn qa ->
      Enum.map(qa.relevant_ids, fn rid ->
        Recollect.Fixtures.entry(
          scope_id: scope_id,
          owner_id: owner_id,
          content: "#{qa.question} #{qa.expected_answer}",
          source_id: rid
        )
      end)
    end)
  end
end
