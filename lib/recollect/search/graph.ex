defmodule Recollect.Search.Graph do
  @moduledoc """
  Graph-based search using PostgreSQL recursive CTEs.
  Provides neighborhood expansion and relation queries.

  This module is Postgres-only by design: the traversal relies on recursive
  CTEs with `ANY($N)` array bindings, which have no portable equivalent.
  There is no dialect branch here — SQLite/libSQL hosts should swap the
  graph backend (see `Recollect.GraphStore`) instead.
  """

  alias Recollect.Config

  require Logger

  @doc """
  Get the subgraph around an entity within N hops.

  ## Options
  - `:owner_id` (required) — scope
  - `:hops` — traversal depth (default: 2)
  """
  def neighborhood(entity_id, opts \\ []) do
    owner_id = Keyword.fetch!(opts, :owner_id)
    hops = Keyword.get(opts, :hops, 2)

    Recollect.GraphStore.impl().get_neighbors(owner_id, entity_id, hops)
  end

  @doc """
  Get all relations for an entity.

  ## Options
  - `:owner_id` (required)
  """
  def relations(entity_id, opts \\ []) do
    owner_id = Keyword.fetch!(opts, :owner_id)
    Recollect.GraphStore.impl().get_relations(owner_id, entity_id)
  end

  @doc """
  Follow edges from entry IDs (Tier 2 lightweight edges).
  Returns related entries within N hops.

  Entries superseded via a `"supersedes"` edge are excluded unless
  `include_superseded: true` is passed.
  """
  def follow_edges(entry_ids, opts \\ []) when is_list(entry_ids) do
    hops = Keyword.get(opts, :hops, 1)
    limit = Keyword.get(opts, :limit, 5)
    include_superseded = Keyword.get(opts, :include_superseded, false)
    repo = Config.repo()

    if entry_ids == [] do
      {:ok, []}
    else
      bin_ids = entry_ids |> Enum.map(&Recollect.Util.uuid_to_bin/1) |> Enum.reject(&is_nil/1)

      superseded_clause =
        if include_superseded do
          ""
        else
          "AND NOT EXISTS (SELECT 1 FROM recollect_edges se WHERE se.target_entry_id = me.id AND se.relation = 'supersedes')"
        end

      sql = """
      WITH RECURSIVE edge_walk AS (
        SELECT target_entry_id AS entry_id, 1 AS depth
        FROM recollect_edges
        WHERE source_entry_id = ANY($1)
        UNION
        SELECT target_entry_id AS entry_id, 1 AS depth
        FROM recollect_edges
        WHERE target_entry_id = ANY($1)
        UNION ALL
        SELECT
          CASE
            WHEN e.source_entry_id = ew.entry_id THEN e.target_entry_id
            ELSE e.source_entry_id
          END,
          ew.depth + 1
        FROM edge_walk ew
        JOIN recollect_edges e ON (e.source_entry_id = ew.entry_id OR e.target_entry_id = ew.entry_id)
        WHERE ew.depth < $2
      )
      SELECT DISTINCT me.id, me.content, me.summary, me.entry_type, me.confidence, me.inserted_at
      FROM edge_walk ew
      JOIN recollect_entries me ON me.id = ew.entry_id
      WHERE me.id != ALL($1)
        AND me.entry_type != 'archived'
        #{superseded_clause}
      LIMIT $3
      """

      case repo.query(sql, [bin_ids, hops, limit]) do
        {:ok, %{rows: rows, columns: columns}} ->
          results =
            Enum.map(rows, fn row ->
              columns
              |> Enum.zip(row)
              |> Map.new()
              |> Map.put("_related", true)
            end)

          {:ok, results}

        {:error, reason} ->
          Logger.error("Recollect edge traversal failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
end
