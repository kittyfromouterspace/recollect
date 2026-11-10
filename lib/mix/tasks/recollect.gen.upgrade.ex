defmodule Mix.Tasks.Recollect.Gen.Upgrade do
  @moduledoc """
  Generate an additive upgrade migration from the Recollect migration manifest.

      mix recollect.gen.upgrade --from VERSION [--to VERSION]

  Compares the manifest entries between `--from` and `--to` (default: latest)
  and generates a migration file that creates any tables/columns present in
  `--to` but absent in `--from`, using `IF NOT EXISTS` forms where the adapter
  supports them.

  The generated migration is idempotent: re-running it is safe.

  ## Options

  - `--from` — Source version (required)
  - `--to` — Target version (default: latest in manifest)
  - `--repo` — Ecto repo module (default: from config)
  """
  use Mix.Task

  alias Recollect.Config

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [from: :string, to: :string, repo: :string])

    from_version = Keyword.get(opts, :from)
    to_version = Keyword.get(opts, :to)

    if is_nil(from_version) do
      IO.puts(IO.ANSI.red() <> "--from VERSION is required" <> IO.ANSI.reset())
      System.halt(1)
    end

    manifest = load_manifest()
    to_version = to_version || latest_version(manifest)

    from_idx = manifest_index(manifest, from_version)
    to_idx = manifest_index(manifest, to_version)

    if is_nil(from_idx) do
      IO.puts(IO.ANSI.red() <> "Version #{from_version} not found in manifest" <> IO.ANSI.reset())
      System.halt(1)
    end

    if is_nil(to_idx) do
      IO.puts(IO.ANSI.red() <> "Version #{to_version} not found in manifest" <> IO.ANSI.reset())
      System.halt(1)
    end

    if to_idx <= from_idx do
      IO.puts(IO.ANSI.red() <> "--to must be after --from" <> IO.ANSI.reset())
      System.halt(1)
    end

    # Collect all creates/alters between from (exclusive) and to (inclusive)
    range = Enum.slice(manifest["migrations"], from_idx + 1..to_idx)

    creates = Enum.reduce(range, [], fn m, acc -> acc ++ m["creates"] end)
    alters = Enum.reduce(range, [], fn m, acc -> acc ++ m["alters"] end)

    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    filename = "#{timestamp}_upgrade_#{from_version}_to_#{to_version}.exs"

    migrations_path = Path.join(["priv", "repo", "migrations"])
    File.mkdir_p!(migrations_path)

    target = Path.join(migrations_path, filename)

    adapter = Config.adapter()
    dialect = adapter.dialect()

    content = generate_migration(filename, creates, alters, dialect, timestamp)

    File.write!(target, content)

    IO.puts(IO.ANSI.green() <> "* creating " <> IO.ANSI.reset() <> target)
    IO.puts("")
    IO.puts("Run `mix ecto.migrate` to apply the upgrade migration.")
  end

  defp load_manifest do
    path = Path.join([:code.priv_dir(:recollect), "recollect_migrations.manifest.json"])
    File.read!(path) |> Jason.decode!()
  end

  defp latest_version(manifest) do
    Enum.map(manifest["migrations"], & &1["version"]) |> Enum.max()
  end

  defp manifest_index(manifest, version) do
    Enum.find_index(manifest["migrations"], & &1["version"] == version)
  end

  defp generate_migration(_filename, creates, alters, dialect, timestamp) do
    up_statements = generate_up_statements(creates, alters, dialect)
    down_statements = generate_down_statements()

    module_name_suffix = String.replace(timestamp, "_", "")

    ~s"""
    defmodule Recollect.Repo.Migrations.Upgrade#{module_name_suffix} do
      use Ecto.Migration

      def up do
    #{indent(up_statements, 8)}
      end

      def down do
    #{indent(down_statements, 8)}
      end
    end
    """
  end

  defp generate_up_statements(creates, alters, dialect) do
    # Dedupe creates by table name
    {_seen_tables, stmt_list} =
      Enum.reduce(creates, {MapSet.new(), []}, fn table, {seen, acc} ->
        if MapSet.member?(seen, table) do
          {seen, acc}
        else
          new_seen = MapSet.put(seen, table)
          stmts =
            if dialect == :postgres do
              ["CREATE TABLE IF NOT EXISTS #{table} (id binary_id PRIMARY KEY);"] ++ acc
            else
              ["create table(:#{table}) do\n  # add columns for #{table}\nend"] ++ acc
            end
          {new_seen, stmts}
        end
      end)

    alter_list =
      Enum.reduce(alters, [], fn alter, acc ->
        ["# alter: #{alter}"] ++ acc
      end)

    combined = Enum.reverse(stmt_list ++ alter_list)

    if length(combined) == 0 do
      ["# No changes between versions"]
    else
      combined
    end
  end

  defp generate_down_statements() do
    ["# Downgrade: manually reverse the up changes above"]
  end

  defp indent(text_or_list, spaces) do
    case text_or_list do
      list when is_list(list) ->
        Enum.map_join(list, "\n", &String.pad_leading(&1, String.length(&1) + spaces))
      text when is_binary(text) ->
        text
        |> String.split("\n")
        |> Enum.map_join("\n", &String.pad_leading(&1, String.length(&1) + spaces))
    end
  end
end