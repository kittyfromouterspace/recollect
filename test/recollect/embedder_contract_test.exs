defmodule Recollect.EmbedderContractTest do
  use Recollect.DataCase, async: false

  # MEM-035: enrichment is best-effort and commit-first. remember/2 must
  # return {:ok, entry} once the row is committed — a disabled embedding
  # provider is a skip, not a throw(:disabled) that escapes the caller.

  alias Recollect.Embedding.Mock

  setup do
    original = Application.get_env(:recollect, :embedding)

    on_exit(fn ->
      if original == nil do
        Application.delete_env(:recollect, :embedding)
      else
        Application.put_env(:recollect, :embedding, original)
      end
    end)

    :ok
  end

  test "remember/2 with embeddings disabled returns {:ok, entry} and does not throw" do
    Application.put_env(:recollect, :embedding,
      provider: Mock,
      credentials_fn: fn -> :disabled end
    )

    refute Recollect.Config.embedding_enabled?()

    result =
      Recollect.remember("Stored even with embeddings disabled.",
        owner_id: Fixtures.owner_id(),
        scope_id: Fixtures.scope_id()
      )

    assert {:ok, entry} = result
    assert entry.content == "Stored even with embeddings disabled."
    assert entry.embedding == nil
  end

  test "skipping enrichment emits telemetry instead of throwing" do
    Application.put_env(:recollect, :embedding,
      provider: Mock,
      credentials_fn: fn -> :disabled end
    )

    test_pid = self()

    :telemetry.attach(
      "embed-skipped-test",
      [:recollect, :embed, :skipped],
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:skipped, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("embed-skipped-test") end)

    {:ok, _entry} =
      Recollect.remember("Telemetry on skip",
        owner_id: Fixtures.owner_id(),
        scope_id: Fixtures.scope_id()
      )

    assert_receive {:skipped, %{count: 1}, %{reason: :disabled}}, 1_000
  end

  test "config functions survive nil embedding/extraction config" do
    Application.put_env(:recollect, :embedding, nil)
    Application.put_env(:recollect, :extraction, nil)

    on_exit(fn ->
      Application.delete_env(:recollect, :extraction)
    end)

    assert Recollect.Config.embedding_provider() == nil
    assert Recollect.Config.embedding_credentials() == :disabled
    assert Recollect.Config.embedding_enabled?() == false
    assert Recollect.Config.extraction_provider() == Recollect.Extraction.LlmJson
    assert Recollect.Config.extraction_opts() == []
    assert Recollect.Config.extraction_enabled?() == false
  end
end
