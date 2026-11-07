defmodule Recollect.Invalidation do
  @moduledoc """
  Active memory invalidation based on detected or explicit breaking changes.

  When a breaking change is detected (e.g., migrating from webpack to vite),
  this module weakens related memories and optionally creates replacement entries.

  ## Usage

      # Auto-detect and invalidate from git history
      {:ok, result} = Recollect.Invalidation.run_from_git(scope_id: workspace_id)
      
      # Manual invalidation
      Recollect.Invalidation.invalidate(scope_id, "webpack",
        reason: "migrated to vite"
      )
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Knowledge
  alias Recollect.Telemetry

  @migration_patterns [
    ~r/migrate[ds]?\s+(?:from\s+)?(\w+)\s+(?:to|with)\s+(\w+)/i,
    ~r/(?:refactor|rewrite):\s+(\w+)\s+(?:to|->)\s+(\w+)/i,
    ~r/replace[dr]?\s+(\w+)\s+(?:with|by)\s+(\w+)/i,
    ~r/drop(?:ped)?\s+(?:support\s+for\s+)?(\w+)/i,
    ~r/remove[dr]?\s+(\w+)\s+(?:and|use)\s+(\w+)/i,
    ~r/BREAKING(?:\s+CHANGE)?:/i
  ]

  @default_weaken_factor 0.1

  @doc """
  Run invalidation detection from git history.

  Scans recent commits for migration patterns and invalidates related memories.
  """
  def run_from_git(opts \\ []) do
    scope_id = Keyword.fetch!(opts, :scope_id)
    days = Keyword.get(opts, :days, 7)
    cd = Keyword.get(opts, :cd)

    {_, telemetry_meta} =
      Telemetry.span([:recollect, :invalidation], %{scope_id: scope_id, days: days}, fn ->
        migrations = detect_migrations(days, cd: cd)

        results =
          Enum.map(migrations, fn migration ->
            weaken_related(scope_id, migration.from, migration.to)
          end)

        total_invalidated = Enum.sum(results)

        {%{
           migrations_detected: length(migrations),
           invalidations: total_invalidated,
           migrations: migrations
         },
         %{
           migrations_detected: length(migrations),
           invalidations: total_invalidated
         }}
      end)

    {:ok,
     %{
       migrations_detected: telemetry_meta.migrations_detected,
       invalidations: telemetry_meta.invalidations,
       migrations: telemetry_meta[:migrations] || []
     }}
  end

  @doc """
  Invalidate memories matching a pattern.

  ## Options
  - `:reason` - Why this is being invalidated
  - `:replacement` - What replaces it (creates new entry with supersedes link)
  - `:weaken_factor` - Multiply half-life by this (default: 0.1)
  """
  def invalidate(scope_id, pattern, opts \\ []) do
    reason = Keyword.get(opts, :reason, "manual_invalidation")
    replacement = Keyword.get(opts, :replacement)
    weaken_factor = Keyword.get(opts, :weaken_factor, @default_weaken_factor)

    {_, meta} =
      Telemetry.span([:recollect, :invalidate], %{scope_id: scope_id, pattern: pattern, reason: reason}, fn ->
        count = weaken_matching(scope_id, pattern, weaken_factor)

        replacement_created =
          if replacement do
            case Knowledge.remember(replacement,
                   scope_id: scope_id,
                   entry_type: "note",
                   metadata: %{supersedes: pattern, reason: reason},
                   source: "system"
                 ) do
              {:ok, _} -> true
              _ -> false
            end
          else
            false
          end

        {%{
           invalidated: count,
           replacement_created: replacement_created
         },
         %{
           invalidated: count,
           replacement_created: replacement_created
         }}
      end)

    {:ok, meta}
  end

  @doc """
  Detect migration patterns in recent git commits.

  Options: `:cd` — repository directory to scan (defaults to the current
  working directory; pass the workspace root when the host process does
  not live inside the repo of interest).
  """
  def detect_migrations(days \\ 7, opts \\ []) do
    cmd_opts =
      case Keyword.get(opts, :cd) do
        nil -> [stderr_to_stdout: true]
        dir -> [stderr_to_stdout: true, cd: dir]
      end

    case System.cmd("git", ["log", "--since=#{days} days", "--pretty=format:%s"], cmd_opts) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_migration/1)

      _ ->
        []
    end
  rescue
    # e.g. :cd points at a directory that vanished
    _ -> []
  end

  # Private

  defp parse_migration(subject) do
    Enum.reduce(@migration_patterns, [], fn pattern, acc ->
      case Regex.run(pattern, subject) do
        [_, from, to] ->
          [%{type: :migration, from: from, to: to, subject: subject} | acc]

        _ ->
          acc
      end
    end)
  end

  defp weaken_related(scope_id, from_concept, _to_concept) do
    # Find entries mentioning the old concept; only entries still above the
    # half-life floor are worth weakening.
    weaken_query(scope_id, from_concept, @default_weaken_factor, only_above_floor: true)
  end

  defp weaken_matching(scope_id, pattern, factor) do
    weaken_query(scope_id, pattern, factor, only_above_floor: false)
  end

  # MEM-011: was raw GREATEST/ILIKE SQL (Postgres-only). LOWER()+LIKE matches
  # case-insensitively on both dialects, and CASE replaces GREATEST (which is
  # spelled MAX() on SQLite/libSQL) so no dialect branch is needed at all.
  defp weaken_query(scope_id, concept, factor, only_above_floor: only_above_floor) do
    repo = Config.repo()
    pattern = "%#{String.downcase(concept)}%"
    now = DateTime.utc_now()

    query =
      from(e in Recollect.Schema.Entry,
        where: e.scope_id == ^scope_id,
        where: e.entry_type != "archived",
        where: fragment("LOWER(?) LIKE ?", e.content, ^pattern)
      )

    query =
      if only_above_floor do
        from(e in query, where: e.half_life_days > 0.5)
      else
        query
      end

    {count, _} =
      repo.update_all(
        from(e in query,
          update: [
            set: [
              half_life_days:
                fragment(
                  "CASE WHEN half_life_days * ? > 0.5 THEN half_life_days * ? ELSE 0.5 END",
                  ^factor,
                  ^factor
                ),
              confidence:
                fragment(
                  "CASE WHEN confidence * ? > 0.05 THEN confidence * ? ELSE 0.05 END",
                  ^factor,
                  ^factor
                ),
              updated_at: ^now
            ]
          ]
        ),
        []
      )

    count
  end
end
