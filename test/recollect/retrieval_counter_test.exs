defmodule Recollect.RetrievalCounterTest do
  use Recollect.DataCase, async: false

  alias Recollect.RetrievalCounter

  describe "flush/0 (MEM-007)" do
    test "200 bumps flush as access_count 200, not 1" do
      entry = Fixtures.entry(content: "retrieved a lot")

      Enum.each(1..200, fn _n -> RetrievalCounter.bump(entry.id) end)
      assert RetrievalCounter.count(entry.id) == 200

      :ok = RetrievalCounter.flush()

      reloaded = Config.repo().reload!(entry)
      assert reloaded.access_count == 200
      assert reloaded.last_accessed_at
      # counts consumed
      assert RetrievalCounter.count(entry.id) == 0
    end

    test "two entries with different counts each land correctly" do
      a = Fixtures.entry(content: "hot entry")
      b = Fixtures.entry(content: "warm entry")

      Enum.each(1..50, fn _n -> RetrievalCounter.bump(a.id) end)
      Enum.each(1..3, fn _n -> RetrievalCounter.bump(b.id) end)

      :ok = RetrievalCounter.flush()

      assert Config.repo().reload!(a).access_count == 50
      assert Config.repo().reload!(b).access_count == 3
    end

    test "half-life boost scales with the count and is capped" do
      entry = Fixtures.entry(content: "boosted", half_life_days: 360.0)

      Enum.each(1..200, fn _n -> RetrievalCounter.bump(entry.id) end)
      :ok = RetrievalCounter.flush()

      reloaded = Config.repo().reload!(entry)
      # 360 + 200 * 2 would be 760; capped at the configured 365
      assert reloaded.half_life_days == 365.0
    end
  end
end
