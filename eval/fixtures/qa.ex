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
end