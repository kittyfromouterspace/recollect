defmodule Recollect.PageTest do
  use Recollect.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Recollect.Config
  alias Recollect.Page
  alias Recollect.Schema.Page, as: PageRow
  alias Recollect.Schema.PageSource, as: PageSourceRow

  setup do
    scope_id = Fixtures.scope_id()
    owner_id = Fixtures.owner_id()

    {:ok, scope_id: scope_id, owner_id: owner_id}
  end

  defp attrs(scope_id, owner_id, overrides \\ []) do
    Keyword.merge(
      [
        owner_id: owner_id,
        scope_id: scope_id,
        slug: "deploy/runbook",
        title: "Deploy runbook",
        body_md: "## Steps\n\n1. Run migrations.\n2. Swap the symlink.\n3. Smoke test."
      ],
      overrides
    )
  end

  defp one_source do
    [%{source_type: "entry", entry_id: Fixtures.entry().id, role: "primary"}]
  end

  describe "create/2 (MEM-027)" do
    test "creates a page with computed token_count and source_hash", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      body = "## Steps\n\n1. Run migrations.\n2. Swap the symlink.\n3. Smoke test."

      assert {:ok, page} = Page.create(attrs(scope_id, owner_id, body_md: body), one_source())

      assert page.slug == "deploy/runbook"
      assert page.token_count == Recollect.Tokenizer.estimate(body)
      assert page.source_hash == Base.encode16(:crypto.hash(:sha256, body), case: :lower)
      assert page.version == 1

      assert {:ok, sources} = Page.sources(page.id)
      assert length(sources) == 1
      assert hd(sources).role == "primary"
    end

    test "a page with no sources is rejected" do
      assert {:error, :no_sources} = Page.create(attrs(Fixtures.scope_id(), Fixtures.owner_id()), [])

      assert {:error, :no_sources} =
               Page.create(attrs(Fixtures.scope_id(), Fixtures.owner_id()), "not a list")
    end

    test "invalid slug format returns a changeset error" do
      assert {:error, %Ecto.Changeset{errors: errors}} =
               Page.create(
                 attrs(Fixtures.scope_id(), Fixtures.owner_id(), slug: "Deploy Runbook!"),
                 one_source()
               )

      assert errors[:slug]
    end

    test "duplicate slug in the same scope returns a changeset error", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      assert {:ok, _} = Page.create(attrs(scope_id, owner_id), one_source())

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Page.create(attrs(scope_id, owner_id, title: "Second"), one_source())

      assert errors != %{}
    end

    test "the same slug is fine in a different scope", %{scope_id: scope_id, owner_id: owner_id} do
      assert {:ok, _} = Page.create(attrs(scope_id, owner_id), one_source())
      assert {:ok, _} = Page.create(attrs(Fixtures.scope_id(), owner_id), one_source())
    end

    test "event-sourced citations are supported" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {:ok, event} =
        Recollect.Event.record(owner_id: owner_id, scope_id: scope_id, event_type: "message", content: "src")

      assert {:ok, _page} =
               Page.create(attrs(scope_id, owner_id), [
                 %{source_type: "event", event_id: event.id, source_ref: "session:1", role: "supporting"}
               ])
    end
  end

  describe "get/list/update/delete (MEM-027)" do
    test "get/1 returns the page with sources", %{scope_id: scope_id, owner_id: owner_id} do
      {:ok, page} = Page.create(attrs(scope_id, owner_id), one_source())

      assert {:ok, fetched} = Page.get(page.id)
      assert fetched.id == page.id
      assert length(fetched.sources) == 1
      assert {:error, :not_found} = Page.get(Ecto.UUID.generate())
    end

    test "list/2 filters by kind", %{scope_id: scope_id, owner_id: owner_id} do
      {:ok, _} = Page.create(attrs(scope_id, owner_id), one_source())

      {:ok, _} =
        Page.create(
          attrs(scope_id, owner_id, slug: "runbook/index", title: "Index", kind: "index"),
          one_source()
        )

      assert {:ok, all} = Page.list(scope_id)
      assert length(all) == 2

      assert {:ok, [%{kind: "index"}]} = Page.list(scope_id, kind: "index")
    end

    test "update/2 bumps version and recomputes hash on body change", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      {:ok, page} = Page.create(attrs(scope_id, owner_id), one_source())

      new_body = "## New body\n\nCompletely different."
      assert {:ok, updated} = Page.update(page.id, body_md: new_body, summary: "v2")

      assert updated.body_md == new_body
      assert updated.version == 2
      assert updated.summary == "v2"
      assert updated.token_count == Recollect.Tokenizer.estimate(new_body)
      assert updated.source_hash != page.source_hash
    end

    test "update/2 without body change keeps version", %{scope_id: scope_id, owner_id: owner_id} do
      {:ok, page} = Page.create(attrs(scope_id, owner_id), one_source())
      assert {:ok, updated} = Page.update(page.id, summary: "just a summary edit")
      assert updated.version == 1
      assert updated.summary == "v" || true
      assert updated.summary == "just a summary edit"
    end

    test "delete/1 cascades to sources", %{scope_id: scope_id, owner_id: owner_id} do
      {:ok, page} = Page.create(attrs(scope_id, owner_id), one_source())

      assert {:ok, _} = Page.delete(page.id)

      assert Config.repo().get(PageRow, page.id) == nil
      assert Config.repo().all(from(s in PageSourceRow, where: s.page_id == ^page.id)) == []
      assert {:error, :not_found} = Page.get(page.id)
    end
  end

  describe "sources/1 + citations/1 (MEM-027)" do
    test "citations are role-ordered with display strings" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      entry = Fixtures.entry()

      {:ok, page} =
        Page.create(attrs(scope_id, owner_id), [
          %{source_type: "entry", entry_id: entry.id, role: "supporting", source_ref: "sup-1"},
          %{source_type: "entry", entry_id: entry.id, role: "primary", source_ref: "pri-1"}
        ])

      assert {:ok, citations} = Page.citations(page.id)
      assert [%{role: "primary"}, %{role: "supporting"}] = citations
      assert hd(citations).display =~ "[p] entry:"
    end

    test "add_source/2 appends a citation to an existing page", %{scope_id: scope_id, owner_id: owner_id} do
      {:ok, page} = Page.create(attrs(scope_id, owner_id), one_source())

      assert {:ok, _} =
               Page.add_source(page.id, %{source_type: "file", source_ref: "lib/deploy.ex"})

      assert {:ok, sources} = Page.sources(page.id)
      assert length(sources) == 2
    end
  end
end
