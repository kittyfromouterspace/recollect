defmodule Mix.Tasks.Recollect.BackfillTags do
  @shortdoc "Backfill recollect_entry_tags from entries' metadata[\"tags\"]"

  @moduledoc """
  One-shot backfill for hosts upgrading past MEM-005: entries written before
  the tags table existed may carry a `tags` list inside `metadata`. This task
  copies those into `recollect_entry_tags` (normalized: trimmed, downcased,
  deduped) in batches, idempotently.

      mix recollect.backfill_tags                 # backfill, 500-entry batches
      mix recollect.backfill_tags --batch 1000
      mix recollect.backfill_tags --dry-run       # report only

  Safe to re-run: insert conflicts are ignored. Run it once after mirroring
  the entry_tags migration (`mix recollect.migration_status` tells you when
  the mirror is stale).
  """

  use Mix.Task

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Knowledge
  alias Recollect.Schema.EntryTag

  @switches [batch: :integer, dry_run: :boolean]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    batch_size = Keyword.get(opts, :batch, 500)
    dry_run = Keyword.get(opts, :dry_run, false)

    Mix.Task.run("app.start")

    repo = Config.repo()

    total = backfill(repo, batch_size, dry_run, 0, 0)

    verb = if dry_run, do: "would backfill", else: "backfilled"
    Mix.shell().info("#{verb} tags for #{total} entr#{if total == 1, do: "y", else: "ies"}")
  end

  defp backfill(repo, batch_size, dry_run, offset, acc) do
    # Portable: no jsonb operators — metadata is a map by the time Ecto hands
    # it over, so the "has tags?" filter runs in Elixir. Fine for a one-shot
    # backfill; the batch walk keeps memory bounded.
    entries =
      repo.all(
        from(e in "recollect_entries",
          order_by: [asc: :id],
          limit: ^batch_size,
          offset: ^offset,
          select: %{id: e.id, scope_id: e.scope_id, owner_id: e.owner_id, metadata: e.metadata}
        )
      )

    case entries do
      [] ->
        acc

      batch ->
        rows =
          Enum.flat_map(batch, fn e ->
            tags = if is_map(e.metadata), do: Map.get(e.metadata, "tags", []), else: []

            # Schemaless select returns raw 16-byte binaries; the
            # schema-typed insert_all wants string UUIDs.
            entry_id = Ecto.UUID.load!(e.id)
            scope_id = e.scope_id && Ecto.UUID.load!(e.scope_id)
            owner_id = e.owner_id && Ecto.UUID.load!(e.owner_id)

            tags
            |> Knowledge.normalize_tags()
            |> Enum.map(fn tag ->
              %{entry_id: entry_id, tag: tag, scope_id: scope_id, owner_id: owner_id}
            end)
          end)

        if !(dry_run or rows == []) do
          repo.insert_all(EntryTag, rows, on_conflict: :nothing, conflict_target: [:entry_id, :tag])
        end

        tagged = Enum.count(batch, fn e -> is_map(e.metadata) and Map.get(e.metadata, "tags", []) != [] end)
        backfill(repo, batch_size, dry_run, offset + length(batch), acc + tagged)
    end
  end
end
