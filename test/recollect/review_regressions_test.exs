defmodule Recollect.ReviewRegressionsTest do
  @moduledoc """
  Regression tests for the issues found in the pre-merge code review:

  - P0: `related_entries` must not be permanently empty (mode/tier mixup)
  - P1: hybrid mode must actually fetch lexical candidates
  - P1: keyword-fallback entries must reach `items`, not just `entries`
  - P1: `candidates_considered` must reach search stop telemetry
  - P1: migration_status must detect unknown host migrations
  - P1: upgrade generator must emit runnable delegation code, not stubs
  """
  use Recollect.DataCase, async: false

  alias Recollect.Embedding.Mock
  alias Recollect.Search.Lexical

  setup do
    scope_id = Fixtures.scope_id()
    owner_id = Fixtures.owner_id()
    {:ok, scope_id: scope_id, owner_id: owner_id}
  end

  defp embedded_entry(scope_id, owner_id, content) do
    {:ok, embedding} = Mock.embed(content, [])
    Fixtures.entry(scope_id: scope_id, owner_id: owner_id, content: content, embedding: embedding)
  end

  describe "P0: related_entries edge following" do
    test "connected entries surface in related_entries", %{scope_id: scope_id, owner_id: owner_id} do
      e1 = embedded_entry(scope_id, owner_id, "The deploy script requires bash 5.")
      e2 = Fixtures.entry(scope_id: scope_id, owner_id: owner_id, content: "Runbook for rollbacks.")

      {:ok, _} = Recollect.connect(e1.id, e2.id, "related_to")

      {:ok, context} =
        Recollect.search("The deploy script requires bash 5.",
          scope_id: scope_id,
          owner_id: owner_id,
          tier: :both
        )

      assert is_list(context.related_entries)
      assert context.related_entries != []
    end
  end

  describe "P1: lexical candidates in hybrid mode" do
    test "hybrid items include lexical hits even with keyword_fallback disabled", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      Fixtures.entry(
        scope_id: scope_id,
        owner_id: owner_id,
        content: "quixotic lexical marker deploy"
      )

      {:ok, context} =
        Recollect.search("quixotic lexical marker",
          scope_id: scope_id,
          owner_id: owner_id,
          mode: :hybrid,
          keyword_fallback: false
        )

      assert context.items != []

      assert Enum.any?(context.items, fn item ->
               (item["content"] || item[:content] || "") =~ "quixotic"
             end)
    end

    test "Lexical.search returns the seeded entry directly", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      Fixtures.entry(scope_id: scope_id, owner_id: owner_id, content: "zebra lexical deploy")

      {:ok, results} = Lexical.search("zebra", scope_id)
      assert results != []
    end
  end

  describe "P1: keyword fallback reaches items" do
    test "items include keyword hits when embeddings are disabled", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      orig = Application.get_env(:recollect, :embedding)
      Application.put_env(:recollect, :embedding, provider: nil)

      try do
        Fixtures.entry(
          scope_id: scope_id,
          owner_id: owner_id,
          content: "fallback-marker deploy script"
        )

        {:ok, context} =
          Recollect.search("fallback-marker",
            scope_id: scope_id,
            owner_id: owner_id,
            mode: :vector
          )

        assert context.resolved_mode == :keyword_fallback
        assert context.items != []
        assert context.entries != []
      after
        Application.put_env(:recollect, :embedding, orig)
      end
    end
  end

  describe "P1: candidates_considered in telemetry" do
    test "search stop event carries candidates_considered", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      parent = self()
      handler_id = "review-regressions-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:recollect, :search, :stop],
        fn _event, measurements, _metadata, _config ->
          send(parent, {:search_stop, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, _} =
        Recollect.search("telemetry probe", scope_id: scope_id, owner_id: owner_id, mode: :hybrid)

      assert_receive {:search_stop, measurements}, 1000
      assert Map.has_key?(measurements, :candidates_considered)
      assert is_integer(measurements.candidates_considered)
    end
  end

  describe "P1: migration_status unknown detection" do
    test "host migrations not in manifest are reported as unknown" do
      manifest = %{
        "migrations" => [
          %{
            "version" => "20240101000000",
            "name" => "create_mneme_tables",
            "module" => "X",
            "creates" => [],
            "alters" => []
          }
        ]
      }

      host = [
        %{version: "20240101000000", filename: "20240101000000_create_mneme_tables.exs"},
        %{version: "20250101000000", filename: "20250101000000_host_custom.exs"}
      ]

      results =
        Mix.Tasks.Recollect.MigrationStatus.analyze(manifest, host, ["20240101000000"])

      assert %{status: :applied} = Enum.find(results, &(&1.version == "20240101000000"))
      assert %{status: :unknown} = Enum.find(results, &(&1.version == "20250101000000"))
    end
  end

  describe "P1: upgrade generator emits runnable delegation" do
    test "generated migration requires upstream files and calls up/down" do
      tmp = Path.join("/tmp/opencode", "recollect-upgrade-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      original_cwd = File.cwd!()

      try do
        File.cd!(tmp)

        manifest_versions =
          [
            :recollect
            |> :code.priv_dir()
            |> Path.join("recollect_migrations.manifest.json")
            |> File.read!()
            |> Jason.decode!()
            |> Map.get("migrations")
          ]
          |> hd()
          |> Enum.map(& &1["version"])

        from = Enum.at(manifest_versions, 0)
        to = Enum.at(manifest_versions, 1)

        Mix.Tasks.Recollect.Gen.Upgrade.run(["--from", from, "--to", to])

        [file] = Path.wildcard(Path.join([tmp, "priv", "repo", "migrations", "*.exs"]))
        content = File.read!(file)

        assert content =~ "Code.require_file("
        assert content =~ ".up()"
        assert content =~ ":down, 0"
        # No leftover placeholder DDL
        refute content =~ "binary_id PRIMARY KEY"
      after
        File.cd!(original_cwd)
        File.rm_rf!(tmp)
      end
    end
  end
end
