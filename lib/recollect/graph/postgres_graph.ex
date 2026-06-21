defmodule Recollect.Graph.PostgresGraph do
  @moduledoc """
  Graph store implementation using PostgreSQL recursive CTEs.
  Queries the recollect_entities and recollect_relations tables directly.
  """
  @behaviour Recollect.GraphStore

  alias Recollect.Config
  alias Recollect.Util

  require Logger

  @impl true
  def get_neighbors(owner_id, entity_id, hops) do
    repo = Config.repo()

    sql = """
    WITH RECURSIVE graph_walk AS (
      -- Direct neighbors
      SELECT
        CASE
          WHEN r.from_entity_id = $1::uuid THEN r.to_entity_id
          ELSE r.from_entity_id
        END AS entity_id,
        1 AS depth
      FROM recollect_relations r
      WHERE (r.from_entity_id = $1::uuid OR r.to_entity_id = $1::uuid)
        AND r.owner_id = $2::uuid

      UNION ALL

      -- N-hop expansion
      SELECT
        CASE
          WHEN r.from_entity_id = gw.entity_id THEN r.to_entity_id
          ELSE r.from_entity_id
        END,
        gw.depth + 1
      FROM graph_walk gw
      JOIN recollect_relations r ON (r.from_entity_id = gw.entity_id OR r.to_entity_id = gw.entity_id)
      WHERE gw.depth < $3
        AND r.owner_id = $2::uuid
    )
    SELECT DISTINCT
      e.id, e.name, e.entity_type, e.description, e.mention_count
    FROM graph_walk gw
    JOIN recollect_entities e ON e.id = gw.entity_id
    WHERE e.id != $1::uuid
    LIMIT 50
    """

    # UUID params must be 16-byte binaries for the `$::uuid` casts. owner_id often
    # arrives as a UUID string (e.g. the host app's constant owner) — convert both
    # (uuid_to_bin is idempotent, so already-binary entity ids pass through).
    case repo.query(sql, [Util.uuid_to_bin(entity_id), Util.uuid_to_bin(owner_id), hops]) do
      {:ok, %{rows: rows}} ->
        entities =
          Enum.map(rows, fn [id, name, type, desc, mentions] ->
            %{
              id: id,
              name: name,
              entity_type: type,
              description: desc,
              mention_count: mentions || 0
            }
          end)

        {:ok, entities}

      {:error, reason} ->
        Logger.error("PostgresGraph.get_neighbors failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def get_relations(owner_id, entity_id) do
    repo = Config.repo()

    sql = """
    SELECT
      r.from_entity_id, r.to_entity_id, r.relation_type, r.weight
    FROM recollect_relations r
    WHERE (r.from_entity_id = $1::uuid OR r.to_entity_id = $1::uuid)
      AND r.owner_id = $2::uuid
    """

    case repo.query(sql, [Util.uuid_to_bin(entity_id), Util.uuid_to_bin(owner_id)]) do
      {:ok, %{rows: rows}} ->
        relations =
          Enum.map(rows, fn [from_id, to_id, type, weight] ->
            %{
              from_id: from_id,
              to_id: to_id,
              relation_type: type,
              weight: weight
            }
          end)

        {:ok, relations}

      {:error, reason} ->
        Logger.error("PostgresGraph.get_relations failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
