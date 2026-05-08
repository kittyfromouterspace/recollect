defmodule Recollect.Pipeline.Extractor do
  @moduledoc """
  Extracts entities and relationships from text chunks using LLM structured output.
  Deduplicates and persists results with mention counting.
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Schema.Entity
  alias Recollect.Schema.Relation

  require Logger

  @entity_types Entity.entity_types()
  @relation_types Relation.relation_types()

  @doc """
  Extract entities and relations from a chunk's content using the configured provider.
  """
  def extract_from_chunk(chunk_content, opts \\ []) do
    start_time = System.monotonic_time()
    provider = Config.extraction_provider()
    provider_opts = Keyword.merge(Config.extraction_opts(), opts)
    result = provider.extract(chunk_content, provider_opts)
    duration = System.monotonic_time() - start_time

    case result do
      {:ok, %{entities: entities, relations: relations}} ->
        Recollect.Telemetry.event([:recollect, :extract, :stop], %{
          duration: duration,
          entities_count: length(entities),
          relations_count: length(relations)
        })

      _ ->
        Recollect.Telemetry.event([:recollect, :extract, :stop], %{
          duration: duration,
          entities_count: 0,
          relations_count: 0
        })
    end

    result
  end

  @doc """
  Persist extracted entities into the database, deduplicating by name+type
  within the same collection. Returns `{:ok, [entity]}`.
  """
  def persist_entities(entities, opts) do
    collection_id = Keyword.fetch!(opts, :collection_id)
    owner_id = Keyword.fetch!(opts, :owner_id)
    scope_id = Keyword.get(opts, :scope_id)
    repo = Config.repo()

    Enum.reduce_while(entities, {:ok, []}, fn entity_data, {:ok, acc} ->
      case upsert_entity(entity_data, collection_id, owner_id, scope_id, repo) do
        {:ok, entity} -> {:cont, {:ok, acc ++ [entity]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Persist extracted relations. Requires a map of entity_name -> entity_id.
  """
  def persist_relations(relations, entity_map, opts) do
    owner_id = Keyword.fetch!(opts, :owner_id)
    scope_id = Keyword.get(opts, :scope_id)
    source_chunk_id = Keyword.get(opts, :source_chunk_id)
    repo = Config.repo()

    Enum.reduce_while(relations, {:ok, []}, fn rel_data, {:ok, acc} ->
      from_key = normalize_name(rel_data["from"] || rel_data[:from])
      to_key = normalize_name(rel_data["to"] || rel_data[:to])
      from_id = Map.get(entity_map, from_key)
      to_id = Map.get(entity_map, to_key)

      if from_id && to_id && from_id != to_id do
        case upsert_relation(from_id, to_id, rel_data, owner_id, scope_id, source_chunk_id, repo) do
          {:ok, relation} -> {:cont, {:ok, acc ++ [relation]}}
          {:error, _reason} -> {:cont, {:ok, acc}}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp upsert_entity(entity_data, collection_id, owner_id, scope_id, repo) do
    name = normalize_name(entity_data["name"] || entity_data[:name])
    entity_type = to_string(entity_data["type"] || entity_data[:entity_type])

    if entity_type in @entity_types do
      existing =
        repo.one(
          from(e in Entity,
            where: e.collection_id == ^collection_id and e.name == ^name and e.entity_type == ^entity_type
          )
        )

      case existing do
        nil ->
          changeset =
            Entity.changeset(%Entity{}, %{
              collection_id: collection_id,
              name: name,
              entity_type: entity_type,
              description: entity_data["description"] || entity_data[:description],
              mention_count: 1,
              first_seen_at: DateTime.utc_now(),
              last_seen_at: DateTime.utc_now(),
              owner_id: owner_id,
              scope_id: scope_id
            })

          case repo.insert(changeset) do
            {:ok, entity} ->
              Config.on_graph_change().(%{
                type: :entity,
                operation: :insert,
                data: %{
                  id: entity.id,
                  name: entity.name,
                  entity_type: entity.entity_type,
                  owner_id: owner_id,
                  scope_id: scope_id
                }
              })

              {:ok, entity}

            error ->
              error
          end

        entity ->
          case repo.update(Entity.increment_mentions_changeset(entity)) do
            {:ok, updated} ->
              Config.on_graph_change().(%{
                type: :entity,
                operation: :update,
                data: %{
                  id: updated.id,
                  name: updated.name,
                  entity_type: updated.entity_type,
                  owner_id: owner_id,
                  scope_id: scope_id
                }
              })

              {:ok, updated}

            error ->
              error
          end
      end
    else
      {:error, "Invalid entity type: #{entity_type}"}
    end
  end

  defp upsert_relation(from_id, to_id, rel_data, owner_id, scope_id, source_chunk_id, repo) do
    relation_type = to_string(rel_data["type"] || rel_data[:relation_type])
    weight = parse_weight(rel_data["weight"] || rel_data[:weight])

    if relation_type in @relation_types do
      existing =
        repo.one(
          from(r in Relation,
            where: r.from_entity_id == ^from_id and r.to_entity_id == ^to_id and r.relation_type == ^relation_type
          )
        )

      case existing do
        nil ->
          changeset =
            Relation.changeset(%Relation{}, %{
              from_entity_id: from_id,
              to_entity_id: to_id,
              relation_type: relation_type,
              weight: weight,
              source_chunk_id: source_chunk_id,
              owner_id: owner_id,
              scope_id: scope_id
            })

          case repo.insert(changeset) do
            {:ok, relation} ->
              Config.on_graph_change().(%{
                type: :relation,
                operation: :insert,
                data: %{
                  id: relation.id,
                  relation_type: relation.relation_type,
                  from_entity_id: from_id,
                  to_entity_id: to_id,
                  owner_id: owner_id,
                  scope_id: scope_id
                }
              })

              {:ok, relation}

            error ->
              error
          end

        relation ->
          new_weight = (relation.weight + weight) / 2.0

          case repo.update(Relation.changeset(relation, %{weight: new_weight})) do
            {:ok, updated} ->
              Config.on_graph_change().(%{
                type: :relation,
                operation: :update,
                data: %{
                  id: updated.id,
                  relation_type: updated.relation_type,
                  from_entity_id: from_id,
                  to_entity_id: to_id,
                  owner_id: owner_id,
                  scope_id: scope_id
                }
              })

              {:ok, updated}

            error ->
              error
          end
      end
    else
      {:error, "Invalid relation type: #{relation_type}"}
    end
  end

  defp normalize_name(name) when is_binary(name), do: name |> String.downcase() |> String.trim()
  defp normalize_name(_), do: ""

  defp parse_weight(w) when is_float(w), do: min(max(w, 0.0), 1.0)
  defp parse_weight(w) when is_integer(w), do: min(max(w / 1.0, 0.0), 1.0)
  defp parse_weight(_), do: 0.5
end
