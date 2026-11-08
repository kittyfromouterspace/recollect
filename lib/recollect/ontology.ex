defmodule Recollect.Ontology do
  @moduledoc """
  Ontology-lite: a small canonical vocabulary for entity types and relation
  types, plus synonym mapping, so the knowledge graph converges on shared
  terms instead of accumulating near-duplicates ("server" vs "machine" vs
  "host").

  Canonical types are the default vocabulary; anything else is kept as a
  custom type (flagged `custom_type: true` in properties at persist time)
  rather than rejected.

  ## Extension

  Host apps extend the vocabulary via application env:

      config :recollect, :ontology,
        entity_types: ["workspace"],
        relations: ["reviews"],
        entity_synonyms: %{"ws" => "workspace"},
        relation_synonyms: %{"reviews_code" => "reviews"}
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Schema.Entity
  alias Recollect.Schema.Relation

  @canonical_entity_types ~w(
    person project tool service host concept incident ticket runbook
    obstacle goal decision dependency config credential_ref
  )

  @canonical_relations ~w(
    depends_on causes fixes supersedes relates_to part_of owns deployed_on
    configured_by blocks
  )

  @entity_synonyms %{
    "daemon" => "service",
    "app" => "service",
    "application" => "service",
    "machine" => "host",
    "server" => "host",
    "vm" => "host",
    "node" => "host",
    "bug" => "incident",
    "outage" => "incident",
    "defect" => "incident",
    "human" => "person",
    "user" => "person",
    "individual" => "person",
    "repo" => "project",
    "repository" => "project",
    "library" => "tool",
    "library_ref" => "tool",
    "utility" => "tool",
    "issue" => "ticket",
    "task" => "ticket",
    "run_book" => "runbook",
    "playbook" => "runbook",
    "blocker" => "obstacle",
    "objective" => "goal",
    "resolution" => "decision",
    "setting" => "config",
    "configuration" => "config",
    "secret" => "credential_ref",
    "credential" => "credential_ref",
    "credentials" => "credential_ref",
    "api_key" => "credential_ref",
    "idea" => "concept"
  }

  @relation_synonyms %{
    "requires" => "depends_on",
    "needs" => "depends_on",
    "triggers" => "causes",
    "leads_to" => "causes",
    "repairs" => "fixes",
    "resolves" => "fixes",
    "replaces" => "supersedes",
    "related_to" => "relates_to",
    "references" => "relates_to",
    "contains" => "part_of",
    "belongs_to" => "part_of",
    "member_of" => "part_of",
    "maintains" => "owns",
    "runs_on" => "deployed_on",
    "hosted_on" => "deployed_on",
    "configured_with" => "configured_by",
    "blocked_by" => "blocks"
  }

  @doc "Canonical entity types (configured extensions included)."
  def entity_types do
    @canonical_entity_types ++ configured(:entity_types)
  end

  @doc "Canonical relation types (configured extensions included)."
  def relation_types do
    @canonical_relations ++ configured(:relations)
  end

  @doc """
  Normalize an entity type to its canonical form.

  Returns the canonical type string, or `{:custom, normalized}` when the
  type is not part of the vocabulary. Downcasing and space/hyphen variants
  are handled ("API Key" → "credential_ref").
  """
  def normalize_entity_type(type) do
    normalized = normalize_term(type)

    cond do
      normalized in entity_types() -> normalized
      synonym = entity_synonyms()[normalized] -> synonym
      true -> {:custom, normalized}
    end
  end

  @doc """
  Normalize a relation type to its canonical form.

  Same contract as `normalize_entity_type/1`.
  """
  def normalize_relation(relation) do
    normalized = normalize_term(relation)

    cond do
      normalized in relation_types() -> normalized
      synonym = relation_synonyms()[normalized] -> synonym
      true -> {:custom, normalized}
    end
  end

  @doc """
  Apply ontology normalization to an extracted entity map.

  Canonical types are applied in place; custom types are kept and flagged
  with `"custom_type" => true` so persistence can record the flag in the
  entity's properties.
  """
  def apply_entity_type(entity) when is_map(entity) do
    raw = entity["type"] || entity[:type] || entity[:entity_type]

    case normalize_entity_type(raw) do
      {:custom, custom} ->
        entity
        |> Map.put("type", custom)
        |> Map.put("custom_type", true)

      canonical ->
        entity
        |> Map.put("type", canonical)
        |> Map.delete("custom_type")
    end
  end

  @doc "Apply ontology normalization to an extracted relation map."
  def apply_relation_type(relation) when is_map(relation) do
    raw = relation["type"] || relation[:type] || relation[:relation_type]

    case normalize_relation(raw) do
      {:custom, custom} ->
        relation
        |> Map.put("type", custom)
        |> Map.put("custom_type", true)

      canonical ->
        relation
        |> Map.put("type", canonical)
        |> Map.delete("custom_type")
    end
  end

  @doc """
  Vocabulary usage report from the database.

  Returns counts per entity/relation type plus the number of rows carrying a
  custom (non-canonical) type:

      %{entity_types: %{"person" => 3, ...}, relation_types: %{...},
        custom_entity_types: 1, custom_relation_types: 0}
  """
  def report do
    repo = Config.repo()

    entity_counts =
      from(e in Entity,
        group_by: e.entity_type,
        select: {e.entity_type, count(e.id)}
      )
      |> repo.all()
      |> Map.new()

    relation_counts =
      from(r in Relation,
        group_by: r.relation_type,
        select: {r.relation_type, count(r.id)}
      )
      |> repo.all()
      |> Map.new()

    canonical_entities = MapSet.new(entity_types())
    canonical_relations = MapSet.new(relation_types())

    %{
      entity_types: entity_counts,
      relation_types: relation_counts,
      custom_entity_types: custom_count(entity_counts, canonical_entities),
      custom_relation_types: custom_count(relation_counts, canonical_relations)
    }
  end

  defp custom_count(counts, canonical) do
    counts
    |> Enum.reject(fn {type, _count} -> MapSet.member?(canonical, type) end)
    |> Enum.map(fn {_type, count} -> count end)
    |> Enum.sum()
  end

  defp normalize_term(term) when is_atom(term), do: term |> Atom.to_string() |> normalize_term()

  defp normalize_term(term) when is_binary(term) do
    term
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[\s\-]+/, "_")
  end

  defp normalize_term(_), do: ""

  defp entity_synonyms do
    Map.merge(@entity_synonyms, configured(:entity_synonyms))
  end

  defp relation_synonyms do
    Map.merge(@relation_synonyms, configured(:relation_synonyms))
  end

  defp configured(key) do
    :recollect
    |> Application.get_env(:ontology, [])
    |> Keyword.get(key, default_for(key))
    |> normalize_configured(key)
  end

  defp default_for(key) when key in [:entity_synonyms, :relation_synonyms], do: %{}
  defp default_for(_), do: []

  # Configured synonyms arrive with user-controlled keys; normalize them to
  # the same downcased/underscored form the lookup path uses.
  defp normalize_configured(synonyms, key) when is_map(synonyms) and key in [:entity_synonyms, :relation_synonyms] do
    Map.new(synonyms, fn {from, to} -> {normalize_term(from), normalize_term(to)} end)
  end

  defp normalize_configured(types, _key) when is_list(types) do
    Enum.map(types, &normalize_term/1)
  end

  defp normalize_configured(_other, key), do: default_for(key)
end
