defmodule Recollect.ContextCacheTest do
  use Recollect.DataCase, async: false

  alias Recollect.Context.Detector

  setup do
    # The detect cache lives in :persistent_term — process-global, not
    # sandboxed. Cold cache per test so detection counts are deterministic.
    Detector.clear_cache()

    original = Application.get_env(:recollect, :context_detection)

    on_exit(fn ->
      if original == nil do
        Application.delete_env(:recollect, :context_detection)
      else
        Application.put_env(:recollect, :context_detection, original)
      end
    end)

    :ok
  end

  defp count_detects(fun) do
    test_pid = self()
    handler_id = "detect-count-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:recollect, :context, :detect, :stop],
      fn _event, _measurements, _metadata, _ -> send(test_pid, :detected) end,
      nil
    )

    fun.()

    :telemetry.detach(handler_id)

    receive_detects(0)
  end

  defp receive_detects(count) do
    receive do
      :detected -> receive_detects(count + 1)
    after
      100 -> count
    end
  end

  test "two detect_cached calls within the TTL run the detectors once" do
    count =
      count_detects(fn ->
        Detector.detect_cached()
        Detector.detect_cached()
        Detector.detect_cached()
      end)

    assert count == 1
  end

  test "ttl_ms: 0 disables the cache" do
    count =
      count_detects(fn ->
        Detector.detect_cached(ttl_ms: 0)
        Detector.detect_cached(ttl_ms: 0)
      end)

    assert count == 2
  end

  test "mode :none skips detection entirely" do
    Application.put_env(:recollect, :context_detection, mode: :none)

    count =
      count_detects(fn ->
        assert Detector.resolve_context([]) == %{}
      end)

    assert count == 0
  end

  test "remember context: :none stores no hints and runs no detection" do
    count =
      count_detects(fn ->
        {:ok, entry} =
          Recollect.remember("no context please",
            owner_id: Fixtures.owner_id(),
            scope_id: Fixtures.scope_id(),
            context: :none
          )

        assert entry.context_hints == %{}
      end)

    assert count == 0
  end

  test "an explicit context map is used verbatim" do
    {:ok, entry} =
      Recollect.remember("explicit context",
        owner_id: Fixtures.owner_id(),
        scope_id: Fixtures.scope_id(),
        context: %{repo: "acme/widgets", branch: "main"}
      )

    assert entry.context_hints == %{repo: "acme/widgets", branch: "main"}
  end

  test "deprecated :context_hints still wins over detection" do
    {:ok, entry} =
      Recollect.remember("legacy hints",
        owner_id: Fixtures.owner_id(),
        scope_id: Fixtures.scope_id(),
        context_hints: %{repo: "legacy/repo"}
      )

    assert entry.context_hints == %{repo: "legacy/repo"}
  end
end
