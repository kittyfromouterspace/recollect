defmodule Recollect.Consolidation do
  @moduledoc """
  Sleep consolidation for memory maintenance.

  Runs a multi-pass consolidation cycle:
  1. Decay pass - remove entries below strength threshold
  2. Merge pass - find overlapping entries, create semantic summaries
  3. Conflict detection - find contradictory memories
  4. Schema index rebuild - update tag frequency index
  5. Persist results - record consolidation run

  Uses Task.async_stream for CPU-bound operations.
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.ConflictDetection
  alias Recollect.Conflicts
  alias Recollect.Schema.Entry
  alias Recollect.SchemaIndex
  alias Recollect.Strength
  alias Recollect.Telemetry

  @default_decay_threshold 0.05
  @default_merge_threshold 0.35
  @default_min_cluster 3

  @doc """
  Run a full consolidation pass for a scope.

  ## Options
  - `:scope_id` - Required. The scope to consolidate.
  - `:decay_threshold` - Minimum strength to survive (default: 0.05)
  - `:merge_threshold` - Text overlap threshold for merging (default: 0.35)
  - `:min_cluster` - Minimum entries to form a merge cluster (default: 3)
  - `:dry_run` - If true, don't persist changes (default: false)

  ## Returns
  ```
  {:ok, %{
    decayed: non_neg_integer(),
    removed: non_neg_integer(),
    merged: non_neg_integer(),
    semantic_created: non_neg_integer(),
    conflicts_detected: non_neg_integer(),
    duration_ms: non_neg_integer()
  }}
  ```
  """
  def run(opts \\ []) do
    scope_id = Keyword.fetch!(opts, :scope_id)
    dry_run = Keyword.get(opts, :dry_run, false)
    decay_threshold = Keyword.get(opts, :decay_threshold, @default_decay_threshold)
    merge_threshold = Keyword.get(opts, :merge_threshold, @default_merge_threshold)
    min_cluster = Keyword.get(opts, :min_cluster, @default_min_cluster)

    start_time = System.monotonic_time()

    # Telemetry.span returns the fun's result verbatim.
    result =
      Telemetry.span([:recollect, :consolidation], %{scope_id: scope_id}, fn ->
        repo = Config.repo()
        owner_id = fetch_owner_id(scope_id, repo)

        entries = fetch_entries(scope_id, repo)

        decay_result = decay_pass(entries, decay_threshold)
        survivors = decay_result.survivors

        merge_result = merge_pass(survivors, merge_threshold, min_cluster, repo, scope_id)

        conflicts = ConflictDetection.detect(scope_id)

        if !dry_run do
          SchemaIndex.rebuild()
        end

        duration_ms =
          System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

        removed_count =
          if dry_run do
            length(decay_result.removed)
          else
            {:ok, archived_count} =
              repo.transaction(fn ->
                {:ok, %{archived: archived_count}} =
                  archive_removed(decay_result.removed, repo)

                persist_consolidation_run(
                  scope_id,
                  owner_id,
                  %{
                    decayed: decay_result.count,
                    removed: archived_count,
                    merged: merge_result.merged,
                    semantic_created: merge_result.semantic_created,
                    conflicts_detected: length(conflicts)
                  },
                  duration_ms
                )

                persist_conflicts(scope_id, owner_id, conflicts)

                create_summary_entries(merge_result.summaries, scope_id, owner_id, repo)

                archived_count
              end)

            archived_count
          end

        %{
          decayed: decay_result.count,
          removed: removed_count,
          merged: merge_result.merged,
          semantic_created: merge_result.semantic_created,
          conflicts_detected: length(conflicts),
          duration_ms: duration_ms
        }
      end)

    {:ok, result}
  end

  defp fetch_entries(scope_id, repo) do
    # Load through the schema so callers get atom-keyed %Entry{} structs with
    # typed fields (the previous raw SELECT returned string-keyed maps that
    # struct/2 silently nil'd out).
    repo.all(
      from(e in Entry,
        where: e.scope_id == ^scope_id and e.entry_type != "archived",
        order_by: [asc: e.id]
      )
    )
  end

  defp fetch_owner_id(scope_id, repo) do
    repo.one(
      from(e in Entry,
        where: e.scope_id == ^scope_id,
        limit: 1,
        select: e.owner_id
      )
    )
  end

  defp decay_pass(entries, threshold) do
    now = DateTime.utc_now()

    {survivors, removed} =
      Enum.split_with(entries, fn %Entry{} = entry ->
        entry.pinned || Strength.calculate(entry, now) >= threshold
      end)

    %{survivors: survivors, removed: removed, count: length(removed)}
  end

  # Persist the decay decision: archive entries below the threshold instead of
  # deleting them, so a rollback can restore them by resetting entry_type.
  defp archive_removed([], _repo), do: {:ok, %{archived: 0}}

  defp archive_removed(entries, repo) do
    ids = Enum.map(entries, & &1.id)

    {archived, _} =
      repo.update_all(
        from(e in Entry, where: e.id in ^ids and e.entry_type != "archived"),
        set: [entry_type: "archived", updated_at: DateTime.utc_now()]
      )

    {:ok, %{archived: archived}}
  end

  defp merge_pass(entries, threshold, min_cluster, _repo, _scope_id) do
    if length(entries) < 2 do
      %{merged: 0, semantic_created: 0, summaries: [], cluster_indices: []}
    else
      pairs =
        for i <- 0..(length(entries) - 2),
            j <- (i + 1)..(length(entries) - 1) do
          {i, j}
        end

      overlaps =
        pairs
        |> Task.async_stream(
          fn {i, j} ->
            a = Enum.at(entries, i)
            b = Enum.at(entries, j)
            {i, j, Recollect.Util.text_overlap(a.content, b.content)}
          end,
          max_concurrency: System.schedulers_online(),
          timeout: 30_000
        )
        |> Enum.flat_map(fn
          {:ok, {i, j, overlap}} when overlap >= threshold -> [{i, j}]
          _ -> []
        end)

      clusters = build_clusters(overlaps, length(entries))

      valid_clusters = Enum.filter(clusters, fn indices -> length(indices) >= min_cluster end)

      summaries =
        if valid_clusters == [] do
          []
        else
          Enum.map(valid_clusters, fn indices ->
            cluster = Enum.map(indices, &Enum.at(entries, &1))
            create_semantic_summary(cluster)
          end)
        end

      %{
        merged: length(List.flatten(valid_clusters)),
        semantic_created: length(summaries),
        summaries: summaries,
        cluster_indices: valid_clusters
      }
    end
  end

  defp build_clusters(overlaps, n) do
    parent =
      Enum.reduce(0..(n - 1), %{}, fn i, acc -> Map.put(acc, i, i) end)

    find = fn find_fn, node ->
      case parent[node] do
        ^node -> node
        p -> find_fn.(find_fn, p)
      end
    end

    union = fn {i, j}, acc ->
      root_i = find.(find, i)
      root_j = find.(find, j)

      if root_i == root_j do
        acc
      else
        Map.put(acc, root_i, root_j)
      end
    end

    parent = Enum.reduce(overlaps, parent, union)

    parent
    |> Enum.group_by(fn {_k, v} -> v end, fn {k, _v} -> k end)
    |> Map.values()
    |> Enum.filter(&(&1 != []))
  end

  defp create_semantic_summary(cluster) do
    base = Enum.max_by(cluster, fn e -> String.length(e.content) end)

    if length(cluster) <= 2 do
      "[Consolidated from #{length(cluster)} related memories]\n\n#{base.content}"
    else
      bullets =
        Enum.map(cluster, fn e ->
          "- #{e.content |> String.split("\n") |> hd() |> String.slice(0, 120)}"
        end)

      "[Consolidated pattern from #{length(cluster)} related memories]\n\n#{Enum.join(bullets, "\n")}"
    end
  end

  defp persist_consolidation_run(scope_id, owner_id, results, duration_ms) do
    repo = Config.repo()
    now = DateTime.utc_now()

    repo.query(
      """
        INSERT INTO recollect_consolidation_runs
          (id, scope_id, owner_id, timestamp, decayed, removed, merged, semantic_created, conflicts_detected, duration_ms)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
      """,
      [
        Ecto.UUID.bingenerate(),
        Recollect.Util.uuid_to_bin(scope_id),
        Recollect.Util.uuid_to_bin(owner_id),
        now,
        results.decayed,
        results.removed,
        results.merged,
        results.semantic_created,
        results.conflicts_detected,
        duration_ms
      ]
    )
  end

  defp persist_conflicts(_scope_id, _owner_id, []), do: {:ok, 0}

  defp persist_conflicts(scope_id, owner_id, conflicts) do
    Conflicts.persist(scope_id, owner_id, conflicts)
  end

  defp create_summary_entries([], _scope_id, _owner_id, _repo), do: {:ok, 0}

  defp create_summary_entries(summaries, scope_id, owner_id, repo) do
    now = DateTime.utc_now()

    for summary <- summaries do
      repo.query(
        """
          INSERT INTO recollect_entries
            (id, scope_id, owner_id, entry_type, content, confidence, half_life_days, pinned, emotional_valence, schema_fit, confidence_state, inserted_at, updated_at)
          VALUES ($1, $2, $3, 'note', $4, 0.8, 14.0, false, 'neutral', 0.6, 'active', $5, $5)
        """,
        [
          Ecto.UUID.bingenerate(),
          Recollect.Util.uuid_to_bin(scope_id),
          Recollect.Util.uuid_to_bin(owner_id),
          summary,
          now
        ]
      )
    end

    {:ok, length(summaries)}
  end
end
