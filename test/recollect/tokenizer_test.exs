defmodule Recollect.TokenizerTest do
  use ExUnit.Case, async: false

  alias Recollect.Budget
  alias Recollect.Tokenizer

  describe "estimate/1 (MEM-018)" do
    test "default model is ceil(chars / 4) and is deterministic" do
      assert Tokenizer.estimate("") == 0
      assert Tokenizer.estimate("abcd") == 1
      assert Tokenizer.estimate("abc") == 1
      assert Tokenizer.estimate("abcdefghi") == 3

      text = String.duplicate("word ", 100)
      assert Tokenizer.estimate(text) == Tokenizer.estimate(text)
      assert Tokenizer.estimate(text) == 125
    end

    test "nil and non-binaries estimate to zero" do
      assert Tokenizer.estimate(nil) == 0
      assert Tokenizer.estimate(42) == 0
    end

    test "a configured tokenizer_fn replaces the default model" do
      previous = Application.get_env(:recollect, :tokenizer_fn)
      Application.put_env(:recollect, :tokenizer_fn, fn _text -> 7 end)

      try do
        assert Tokenizer.estimate("anything") == 7
        assert Tokenizer.estimate_many(["a", "b"]) == [7, 7]
      after
        if previous,
          do: Application.put_env(:recollect, :tokenizer_fn, previous),
          else: Application.delete_env(:recollect, :tokenizer_fn)
      end
    end

    test "estimate_many maps in order" do
      assert Tokenizer.estimate_many(["", "abcd", "abcdefghi"]) == [0, 1, 3]
    end
  end

  describe "Budget.fit/3 (MEM-018)" do
    defp item(id, tokens, opts \\ []) do
      %{
        id: id,
        estimated_tokens: tokens,
        priority: Keyword.get(opts, :priority, 0),
        score: Keyword.get(opts, :score, 0.0),
        recency: Keyword.get(opts, :recency)
      }
    end

    test "never exceeds the effective budget (after reserve)" do
      items = for i <- 1..20, do: item("i#{i}", 50)

      result = Budget.fit(items, 500)

      # reserve 10% -> budget 450
      assert result.budget == 450
      assert result.used <= 450
      assert result.truncated == true
      assert length(result.items) == 9
      assert length(result.dropped) == 11
    end

    test "everything fits when under budget" do
      items = [item("a", 10), item("b", 20)]

      result = Budget.fit(items, 100)

      assert Enum.map(result.items, & &1.id) == ["a", "b"]
      assert result.used == 30
      assert result.truncated == false
      assert result.dropped == []
    end

    test "higher-priority items win when not everything fits" do
      items = [
        item("low", 60, priority: 1),
        item("high", 60, priority: 10)
      ]

      result = Budget.fit(items, 100, reserve: 0.0)

      assert Enum.map(result.items, & &1.id) == ["high"]
      assert Enum.map(result.dropped, & &1.id) == ["low"]
    end

    test "score breaks priority ties, recency breaks score ties" do
      items = [
        item("old-low-score", 50, score: 0.1, recency: ~U[2026-01-01 00:00:00Z]),
        item("new-high-score", 50, score: 0.9, recency: ~U[2026-11-01 00:00:00Z])
      ]

      # only one of the two 50-token items fits into 75 tokens
      result = Budget.fit(items, 75, reserve: 0.0)
      assert Enum.map(result.items, & &1.id) == ["new-high-score"]
      assert Enum.map(result.dropped, & &1.id) == ["old-low-score"]

      tied = [
        item("older", 50, recency: ~U[2026-01-01 00:00:00Z]),
        item("newer", 50, recency: ~U[2026-11-08 00:00:00Z])
      ]

      result2 = Budget.fit(tied, 75, reserve: 0.0)
      assert Enum.map(result2.items, & &1.id) == ["newer"]
    end

    test "a single oversized item is dropped whole, never sliced" do
      huge = %{id: "huge", estimated_tokens: 10_000, body: "keep me intact"}

      result = Budget.fit([huge], 100, reserve: 0.0)

      assert result.items == []
      assert result.truncated == true
      assert [%{id: "huge"}] = result.dropped
      assert result.used == 0
    end

    test "greedy packing continues past a non-fitting item" do
      items = [
        item("big", 80),
        item("small", 10)
      ]

      result = Budget.fit(items, 100, reserve: 0.0)

      # big fits (80), small fits too (90 <= 100)
      assert Enum.map(result.items, & &1.id) == ["big", "small"]

      tight = [
        item("big", 85),
        item("medium", 15),
        item("tiny", 5)
      ]

      result2 = Budget.fit(tight, 90, reserve: 0.0)
      assert Enum.map(result2.items, & &1.id) == ["big", "tiny"]
      assert Enum.map(result2.dropped, & &1.id) == ["medium"]
    end

    test "custom tokens_key is honored" do
      items = [%{id: "x", tokens: 30}]

      result = Budget.fit(items, 100, tokens_key: :tokens, reserve: 0.0)
      assert Enum.map(result.items, & &1.id) == ["x"]
      assert result.used == 30
    end

    test "zero budget keeps nothing" do
      result = Budget.fit([item("a", 1)], 5, reserve: 1.0)
      assert result.budget == 0
      assert result.items == []
      assert result.truncated == true
    end
  end
end
