defmodule Recollect.MipmapModesTest do
  use Recollect.DataCase, async: false

  import Ecto.Query

  alias Recollect.Embedding.CountingMock
  alias Recollect.Embedding.Mock
  alias Recollect.Mipmap

  setup do
    CountingMock.init_table()

    original_embedding = Application.get_env(:recollect, :embedding)
    original_mipmaps = Application.get_env(:recollect, :mipmaps)

    Application.put_env(:recollect, :embedding,
      provider: CountingMock,
      mock: true
    )

    on_exit(fn ->
      restore_env(:embedding, original_embedding)
      restore_env(:mipmaps, original_mipmaps)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:recollect, key)
  defp restore_env(key, value), do: Application.put_env(:recollect, key, value)

  defp set_mode(mode), do: Application.put_env(:recollect, :mipmaps, mode: mode)

  defp mipmap_count(scope_id) do
    {:ok, %{rows: [[n]]}} =
      Config.repo().query(
        """
          SELECT count(*) FROM recollect_mipmaps mm
          JOIN recollect_entries e ON e.id = mm.entry_id
          WHERE e.scope_id = $1
        """,
        [Recollect.Util.uuid_to_bin(scope_id)]
      )

    n
  end

  defp wait_for(fun, attempts \\ 40)
  defp wait_for(_fun, 0), do: false

  defp wait_for(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      wait_for(fun, attempts - 1)
    end
  end

  describe "mode :off (MEM-009)" do
    test "remember writes no mipmaps and retrieve is a no-op" do
      set_mode(:off)
      scope_id = Fixtures.scope_id()

      {:ok, _entry} =
        Recollect.remember("off-mode memory", owner_id: Fixtures.owner_id(), scope_id: scope_id)

      Process.sleep(200)
      assert mipmap_count(scope_id) == 0

      assert {:ok, [], :off} = Mipmap.retrieve("off-mode", scope_id)
    end
  end

  describe "mode :lazy" do
    test "remember writes no mipmaps; first retrieval backfills, second reuses" do
      set_mode(:lazy)
      scope_id = Fixtures.scope_id()

      {:ok, entry} =
        Recollect.remember("lazy-mode memory about billing retries",
          owner_id: Fixtures.owner_id(),
          scope_id: scope_id
        )

      Process.sleep(200)
      assert mipmap_count(scope_id) == 0

      CountingMock.reset()
      assert {:ok, _results, _level} = Mipmap.retrieve("billing retries", scope_id)
      assert mipmap_count(scope_id) == 4

      after_first = CountingMock.counts()
      # backfill(1 batched generate for 4 levels) + retrieve embed
      assert after_first.texts >= 5

      CountingMock.reset()
      assert {:ok, _results, _level} = Mipmap.retrieve("billing retries", scope_id)
      after_second = CountingMock.counts()
      # second retrieval embeds only the query — no regeneration
      assert after_second.texts == 1
      assert mipmap_count(scope_id) == 4

      assert entry.id
    end
  end

  describe "mode :eager" do
    test "remember persists 4 mipmaps asynchronously" do
      set_mode(:eager)
      scope_id = Fixtures.scope_id()

      {:ok, _entry} =
        Recollect.remember("eager-mode memory", owner_id: Fixtures.owner_id(), scope_id: scope_id)

      assert wait_for(fn -> mipmap_count(scope_id) == 4 end)
    end
  end

  describe "batching" do
    test "persist embeds all four levels in ONE provider call" do
      set_mode(:off)
      entry = Fixtures.entry(content: "batch me: deploys run at 16:00 UTC on weekdays")

      CountingMock.reset()
      assert {:ok, 4} = Mipmap.persist(entry, ["deploys"])

      counts = CountingMock.counts()
      assert counts.generate == 1
      assert counts.embed == 0
      assert counts.texts == 4
    end

    test "retrieve with query_embedding makes zero embedding calls" do
      set_mode(:off)
      entry = Fixtures.entry(content: "pre-embedded retrieve target")
      assert {:ok, 4} = Mipmap.persist(entry, [])

      {:ok, embedding} = Mock.embed("retrieve target", [])

      CountingMock.reset()

      assert {:ok, _results, _level} =
               Mipmap.retrieve("retrieve target", entry.scope_id, query_embedding: embedding)

      assert CountingMock.counts().texts == 0
    end

    test "archived entries' mipmaps are excluded" do
      set_mode(:off)
      entry = Fixtures.entry(content: "archived mipmap source")
      assert {:ok, 4} = Mipmap.persist(entry, [])

      {:ok, embedding} = Mock.embed("archived mipmap source", [])

      # archive the entry
      entry
      |> Ecto.Changeset.change(entry_type: "archived")
      |> Config.repo().update!()

      assert {:ok, results, _level} =
               Mipmap.retrieve("archived mipmap source", entry.scope_id,
                 query_embedding: embedding,
                 level: :full
               )

      assert results == []
    end
  end
end
