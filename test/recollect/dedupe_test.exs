defmodule Recollect.DedupeTest do
  use Recollect.DataCase, async: false

  alias Recollect.Knowledge
  alias Recollect.Learning.Pipeline

  defp remember(content, opts) do
    Recollect.remember(
      content,
      Keyword.merge([owner_id: Fixtures.owner_id(), scope_id: Fixtures.scope_id()], opts)
    )
  end

  describe "remember/2 :dedupe (MEM-012)" do
    test "same (source, source_id) twice stores one entry by default" do
      assert {:ok, first} =
               remember("harvested note v1", source: "system", source_id: "agent:session:abc")

      assert {:ok, second} =
               remember("harvested note v1", source: "system", source_id: "agent:session:abc")

      assert first.id == second.id
    end

    test "dedupe: :error returns {:error, :duplicate}" do
      {:ok, _} = remember("original", source: "system", source_id: "git:commit:1")

      assert {:error, :duplicate} =
               remember("changed", source: "system", source_id: "git:commit:1", dedupe: :error)
    end

    test "dedupe: :update refreshes content and tags of the existing entry" do
      {:ok, first} =
        remember("old content", source: "system", source_id: "git:commit:2", tags: ["old"])

      {:ok, updated} =
        remember("new content",
          source: "system",
          source_id: "git:commit:2",
          tags: ["new"],
          dedupe: :update
        )

      assert updated.id == first.id
      assert updated.content == "new content"
      assert Knowledge.tags(first.id) == ["new"]
    end

    test "entries without source_id are never deduped" do
      {:ok, a} = remember("same content", [])
      {:ok, b} = remember("same content", [])
      assert a.id != b.id
    end

    test "concurrent remembers with the same source_id: one wins, nobody raises" do
      results =
        1..5
        |> Task.async_stream(
          fn i ->
            remember("concurrent note #{i}", source: "system", source_id: "agent:race:1")
          end,
          max_concurrency: 5
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))

      {:ok, %{rows: [[count]]}} =
        Config.repo().query(
          "SELECT count(*) FROM recollect_entries WHERE source = 'system' AND source_id = 'agent:race:1'",
          []
        )

      assert count == 1
    end
  end

  describe "parse_since/1 (MEM-012)" do
    alias Recollect.Learner.CodingAgent.Util

    test "DateTime passes through" do
      dt = DateTime.utc_now()
      assert Util.parse_since(dt) == dt
    end

    test "ISO8601 string parses" do
      assert %DateTime{year: 2026, month: 1} = Util.parse_since("2026-01-15T00:00:00Z")
    end

    test "relative strings parse" do
      dt = Util.parse_since("7 days ago")
      assert %DateTime{} = dt
      assert DateTime.diff(DateTime.utc_now(), dt, :day) in 6..8

      assert %DateTime{} = Util.parse_since("30 minutes ago")
      assert %DateTime{} = Util.parse_since("2 weeks ago")
    end

    test "nil and garbage yield no filter" do
      assert Util.parse_since(nil) == nil
      assert Util.parse_since("whenever") == nil
    end
  end

  describe "pipeline idempotency (MEM-012)" do
    test "a second learning run over the same window learns nothing new" do
      scope_id = Fixtures.scope_id()

      {:ok, first} = Pipeline.run(scope_id: scope_id, since: "30 days ago")
      {:ok, second} = Pipeline.run(scope_id: scope_id, since: "30 days ago")

      learned_first = first.results |> Map.values() |> Enum.map(& &1[:learned]) |> Enum.sum()
      learned_second = second.results |> Map.values() |> Enum.map(& &1[:learned]) |> Enum.sum()

      assert learned_first > 0
      assert learned_second == 0
    end
  end
end
