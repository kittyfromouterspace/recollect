defmodule Recollect.ContextFormatterTest do
  use ExUnit.Case, async: true

  alias Recollect.Search.ContextFormatter
  alias Recollect.Tokenizer

  @golden_pack %{
    entries: [
      %{
        "id" => "e-1",
        "content" => "Deploy checklist: run migrations before the blue/green swap.",
        "entry_type" => "note",
        "score" => 0.91
      }
    ],
    related_entries: [
      %{"id" => "r-1", "content" => "Related: the swap needs a drain.", "entry_type" => "note"}
    ],
    entities: [
      %{"name" => "deploy script", "entity_type" => "tool", "description" => "scripts/deploy.sh"}
    ],
    relations: [
      %{"from_id" => "deploy", "relation_type" => "uses", "to_id" => "pgvector"}
    ]
  }

  describe "format/1 golden (MEM-020)" do
    test "output is unchanged for a small pack" do
      text = ContextFormatter.format(@golden_pack)

      assert text ==
               "## Relevant Knowledge\n" <>
                 "[1] [note] (score: 0.91) Deploy checklist: run migrations before the blue/green swap.\n\n" <>
                 "## Related Knowledge\n" <>
                 "[Related] [note] Related: the swap needs a drain.\n\n" <>
                 "## Known Entities\n- deploy script (tool): scripts/deploy.sh\n\n" <>
                 "## Known Relationships\n- deploy --[uses]--> pgvector"
    end
  end

  describe "format/2 budgeted (MEM-020)" do
    defp big_pack do
      entries =
        for i <- 1..100 do
          %{
            "id" => "e#{i}",
            "content" => "Entry #{i}: " <> String.duplicate("content words ", 12),
            "entry_type" => "note",
            "score" => 1 - i / 200
          }
        end

      related =
        for i <- 1..10 do
          # e1..e10 also arrive as related — dedupe must collapse them
          %{"id" => "e#{i}", "content" => "Entry #{i}: dup", "entry_type" => "note"}
        end

      %{entries: entries, related_entries: related}
    end

    test "a pack with 100 entries returns text under the budget" do
      {:ok, text, meta} = ContextFormatter.format_with_meta(big_pack(), max_tokens: 400)

      assert Tokenizer.estimate(text) <= 400
      assert meta.used_tokens <= 360
      assert meta.truncated == true
      assert length(meta.dropped) > 0
    end

    test "duplicate entry/related ids appear once" do
      {:ok, text, meta} = ContextFormatter.format_with_meta(big_pack(), max_tokens: 10_000)

      # e1..e10 are both in entries and related_entries
      assert length(meta.items) == 100
      assert text =~ "Entry 1:"
      refute text =~ "[Related]"
    end

    test "dedupe can be disabled" do
      {:ok, _text, meta} = ContextFormatter.format_with_meta(big_pack(), max_tokens: 10_000, dedupe: false)

      assert length(meta.items) == 110
    end

    test "citations are present and can be turned off" do
      {:ok, text, _} = ContextFormatter.format_with_meta(@golden_pack, max_tokens: 10_000)
      assert text =~ "[e1]"

      {:ok, text_plain, _} =
        ContextFormatter.format_with_meta(@golden_pack, max_tokens: 10_000, citations: false)

      refute text_plain =~ "[e1]"
      assert text_plain =~ "Deploy checklist"
    end

    test "chunks get c citations, entities p citations" do
      pack = %{
        chunks: [%{"id" => "ch1", "content" => "chunk body", "score" => 0.5}],
        entries: [%{"id" => "e1", "content" => "entry body", "score" => 0.9}],
        entities: [%{"name" => "pg", "entity_type" => "db", "description" => "postgres"}]
      }

      {:ok, text, meta} = ContextFormatter.format_with_meta(pack, max_tokens: 500)

      assert text =~ "[e1]"
      assert text =~ "[c1]"
      assert text =~ "[p1]"
      assert Enum.any?(meta.items, &(&1.citation == "c1"))
    end

    test "format/2 keeps the sectioned markdown shape on :markdown" do
      text = ContextFormatter.format(@golden_pack, format: :markdown, max_tokens: 10_000)
      assert text =~ "[e1]"
      assert text != ""
    end

    test "summary wins over content" do
      pack = %{
        entries: [
          %{
            "id" => "s1",
            "content" => "long full body " <> String.duplicate("x", 300),
            "summary" => "the gist",
            "score" => 0.8
          }
        ]
      }

      {:ok, text, _} = ContextFormatter.format_with_meta(pack, max_tokens: 10_000)
      assert text =~ "the gist"
      refute text =~ "long full body"
    end

    test "empty pack formats to empty string" do
      assert ContextFormatter.format(%{}) == ""
      assert {:ok, "", meta} = ContextFormatter.format_with_meta(%{})
      assert meta.used_tokens == 0
      assert meta.truncated == false
    end
  end
end
