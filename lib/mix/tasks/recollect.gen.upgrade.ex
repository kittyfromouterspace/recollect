defmodule Mix.Tasks.Recollect.Gen.Upgrade do
  @moduledoc """
  Generate an additive upgrade migration from the Recollect migration manifest.

      mix recollect.gen.upgrade --from VERSION [--to VERSION]

  Compares the manifest entries between `--from` and `--to` (default: latest)
  and generates a migration file that loads the upstream Recollect migrations
  from the dependency's `priv/repo/migrations` and delegates to their
  `up`/`down` functions — i.e. real, runnable DDL, not approximated stubs.

  Re-running is guarded by Ecto's `schema_migrations` table.

  ## Options

  - `--from` — Source version (required)
  - `--to` — Target version (default: latest in manifest)
  - `--repo` — Ecto repo module (default: from config)
  """
  use Mix.Task

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

    # Collect the migrations between from (exclusive) and to (inclusive)
    range = Enum.slice(manifest["migrations"], (from_idx + 1)..to_idx)

    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    filename = "#{timestamp}_upgrade_#{from_version}_to_#{to_version}.exs"

    migrations_path = Path.join(["priv", "repo", "migrations"])
    File.mkdir_p!(migrations_path)

    target = Path.join(migrations_path, filename)

    content = generate_migration(range, timestamp)

    File.write!(target, content)

    IO.puts(IO.ANSI.green() <> "* creating " <> IO.ANSI.reset() <> target)
    IO.puts("")
    IO.puts("Run `mix ecto.migrate` to apply the upgrade migration.")
  end

  defp load_manifest do
    path = Path.join([:code.priv_dir(:recollect), "recollect_migrations.manifest.json"])
    path |> File.read!() |> Jason.decode!()
  end

  defp latest_version(manifest) do
    manifest["migrations"] |> Enum.map(& &1["version"]) |> Enum.max()
  end

  defp manifest_index(manifest, version) do
    Enum.find_index(manifest["migrations"], &(&1["version"] == version))
  end

  # The generated migration loads the upstream Recollect migration files from
  # the dependency's priv/repo/migrations and delegates to their up/down
  # functions. This produces REAL, runnable DDL (the actual upstream
  # migrations), rather than approximated table stubs.
  #
  # Learned from the ops_center upgrade: upstream migrations use `change/0`
  # as often as `up/0`, so the generated file always includes an
  # `apply_upstream/1` helper that dispatches to whichever exists. Rollback
  # runs in a fresh process, so `down` must `Code.require_file` the upstream
  # files again before delegating (otherwise function_exported? returns false
  # and down silently no-ops).
  #
  # Idempotency note: Ecto's schema_migrations table already guards re-runs of
  # this file. Individual upstream migrations use the same DDL as upstream —
  # no additional IF NOT EXISTS wrapping is added (matching upstream semantics).
  defp generate_migration(range, timestamp) do
    module_name_suffix = String.replace(timestamp, "_", "")

    up_statements =
      Enum.flat_map(range, fn m ->
        [
          "# ── #{m["version"]} #{m["name"]} ──",
          "Code.require_file(#{inspect(migration_filename(m))}, Path.join(:code.priv_dir(:recollect), \"repo/migrations\"))",
          "apply_upstream(#{m["module"]})"
        ]
      end)

    down_requires =
      range
      |> Enum.reverse()
      |> Enum.map(fn m -> inspect(migration_filename(m)) end)
      |> Enum.join(",\n")

    down_delegations =
      range
      |> Enum.reverse()
      |> Enum.map(fn m ->
        "if function_exported?(#{m["module"]}, :down, 0), do: #{m["module"]}.down()"
      end)

    up_statements = if up_statements == [], do: ["# No changes between versions"], else: up_statements

    down_statements =
      if down_delegations == [] do
        ["# No changes between versions"]
      else
        [
          "# Rollback runs in a fresh process: load upstream modules first.",
          "for file <- [",
          down_requires,
          "] do",
          "  Code.require_file(file, Path.join(:code.priv_dir(:recollect), \"repo/migrations\"))",
          "end"
        ] ++ down_delegations
      end

    ~s"""
    defmodule Recollect.Repo.Migrations.Upgrade#{module_name_suffix} do
      @moduledoc \"\"\"
      Additive Recollect upgrade generated by `mix recollect.gen.upgrade`.

      Delegates to the upstream Recollect migrations shipped in the dependency.
      Apply with `mix ecto.migrate`. Re-running is guarded by schema_migrations.
      \"\"\"
      use Ecto.Migration

      def up do
    #{indent(up_statements, 8)}
      end

      def down do
    #{indent(down_statements, 8)}
      end

      # Upstream Recollect migrations define either up/0 or change/0 — call
      # whichever exists, so this mirror works for both styles.
      defp apply_upstream(mod) do
        cond do
          function_exported?(mod, :up, 0) -> mod.up()
          function_exported?(mod, :change, 0) -> mod.change()
          true -> raise "upstream migration \#{inspect(mod)} has no up/0 or change/0"
        end
      end
    end
    """
  end

  defp migration_filename(m) do
    "#{m["version"]}_#{m["name"]}.exs"
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
