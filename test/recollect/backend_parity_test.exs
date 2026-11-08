defmodule Recollect.BackendParityTest do
  @moduledoc """
  MEM-011 ratchet: keeps Postgres-only SQL from leaking into
  adapter-agnostic modules.

  Two contracts:

  1. Modules converted to Ecto must stay raw-SQL free.
  2. Bare `$N` placeholders may only appear in the allowlist of modules that
     carry explicit, documented dialect branches (or are the Postgres
     backend by name). Adding a new file to the allowlist requires a
     dialect branch and a comment justifying it.
  """
  use ExUnit.Case, async: true

  @lib_root Path.expand("../../lib/recollect", __DIR__)

  @ecto_only_modules ~w(
    confidence.ex
    conflicts.ex
    consolidation.ex
    handoff.ex
    invalidation.ex
    outcome.ex
    knowledge.ex
    schema_index.ex
    schema_fit.ex
    conflict_detection.ex
  )

  # Files allowed to contain $N placeholders — each must carry a dialect
  # branch (or BE the Postgres backend).
  @placeholder_allowlist %{
    "database_adapter.ex" => "adapter layer: defines the placeholder contract",
    "postgres.ex" => "the Postgres adapter itself",
    "postgres_graph.ex" => "the explicitly Postgres graph backend (behaviour-swappable)",
    "vector.ex" => "entries_query/2 and chunks_query have :postgres and :sqlite branches",
    "graph.ex" => "recursive-CTE graph traversal is Postgres-only for now",
    "generator.ex" => "mipmap persist/retrieve branch on dialect",
    "embedder.ex" => "store_embedding/update_summary branch on dialect",
    "retrieval_counter.ex" => "bulk unnest UPDATE is the :postgres branch; other dialects take the per-row path",
    "reembed.ex" => "dialect-branched embedding UPDATE",
    "dream.ex" =>
      "advisory-lock session SQL is the :postgres branch (try/wait); SQLite/libSQL takes the :global.trans path"
  }

  test "converted modules contain no raw SQL" do
    for file <- @ecto_only_modules do
      path = Path.join(@lib_root, file)
      assert File.exists?(path), "expected #{path} to exist"

      content = File.read!(path)

      refute content =~ ~r/\b(repo|Repo)\.query[!(]?[\s(]/,
             "#{file} must use Ecto queries, not repo.query — MEM-011 regression"

      refute content =~ ~r/Ecto\.Adapters\.SQL\.query/,
             "#{file} must use Ecto queries, not Ecto.Adapters.SQL.query — MEM-011 regression"
    end
  end

  test "bare $N placeholders appear only in the dialect-branched allowlist" do
    offenders =
      @lib_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        content = File.read!(path)
        Regex.match?(~r/\$\d+/, content) and not Map.has_key?(@placeholder_allowlist, Path.basename(path))
      end)
      |> Enum.map(&Path.relative_to(&1, @lib_root))

    assert offenders == [],
           "bare $N placeholders outside the dialect-branched allowlist: #{inspect(offenders)}"
  end

  test "every allowlisted file documents its dialect branch" do
    for {file, _reason} <- @placeholder_allowlist do
      matching =
        @lib_root
        |> Path.join("**/#{file}")
        |> Path.wildcard()

      for path <- matching do
        content = File.read!(path)

        assert content =~ ~r/dialect/i,
               "#{file} is allowlisted for $N placeholders but mentions no dialect branch"
      end
    end
  end
end
