defmodule Recollect.PageSearchTest do
  use Recollect.DataCase, async: false

  alias Recollect.Embedding.Mock
  alias Recollect.Page
  alias Recollect.Search

  setup do
    scope_id = Fixtures.scope_id()
    owner_id = Fixtures.owner_id()

    {:ok, scope_id: scope_id, owner_id: owner_id}
  end

  defp create_page(scope_id, owner_id, slug, title, body_md, summary, sources) do
    Page.create(
      %{
        scope_id: scope_id,
        owner_id: owner_id,
        slug: slug,
        title: title,
        body_md: body_md,
        summary: summary
      },
      sources
    )
  end

  defp create_entry_with_embedding(scope_id, owner_id, content, tags \\ []) do
    {:ok, embedding} = Mock.embed(content, [])

    entry =
      Fixtures.entry(scope_id: scope_id, owner_id: owner_id, content: content, embedding: embedding)

    if tags != [] do
      Recollect.Knowledge.set_tags(entry.id, tags)
    end

    entry
  end

  describe "Page.search/3 (MEM-030)" do
    test "returns pages matching the query", %{scope_id: scope_id, owner_id: owner_id} do
      entry =
        create_entry_with_embedding(
          scope_id,
          owner_id,
          "Run database migrations before swapping the load balancer."
        )

      {:ok, page} =
        create_page(
          scope_id,
          owner_id,
          "deploy/runbook",
          "Deploy Runbook",
          "Run database migrations before swapping the load balancer.",
          "Deploy procedure for production.",
          [%{source_type: "entry", entry_id: entry.id, role: "primary"}]
        )

      {:ok, results} = Page.search("Run database migrations before swapping the load balancer.", scope_id)

      assert length(results) >= 1
      assert Enum.any?(results, &(&1.id == page.id))
      assert Enum.any?(results, &(&1.title == "Deploy Runbook"))
    end

    test "returns pages with citations", %{scope_id: scope_id, owner_id: owner_id} do
      entry =
        create_entry_with_embedding(
          scope_id,
          owner_id,
          "The deploy script requires bash 5."
        )

      {:ok, page} =
        create_page(
          scope_id,
          owner_id,
          "deploy/notes",
          "Deploy Notes",
          "Deploy using scripts/deploy.sh which requires bash 5.",
          "Deploy script notes.",
          [%{source_type: "entry", entry_id: entry.id, role: "primary"}]
        )

      {:ok, results} = Page.search("The deploy script requires bash 5.", scope_id)

      page_result = Enum.find(results, &(&1.id == page.id))
      assert page_result
      assert length(page_result.sources) >= 1
    end

    test "returns empty when no matches", %{scope_id: scope_id} do
      {:ok, results} = Page.search("zzznothingmatcheszzz", scope_id)
      assert results == []
    end
  end

  describe "Search.search/2 with include_pages (MEM-030)" do
    test "includes pages in results when include_pages: true", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      entry =
        create_entry_with_embedding(
          scope_id,
          owner_id,
          "The deploy process requires database migrations first."
        )

      {:ok, page} =
        create_page(
          scope_id,
          owner_id,
          "deploy/guide",
          "Deploy Guide",
          "The deploy process requires database migrations first.",
          "Deploy process overview.",
          [%{source_type: "entry", entry_id: entry.id, role: "primary"}]
        )

      {:ok, pack} =
        Search.search("database migrations", scope_id: scope_id, include_pages: true)

      assert pack.pages != []
      assert Enum.any?(pack.pages, &(&1.id == page.id))
    end

    test "include_pages: false preserves old behavior", %{scope_id: scope_id} do
      {:ok, without} = Search.search("deploy", scope_id: scope_id, include_pages: false)

      assert without.pages == nil || without.pages == []
    end
  end

  describe "Page.get/1 returns full body and citations (MEM-030)" do
    test "returns full body and cited entries", %{scope_id: scope_id, owner_id: owner_id} do
      entry =
        create_entry_with_embedding(
          scope_id,
          owner_id,
          "The deploy script requires bash 5 and runs migrations first."
        )

      {:ok, page} =
        create_page(
          scope_id,
          owner_id,
          "deploy/guide",
          "Deploy Guide",
          "Deploy process: run migrations, then swap.",
          "Deploy process overview.",
          [%{source_type: "entry", entry_id: entry.id, role: "primary", source_ref: "line 42"}]
        )

      {:ok, fetched} = Page.get(page.id)

      assert fetched.body_md == "Deploy process: run migrations, then swap."
      assert length(fetched.sources) == 1
      assert hd(fetched.sources).source_ref == "line 42"
    end
  end
end
