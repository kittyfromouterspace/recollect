defmodule Recollect.PipelineQuarantineTest do
  use Recollect.DataCase, async: false

  alias Recollect.Pipeline
  alias Recollect.Schema.Document
  alias Recollect.Schema.PipelineRun

  # A null byte is invalid in a Postgres text column: chunk inserts blow up,
  # do_chunk rescues, and the pipeline run fails — a deterministic failure
  # trigger without touching the pipeline's internals.
  @poison_content "valid intro\n\nwith a poisonous byte: #{<<0>>}"

  defp document_fixture(attrs \\ []) do
    attrs =
      attrs
      |> Keyword.put_new(:owner_id, Fixtures.owner_id())
      |> Keyword.put_new(:content, "test document content")
      |> Keyword.put_new(:content_hash, Recollect.Pipeline.Ingester.hash_content("test document content"))

    Fixtures.document(attrs)
  end

  defp poisoned(document) do
    %{document | content: @poison_content}
  end

  describe "process/2 quarantine" do
    test "refuses quarantined documents immediately" do
      document = document_fixture(status: "quarantined", failed_attempts: 3)

      assert {:error, :quarantined} = Pipeline.process(document)
    end

    test "increments failed_attempts on failure, stays failed below threshold" do
      document = document_fixture()

      assert {:error, _} = Pipeline.process(poisoned(document))

      reloaded = Config.repo().get(Document, document.id)
      assert reloaded.status == "failed"
      assert reloaded.failed_attempts == 1
    end

    test "quarantines at the configured threshold" do
      document = document_fixture(status: "failed", failed_attempts: 2)

      assert {:error, _} = Pipeline.process(poisoned(document))

      reloaded = Config.repo().get(Document, document.id)
      assert reloaded.status == "quarantined"
      assert reloaded.failed_attempts == 3

      # And now the pipeline refuses it outright
      assert {:error, :quarantined} = Pipeline.process(reloaded)
    end

    test "success resets failed_attempts" do
      document = document_fixture(status: "failed", failed_attempts: 2)

      assert {:ok, run} = Pipeline.process(document)
      assert run.status == "complete"

      reloaded = Config.repo().get(Document, document.id)
      assert reloaded.status == "ready"
      assert reloaded.failed_attempts == 0
    end
  end

  describe "retry_quarantined/2" do
    test "resets and reprocesses a quarantined document" do
      document = document_fixture(status: "quarantined", failed_attempts: 3)

      assert {:ok, run} = Pipeline.retry_quarantined(document)
      assert run.status == "complete"

      reloaded = Config.repo().get(Document, document.id)
      assert reloaded.status == "ready"
      assert reloaded.failed_attempts == 0
    end

    test "accepts an id and returns :not_found for unknown documents" do
      assert {:error, :not_found} = Pipeline.retry_quarantined(Ecto.UUID.generate())

      document = document_fixture(status: "quarantined", failed_attempts: 3)
      assert {:ok, _run} = Pipeline.retry_quarantined(document.id)
    end
  end

  describe "health/0" do
    test "returns the health snapshot shape" do
      health = Pipeline.health()

      assert is_float(health.error_rate_24h)
      assert is_integer(health.errored_count_24h)
      assert is_integer(health.completed_count_24h)
      assert is_integer(health.quarantined_count)
      assert is_integer(health.tokens_24h)
      assert is_float(health.cost_24h)
      assert Map.has_key?(health, :oldest_pending_age_seconds)
    end

    test "counts runs, tokens, cost, quarantined and pending documents" do
      owner_id = Fixtures.owner_id()
      collection = Fixtures.collection(owner_id: owner_id)
      document = document_fixture(owner_id: owner_id, collection: collection)

      quarantined =
        document_fixture(owner_id: owner_id, collection: collection, status: "quarantined", failed_attempts: 3)

      insert_run!(document, owner_id, "complete", tokens_used: 100, cost_usd: 1.5)
      insert_run!(document, owner_id, "failed", tokens_used: 50, cost_usd: 0.5)

      health = Pipeline.health()

      assert health.errored_count_24h == 1
      assert health.completed_count_24h == 1
      assert health.error_rate_24h == 0.5
      assert health.tokens_24h == 150
      assert health.cost_24h == 2.0
      assert health.quarantined_count == 1

      # Both fixture documents default to "pending" unless told otherwise
      assert Config.repo().get(Document, document.id).status == "pending"
      assert Config.repo().get(Document, quarantined.id).status == "quarantined"
      assert health.oldest_pending_age_seconds >= 0
    end

    test "oldest_pending_age_seconds is nil with no pending documents" do
      assert Pipeline.health().oldest_pending_age_seconds == nil
    end
  end

  defp insert_run!(document, owner_id, status, attrs) do
    {:ok, run} =
      %PipelineRun{}
      |> PipelineRun.changeset(
        Map.merge(
          %{document_id: document.id, owner_id: owner_id, status: status},
          Map.new(attrs)
        )
      )
      |> Config.repo().insert()

    run
  end
end
