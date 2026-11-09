defmodule Recollect.DreamSynthesizeTest do
  use Recollect.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Recollect.Config
  alias Recollect.Dream
  alias Recollect.Dream.Synthesize
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

    # the stage is gated by pages.enabled
    Application.put_env(:recollect, :pages, enabled: true)

    {:ok, scope_id: scope_id, owner_id: owner_id}
  end

  # three overlapping claims, mixed sources — a real cluster
  defp cluster(scope_id, owner_id, tag, sources \\ ["agent", "user", "system"]) do
    contents = [
      "The deploy script scripts/deploy.sh requires bash 5 and runs migrations.",
      "Remember: deploy script scripts/deploy.sh requires bash 5 on the host.",
      "Deploys: scripts/deploy.sh requires bash 5 and runs the migrations."
    ]

    entries =
      contents
      |> Enum.zip(sources)
      |> Enum.map(fn {content, source} ->
        entry =
          Fixtures.entry(scope_id: scope_id, owner_id: owner_id, content: content, source: source)

        {:ok, _} = Recollect.Knowledge.set_tags(entry.id, [tag])
        entry
      end)

    entries
  end

  describe "Dream.Synthesize (MEM-028)" do
    test "a cluster of three claims produces one page with three citations", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      cluster(scope_id, owner_id, "deploy")

      assert {:ok, metrics} = Synthesize.run(scope_id, [])
      assert metrics.pages_created == 1
      assert metrics.clusters_skipped == 0

      assert {:ok, [page]} = Page.list(scope_id)
      assert length(page.sources) == 3

      # the fallback template quotes every claim verbatim with citations
      assert page.body_md =~ "[e:"
      assert page.body_md =~ "requires bash 5 and runs migrations."
      assert page.body_md =~ "## Cited claims"
    end

    test "a cluster from one source is skipped" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      cluster(scope_id, owner_id, "deploy", ["system", "system", "system"])

      assert {:ok, metrics} = Synthesize.run(scope_id, [])
      assert metrics.clusters_skipped == 1
      assert metrics.pages_created == 0
      assert {:ok, []} = Page.list(scope_id)
    end

    test "clusters below the minimum size are skipped" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()
      cluster(scope_id, owner_id, "deploy", ["agent", "user"])

      assert {:ok, metrics} = Synthesize.run(scope_id, min_cluster_size: 3)
      assert metrics.clusters_skipped == 1
      assert metrics.pages_created == 0
    end

    test "the fallback template works without an LLM" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()
      cluster(scope_id, owner_id, "deploy")

      # no llm_fn configured in tests — the template path is what runs
      assert {:ok, _} = Synthesize.run(scope_id, [])

      {:ok, [page]} = Page.list(scope_id)
      assert page.body_md =~ "## Cited claims"
      refute page.body_md =~ "## Synthesis"
    end

    test "an LLM synthesis is layered on top of the verbatim citations" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()
      cluster(scope_id, owner_id, "deploy")

      synthesis_fn = fn _messages, _opts -> {:ok, "All three claims agree: deploys depend on bash 5."} end

      assert {:ok, _} = Synthesize.run(scope_id, synthesis_fn: synthesis_fn)

      {:ok, [page]} = Page.list(scope_id)
      assert page.body_md =~ "All three claims agree: deploys depend on bash 5."
      assert page.body_md =~ "## Cited claims", "verbatim citations stay even with an LLM"
    end

    test "rerunning the same cluster updates one page, not duplicates", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      entries = cluster(scope_id, owner_id, "deploy")

      assert {:ok, first} = Synthesize.run(scope_id, [])
      assert first.pages_created == 1

      # same cluster membership → source_hash unchanged → no rewrite
      assert {:ok, second} = Synthesize.run(scope_id, [])
      assert second.pages_created == 0
      assert second.pages_updated == 0, "unchanged cluster is a no-op"
      assert second.enabled == true

      # add a fourth claim to the same block → incremental update
      fourth =
        Fixtures.entry(
          scope_id: scope_id,
          owner_id: owner_id,
          content: "Deploy tooling: the deploy script scripts/deploy.sh requires bash 5 installed first.",
          source: "user"
        )

      {:ok, _} = Recollect.Knowledge.set_tags(fourth.id, ["deploy"])

      assert {:ok, third} = Synthesize.run(scope_id, [])
      assert third.pages_created == 0
      assert third.pages_updated == 1

      assert {:ok, [page]} = Page.list(scope_id)
      assert page.version == 2
      assert length(page.sources) == 4
      assert entries && page.slug == "cluster/deploy"
    end

    test "two synthesizers never create two pages for the same slug" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()
      cluster(scope_id, owner_id, "deploy")

      tasks =
        for _ <- 1..2 do
          Task.async(fn -> Synthesize.run(scope_id, []) end)
        end

      results = Task.await_many(tasks, 15_000)

      created = Enum.sum(Enum.map(results, fn {:ok, m} -> m.pages_created end))
      updated = Enum.sum(Enum.map(results, fn {:ok, m} -> m.pages_updated end))
      assert created + updated == 1

      assert {:ok, [page]} = Page.list(scope_id)
      assert page.slug == "cluster/deploy"
    end

    test "disabled stage is a no-op" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()
      cluster(scope_id, owner_id, "deploy")

      Application.put_env(:recollect, :pages, enabled: false)

      assert {:ok, %{enabled: false}} = Synthesize.run(scope_id, [])
      assert {:ok, []} = Page.list(scope_id)
    end

    test "the stage runs inside a dream run" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()
      cluster(scope_id, owner_id, "deploy")

      assert {:ok, result} = Dream.run(scope_id, stages: [Synthesize])

      assert result.status == "done"
      assert result.stages["synthesize"]["status"] == "completed"
      assert result.stages["synthesize"]["metrics"]["pages_created"] == 1
    end

    test "pages carry token counts and source hashes for the compression guard" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()
      cluster(scope_id, owner_id, "deploy")

      Synthesize.run(scope_id, [])

      page =
        Config.repo().one(from(p in PageRow, where: p.scope_id == ^scope_id))

      assert page.token_count > 0
      assert page.source_hash
    end
  end
end
