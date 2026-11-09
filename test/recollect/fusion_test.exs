defmodule Recollect.FusionTest do
  use Recollect.DataCase, async: false

  alias Recollect.Search.Fusion

  describe "Fusion.fuse/2 (MEM-032)" do
    test "combines results from multiple sources using RRF" do
      results = [
        %{source: :vector, results: [
          %{kind: :entry, id: "1", content: "first"},
          %{kind: :entry, id: "2", content: "second"},
          %{kind: :entry, id: "3", content: "third"}
        ]},
        %{source: :lexical, results: [
          %{kind: :entry, id: "2", content: "second"},
          %{kind: :entry, id: "4", content: "fourth"}
        ]}
      ]

      {:ok, fusion_result} = Fusion.fuse(results)

      assert is_list(fusion_result.items)
      assert length(fusion_result.items) <= 4
      # Item "2" appears in both sources, should have highest RRF score
      assert hd(fusion_result.items).id == "2"
      assert fusion_result.sources == [:vector, :lexical]
    end

    test "applies RRF k parameter correctly" do
      results = [
        %{source: :vector, results: [
          %{kind: :entry, id: "1"},
          %{kind: :entry, id: "2"}
        ]},
        %{source: :graph, results: [
          %{kind: :entry, id: "2"},
          %{kind: :entry, id: "1"}
        ]}
      ]

      {:ok, r60} = Fusion.fuse(results, k: 60)
      {:ok, r10} = Fusion.fuse(results, k: 10)

      # Both items appear in both sources at ranks 1 and 2
      # With k=60: item 1 score = 1/61 + 1/62 = 0.0326..., item 2 score = 1/62 + 1/61 = same
      # With k=10: item 1 score = 1/11 + 1/12 = 0.174..., item 2 score = 1/12 + 1/11 = same
      # Order should be the same since scores are symmetric
      assert r60.items == r10.items
    end

    test "applies diversity limit (max 2 per kind)" do
      results = [
        %{source: :vector, results: [
          %{kind: :entry, id: "1", entry_type: "note"},
          %{kind: :entry, id: "2", entry_type: "note"},
          %{kind: :entry, id: "3", entry_type: "note"},
          %{kind: :chunk, id: "4", entry_type: "paragraph"},
          %{kind: :chunk, id: "5", entry_type: "paragraph"}
        ]}
      ]

      {:ok, fusion_result} = Fusion.fuse(results, diversity: 2)

      note_items = Enum.filter(fusion_result.items, &(&1.kind == :entry))
      assert length(note_items) <= 2
    end

    test "disables diversity when set to false" do
      results = [
        %{source: :vector, results: [
          %{kind: :entry, id: "1"},
          %{kind: :entry, id: "2"},
          %{kind: :entry, id: "3"}
        ]}
      ]

      {:ok, fusion_result} = Fusion.fuse(results, diversity: false)
      assert length(fusion_result.items) == 3
    end

    test "applies limit" do
      results = [
        %{source: :vector, results: [
          %{kind: :entry, id: "1"},
          %{kind: :entry, id: "2"},
          %{kind: :entry, id: "3"},
          %{kind: :entry, id: "4"},
          %{kind: :entry, id: "5"}
        ]}
      ]

      {:ok, fusion_result} = Fusion.fuse(results, limit: 3, diversity: false)
      assert length(fusion_result.items) == 3
    end

    test "returns empty items for empty results" do
      {:ok, fusion_result} = Fusion.fuse([])
      assert fusion_result.items == []
      assert fusion_result.fused_count == 0
    end

    test "dedupes items by id across sources" do
      results = [
        %{source: :vector, results: [
          %{kind: :entry, id: "1", content: "a"},
          %{kind: :entry, id: "2", content: "b"}
        ]},
        %{source: :graph, results: [
          %{kind: :entry, id: "1", content: "a"},
          %{kind: :entry, id: "2", content: "b"},
          %{kind: :entry, id: "3", content: "c"}
        ]}
      ]

      {:ok, fusion_result} = Fusion.fuse(results, diversity: false)
      ids = Enum.map(fusion_result.items, & &1.id)
      assert length(ids) == length(Enum.uniq(ids))
      assert length(fusion_result.items) == 3
    end

    test "removes private fields from output items" do
      results = [
        %{source: :vector, results: [
          %{kind: :entry, id: "1", content: "test"}
        ]}
      ]

      {:ok, fusion_result} = Fusion.fuse(results)
      item = hd(fusion_result.items)
      assert !Map.has_key?(item, :_rank)
      assert !Map.has_key?(item, :_source)
      assert !Map.has_key?(item, :_score)
      assert !Map.has_key?(item, :_sources)
      assert !Map.has_key?(item, :_ranks)
      assert item.content == "test"
    end
  end
end