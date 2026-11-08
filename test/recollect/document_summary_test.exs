defmodule Recollect.DocumentSummaryTest do
  use Recollect.DataCase, async: false

  alias Recollect.Pipeline
  alias Recollect.Schema.Document

  @gist "deploy runbook gist summary"

  # Distinguishes extraction calls (graph JSON) from summarization calls
  # (plain prose) by the system prompt.
  defp fake_llm(messages, _opts) do
    system = hd(messages).content

    if String.contains?(system, "knowledge graph builder") do
      {:ok, ~s({"entities": [], "relations": []})}
    else
      {:ok, @gist}
    end
  end

  defp with_llm(fun) do
    Application.put_env(:recollect, :extraction, llm_fn: &fake_llm/2)

    try do
      fun.()
    after
      Application.delete_env(:recollect, :extraction)
    end
  end

  test "summary + summary_embedding written on ingest when llm_fn configured" do
    with_llm(fn ->
      owner_id = Fixtures.owner_id()
      {:ok, document} = Recollect.ingest("Deploy Runbook", "How the deploy pipeline fits together.", owner_id: owner_id)

      assert {:ok, run} = Pipeline.process(document)
      assert run.status == "complete"

      reloaded = Config.repo().get(Document, document.id)
      assert reloaded.summary == @gist
      assert reloaded.summary_embedding
    end)
  end

  test "gist query surfaces the document's chunks via the summary tier" do
    with_llm(fn ->
      owner_id = Fixtures.owner_id()

      content =
        Enum.map_join(1..5, "\n\n", fn i ->
          "Section #{i}\n\nDeploy step #{i}: detailed operational content paragraph."
        end)

      {:ok, document} = Recollect.ingest("Deploy Runbook", content, owner_id: owner_id)
      assert {:ok, _run} = Pipeline.process(document)

      # min_score above any direct chunk match: only the summary (embedded
      # from the query text itself) clears the bar, so every chunk in the
      # result arrived through the summary tier.
      {:ok, pack} =
        Recollect.search(@gist, owner_id: owner_id, tier: :full, min_score: 0.9)

      assert pack.chunks != []
      assert Enum.all?(pack.chunks, &(&1[:via] == :summary))

      document_bin = Recollect.Util.uuid_to_bin(document.id)
      assert Enum.all?(pack.chunks, &(&1["document_id"] == document_bin))
      assert length(pack.chunks) <= 3
    end)
  end

  test "summarization failure does not fail the pipeline" do
    Application.put_env(:recollect, :extraction, llm_fn: fn _messages, _opts -> {:error, :boom} end)

    try do
      owner_id = Fixtures.owner_id()
      {:ok, document} = Recollect.ingest("Deploy Runbook", "Content that still ingests.", owner_id: owner_id)

      assert {:ok, run} = Pipeline.process(document)
      assert run.status == "complete"

      reloaded = Config.repo().get(Document, document.id)
      assert reloaded.status == "ready"
      assert reloaded.summary == nil
    after
      Application.delete_env(:recollect, :extraction)
    end
  end

  test "degraded mode (no llm_fn) still ingests, summary stays nil" do
    owner_id = Fixtures.owner_id()
    {:ok, document} = Recollect.ingest("Deploy Runbook", "Plain content, no LLM anywhere.", owner_id: owner_id)

    assert {:ok, run} = Pipeline.process(document)
    assert run.status == "complete"

    reloaded = Config.repo().get(Document, document.id)
    assert reloaded.status == "ready"
    assert reloaded.summary == nil
    assert reloaded.summary_embedding == nil
  end
end
