defmodule Recollect.MigrationStatusTest do
  use Recollect.DataCase, async: false

  alias Mix.Tasks.Recollect.MigrationStatus

  @manifest_path Path.join([:code.priv_dir(:recollect), "recollect_migrations.manifest.json"])

  describe "manifest" do
    test "every manifest version matches an actual migration file" do
      manifest = File.read!(@manifest_path) |> Jason.decode!()
      files = File.ls!(Path.join([:code.priv_dir(:recollect), "repo", "migrations"]))

      Enum.each(manifest["migrations"], fn m ->
        expected = "#{m["version"]}_#{m["name"]}.exs"
        assert expected in files, "manifest entry #{expected} has no matching migration file"
      end)
    end

    test "parses and covers every migration" do
      manifest = @manifest_path |> File.read!() |> Jason.decode!()

      assert is_list(manifest["migrations"])
      assert length(manifest["migrations"]) > 0

      # Every migration has required fields
      Enum.each(manifest["migrations"], fn m ->
        assert is_binary(m["version"])
        assert is_binary(m["name"])
        assert is_binary(m["module"])
        assert is_list(m["creates"])
        assert is_list(m["alters"])
      end)

      # Covers known tables
      all_creates = Enum.reduce(manifest["migrations"], [], fn m, acc -> acc ++ m["creates"] end)
      assert "recollect_pages" in all_creates
      assert "recollect_page_sources" in all_creates

      # Entries table is either created or altered
      assert any_creates_or_alters_entries(manifest)
    end
  end

  describe "analyze" do
    test "reports all applied when host matches manifest" do
      manifest = @manifest_path |> File.read!() |> Jason.decode!()

      host_migrations =
        Enum.map(manifest["migrations"], fn m ->
          %{version: m["version"], filename: "#{m["version"]}_#{m["name"]}.exs"}
        end)

      applied_versions = Enum.map(manifest["migrations"], & &1["version"])

      results = MigrationStatus.analyze(manifest, host_migrations, applied_versions)

      assert length(results) == length(manifest["migrations"])
      assert Enum.all?(results, &(&1.status == :applied))
    end

    test "reports missing when host lacks a migration" do
      manifest = @manifest_path |> File.read!() |> Jason.decode!()
      # Use only the first migration as host
      first_m = manifest["migrations"] |> Enum.take(1) |> List.first()
      host_migrations = [%{version: first_m["version"], filename: "#{first_m["version"]}_#{first_m["name"]}.exs"}]
      applied_versions = []

      results = MigrationStatus.analyze(manifest, host_migrations, applied_versions)

      missing = Enum.filter(results, &(&1.status == :missing))
      assert length(missing) > 0
      assert length(results) == length(manifest["migrations"])
    end

    test "reports mirrored-not-applied when host has migration but not applied" do
      manifest = @manifest_path |> File.read!() |> Jason.decode!()

      host_migrations =
        Enum.map(manifest["migrations"], fn m ->
          %{version: m["version"], filename: "#{m["version"]}_#{m["name"]}.exs"}
        end)

      # none applied
      applied_versions = []

      results = MigrationStatus.analyze(manifest, host_migrations, applied_versions)

      mirrored = Enum.filter(results, &(&1.status == :mirrored_not_applied))
      assert length(mirrored) == length(manifest["migrations"])
    end
  end

  describe "analyze_tables" do
    test "reports all manifest tables present in test DB" do
      manifest = File.read!(@manifest_path) |> Jason.decode!()
      results = Mix.Tasks.Recollect.MigrationStatus.analyze_tables(manifest, Recollect.Config.repo())

      assert results != []
      assert Enum.all?(results, &(&1.status == :applied))
    end

    test "flags a missing table" do
      manifest = %{
        "migrations" => [
          %{"version" => "1", "name" => "x", "module" => "X", "creates" => ["recollect_nonexistent_table"], "alters" => []}
        ]
      }

      results = Mix.Tasks.Recollect.MigrationStatus.analyze_tables(manifest, Recollect.Config.repo())
      missing = Enum.find(results, &(&1.table == "recollect_nonexistent_table"))
      assert missing.status == :missing
    end
  end

  defp any_creates_or_alters_entries(manifest) do
    Enum.any?(manifest["migrations"], fn m ->
      Enum.any?(m["creates"], &(&1 == "recollect_entries")) or
        Enum.any?(m["alters"], &String.contains?(&1, "recollect_entries"))
    end)
  end
end
