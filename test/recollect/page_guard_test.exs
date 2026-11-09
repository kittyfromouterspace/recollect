defmodule Recollect.PageGuardTest do
  use Recollect.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Recollect.Config
  alias Recollect.Page
  alias Recollect.Schema.Page, as: PageRow

  setup do
    scope_id = Fixtures.scope_id()
    owner_id = Fixtures.owner_id()

    previous = Application.get_env(:recollect, :pages)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:recollect, :pages, previous),
        else: Application.delete_env(:recollect, :pages)
    end)

    {:ok, scope_id: scope_id, owner_id: owner_id}
  end

  # a SMALL cited source: ~20 tokens → guard limit = max(200, ~10) = 200
  defp small_source do
    entry = Fixtures.entry(content: "Short note. " |> String.duplicate(2) |> String.trim())

    %{source_type: "entry", entry_id: entry.id, role: "primary"}
  end

  defp long_body do
    Enum.map_join(1..120, " ", fn i ->
      "Sentence #{i} with plenty of words to pad the page size well past two hundred tokens."
    end)
  end

  defp short_body do
    "Tiny page."
  end

  describe "compression guard (MEM-029)" do
    test "a page longer than the guard is rejected" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      body = long_body()
      assert Recollect.Tokenizer.estimate(body) > 200

      capture_log(fn ->
        assert {:error, {:compression_guard, guard}} =
                 Page.create(
                   attrs(scope_id, owner_id, body_md: body),
                   [small_source()]
                 )

        assert guard.page_token_count > guard.limit
        assert guard.source_tokens <= 200
        assert guard.reasons == [:compression_guard_exceeded]
      end)
    end

    test "a page within the guard is accepted" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      assert {:ok, _page} =
               Page.create(attrs(scope_id, owner_id, body_md: short_body()), [small_source()])
    end

    test "the guard uses the cited sources, not the whole corpus" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      # a huge UNRELATED entry exists in the scope — it must not count
      Fixtures.entry(
        scope_id: scope_id,
        owner_id: owner_id,
        content: String.duplicate(long_body(), 3)
      )

      assert {:ok, _} =
               Page.create(attrs(scope_id, owner_id, body_md: short_body()), [small_source()])
    end

    test "a body change that outgrows the sources is rejected on update" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {:ok, page} = Page.create(attrs(scope_id, owner_id, body_md: short_body()), [small_source()])

      assert {:error, {:compression_guard, _}} = Page.update(page.id, body_md: long_body())
    end

    test "check/1 validates without writing" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      {:ok, overgrown} =
        Page.create(attrs(scope_id, owner_id, slug: "overgrown", body_md: short_body()), [small_source()])

      # simulate legacy data that predates the guard: a body way past the
      # sources, written behind the guard's back
      Config.repo().update_all(
        from(p in PageRow, where: p.id == ^overgrown.id),
        set: [body_md: long_body(), token_count: Recollect.Tokenizer.estimate(long_body())]
      )

      assert {:ok, report} = Page.check(overgrown.id)
      assert report.valid == false
      assert report.reasons == [:compression_guard_exceeded]
      assert report.page_token_count > report.max_allowed
    end
  end

  describe "page cap (MEM-029)" do
    test "overflow refuses new pages with a clear error" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()
      Application.put_env(:recollect, :pages, max_pages_per_scope: 1)

      assert {:ok, _} = Page.create(attrs(scope_id, owner_id, slug: "first"), [small_source()])

      assert {:error, :page_cap_reached} =
               Page.create(attrs(scope_id, owner_id, slug: "second"), [small_source()])
    end

    test "the cap is per scope" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()
      Application.put_env(:recollect, :pages, max_pages_per_scope: 1)

      assert {:ok, _} = Page.create(attrs(scope_id, owner_id, slug: "first"), [small_source()])
      assert {:ok, _} = Page.create(attrs(Fixtures.scope_id(), owner_id, slug: "other-scope"), [small_source()])
    end
  end

  describe "no-sources rejection (MEM-029)" do
    test "a page with no sources is rejected at create" do
      assert {:error, :no_sources} = Page.create(attrs(Fixtures.scope_id(), Fixtures.owner_id()), [])
    end
  end

  defp attrs(scope_id, owner_id, overrides \\ []) do
    Keyword.merge(
      [
        owner_id: owner_id,
        scope_id: scope_id,
        slug: "page-#{:erlang.unique_integer([:positive])}",
        title: "Test page",
        body_md: short_body()
      ],
      overrides
    )
  end
end
