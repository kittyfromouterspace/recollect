defmodule Mix.Tasks.Recollect.MigrationStatus do
  @moduledoc """
  Check migration drift against the Recollect migration manifest.

      mix recollect.migration_status

  Reads the host's `priv/repo/migrations` directory and the applied
  `schema_migrations` rows, compares against `priv/recollect_migrations.manifest.json`,
  and prints a status table:

      applied            — migration exists in host and has been applied
      mirrored-not-applied — migration exists in host but not applied
      missing            — migration in manifest but not in host (DRIFT)
      unknown            — migration in host but not in manifest

  Exits non-zero when any migration is `missing`, suitable for use as a
  FleetConformance gate step.

  ## Options

  - `--repo` — Ecto repo module (default: from config)
  - `--gate` — emit gate-report.json-compatible output
  """
  use Mix.Task

  alias Recollect.Config

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [repo: :string, gate: :boolean])

    # The task queries the host repo and reads the host's migrations directory,
    # so the host application (and its Repo) must be running.
    Mix.Task.run("app.start")

    repo_module = resolve_repo(opts)
    gate = Keyword.get(opts, :gate, false)

    manifest = load_manifest()
    host_migrations = load_host_migrations()
    applied_versions = load_applied_versions(repo_module)

    results = analyze(manifest, host_migrations, applied_versions)

    if gate do
      emit_gate_report(results)
    else
      emit_table(results)
    end

    missing_count = Enum.count(results, &(&1.status == :missing))

    if missing_count > 0 do
      IO.puts("")

      IO.puts(
        IO.ANSI.red() <> "DRIFT DETECTED: #{missing_count} migration(s) missing from host mirror" <> IO.ANSI.reset()
      )

      System.halt(1)
    else
      IO.puts("")
      IO.puts(IO.ANSI.green() <> "All manifest migrations are mirrored and applied." <> IO.ANSI.reset())
      System.halt(0)
    end
  end

  defp resolve_repo(opts) do
    case Keyword.get(opts, :repo) do
      nil -> Config.repo()
      mod -> String.to_atom(mod)
    end
  end

  defp load_manifest do
    path = Path.join([:code.priv_dir(:recollect), "recollect_migrations.manifest.json"])
    path |> File.read!() |> Jason.decode!()
  end

  defp load_host_migrations do
    migrations_path = Path.join(["priv", "repo", "migrations"])

    if File.dir?(migrations_path) do
      migrations_path
      |> File.ls!()
      |> Enum.map(fn filename ->
        {version, _name} = parse_migration_filename(filename)
        %{version: version, filename: filename}
      end)
    else
      IO.puts(
        IO.ANSI.yellow() <> "warning: #{migrations_path} not found; treating host mirror as empty" <> IO.ANSI.reset()
      )

      []
    end
  end

  defp parse_migration_filename(filename) do
    [version | _rest] = String.split(filename, "_", parts: 2)
    {version, filename}
  end

  defp load_applied_versions(repo_module) do
    case repo_module.query("SELECT version FROM schema_migrations ORDER BY version") do
      {:ok, result} ->
        Enum.map(result.rows, &hd/1)

      {:error, reason} ->
        IO.puts(
          IO.ANSI.yellow() <>
            "warning: could not read schema_migrations (#{inspect(reason)}); treating applied set as empty" <>
            IO.ANSI.reset()
        )

        []
    end
  end

  def analyze(manifest, host_migrations, applied_versions) do
    host_versions = MapSet.new(Enum.map(host_migrations, & &1.version))
    applied_set = MapSet.new(applied_versions)
    manifest_versions = MapSet.new(Enum.map(manifest["migrations"], & &1["version"]))

    results =
      for m <- manifest["migrations"], into: [] do
        version = m["version"]
        in_host = MapSet.member?(host_versions, version)
        is_applied = MapSet.member?(applied_set, version)

        status =
          cond do
            not in_host -> :missing
            not is_applied -> :mirrored_not_applied
            true -> :applied
          end

        %{version: version, name: m["name"], status: status}
      end

    unknown =
      host_migrations
      |> Enum.reject(&MapSet.member?(manifest_versions, &1.version))
      |> Enum.map(&%{version: &1.version, name: &1.filename, status: :unknown})

    Enum.sort_by(results ++ unknown, & &1.version)
  end

  defp emit_table(results) do
    IO.puts("Migration Status (vs manifest):")
    IO.puts("")

    widths = [version: 20, name: 40, status: 22]

    vw = Keyword.get(widths, :version)
    nw = Keyword.get(widths, :name)
    sw = Keyword.get(widths, :status)

    header = :io_lib.format("~#{vw}s ~#{nw}s ~#{sw}s", ["VERSION", "NAME", "STATUS"])
    IO.puts(iodata_to_string(header))
    IO.puts(String.duplicate("-", vw + nw + sw + 2))

    Enum.each(results, fn r ->
      status_text = format_status(r.status)
      row = :io_lib.format("~#{vw}s ~#{nw}s ~s", [r.version, r.name, status_text])
      IO.puts(iodata_to_string(row))
    end)

    unknown = Enum.filter(results, &(&1.status == :unknown))

    if length(unknown) > 0 do
      IO.puts("")
      IO.puts("Unknown host migrations (not in manifest):")
      Enum.each(unknown, fn r -> IO.puts("  #{r.version} #{r.name}") end)
    end
  end

  defp format_status(status) do
    cond do
      status == :applied -> IO.ANSI.green() <> "applied" <> IO.ANSI.reset()
      status == :mirrored_not_applied -> IO.ANSI.yellow() <> "mirrored-not-applied" <> IO.ANSI.reset()
      status == :missing -> IO.ANSI.red() <> "MISSING" <> IO.ANSI.reset()
      true -> to_string(status)
    end
  end

  defp emit_gate_report(results) do
    missing = Enum.filter(results, &(&1.status == :missing))

    report = %{
      status: if(length(missing) > 0, do: "fail", else: "pass"),
      total_migrations: length(results),
      missing_count: length(missing),
      missing_migrations: Enum.map(missing, &%{version: &1.version, name: &1.name})
    }

    File.write!("gate-report.json", Jason.encode!(report, pretty: true))
    IO.puts("Gate report written to gate-report.json")
  end

  defp iodata_to_string(iodata) do
    iodata |> IO.iodata_to_binary() |> String.trim_trailing()
  end
end
