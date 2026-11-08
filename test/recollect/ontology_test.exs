defmodule Recollect.OntologyTest do
  use Recollect.DataCase, async: false

  alias Recollect.Ontology
  alias Recollect.Pipeline.Extractor
  alias Recollect.Schema.Entity
  alias Recollect.Schema.Relation

  describe "normalize_entity_type/1" do
    test "canonical types pass through, case/space/hyphen variants handled" do
      assert Ontology.normalize_entity_type("person") == "person"
      assert Ontology.normalize_entity_type("Person") == "person"
      assert Ontology.normalize_entity_type("credential_ref") == "credential_ref"
      assert Ontology.normalize_entity_type("credential-ref") == "credential_ref"
      assert Ontology.normalize_entity_type("Credential Ref") == "credential_ref"
      assert Ontology.normalize_entity_type(:project) == "project"
    end

    test "synonyms map to canonical types" do
      assert Ontology.normalize_entity_type("daemon") == "service"
      assert Ontology.normalize_entity_type("app") == "service"
      assert Ontology.normalize_entity_type("application") == "service"
      assert Ontology.normalize_entity_type("machine") == "host"
      assert Ontology.normalize_entity_type("server") == "host"
      assert Ontology.normalize_entity_type("bug") == "incident"
      assert Ontology.normalize_entity_type("outage") == "incident"
      assert Ontology.normalize_entity_type("API Key") == "credential_ref"
      assert Ontology.normalize_entity_type("repo") == "project"
    end

    test "unknown types come back as custom" do
      assert Ontology.normalize_entity_type("gizmo") == {:custom, "gizmo"}
      assert Ontology.normalize_entity_type("Weird Thing") == {:custom, "weird_thing"}
    end

    test "application env extends the vocabulary" do
      Application.put_env(:recollect, :ontology,
        entity_types: ["workspace"],
        entity_synonyms: %{"ws" => "workspace"}
      )

      try do
        assert Ontology.normalize_entity_type("workspace") == "workspace"
        assert Ontology.normalize_entity_type("ws") == "workspace"
      after
        Application.delete_env(:recollect, :ontology)
      end
    end
  end

  describe "normalize_relation/1" do
    test "canonical relations pass through" do
      assert Ontology.normalize_relation("depends_on") == "depends_on"
      assert Ontology.normalize_relation("fixes") == "fixes"
      assert Ontology.normalize_relation("deployed_on") == "deployed_on"
    end

    test "synonyms map to canonical relations" do
      assert Ontology.normalize_relation("requires") == "depends_on"
      assert Ontology.normalize_relation("related_to") == "relates_to"
      assert Ontology.normalize_relation("runs on") == "deployed_on"
      assert Ontology.normalize_relation("blocked_by") == "blocks"
    end

    test "unknown relations come back as custom" do
      assert Ontology.normalize_relation("worships") == {:custom, "worships"}
    end
  end

  describe "extractor integration" do
    setup do
      llm_fn = fn _messages, _opts ->
        {:ok, ~s({"entities": [
           {"name": "api server", "type": "server", "description": "the API host"},
           {"name": "flux capacitor", "type": "gizmo", "description": "custom hardware"}
         ],
         "relations": [
           {"from": "flux capacitor", "to": "api server", "type": "requires", "weight": 0.9}
         ]})}
      end

      Application.put_env(:recollect, :extraction, llm_fn: llm_fn)
      on_exit(fn -> Application.delete_env(:recollect, :extraction) end)

      collection = Fixtures.collection()
      {:ok, collection: collection}
    end

    test "canonical types applied, custom kept and flagged", %{collection: collection} do
      assert {:ok, %{entities: entities, relations: relations}} =
               Extractor.extract_from_chunk("the flux capacitor requires the api server")

      assert Enum.find(entities, &(&1["name"] == "api server"))["type"] == "host"

      custom = Enum.find(entities, &(&1["name"] == "flux capacitor"))
      assert custom["type"] == "gizmo"
      assert custom["custom_type"] == true

      assert [%{"type" => "depends_on"}] = relations

      {:ok, persisted} =
        Extractor.persist_entities(entities,
          collection_id: collection.id,
          owner_id: collection.owner_id,
          scope_id: collection.scope_id
        )

      host_entity = Enum.find(persisted, &(&1.entity_type == "host"))
      assert host_entity.name == "api server"
      refute host_entity.properties["custom_type"]

      custom_entity = Enum.find(persisted, &(&1.entity_type == "gizmo"))
      assert custom_entity.properties["custom_type"] == true

      entity_map = Map.new(persisted, fn e -> {e.name, e.id} end)

      {:ok, [relation]} =
        Extractor.persist_relations(relations, entity_map,
          owner_id: collection.owner_id,
          scope_id: collection.scope_id
        )

      assert relation.relation_type == "depends_on"
    end
  end

  describe "report/0" do
    test "returns vocabulary usage with custom counts" do
      collection = Fixtures.collection()

      Fixtures.entity(
        collection: collection,
        name: "kai",
        entity_type: "person",
        owner_id: collection.owner_id,
        scope_id: collection.scope_id
      )

      [
        collection: collection,
        name: "flux capacitor",
        entity_type: "gizmo",
        owner_id: collection.owner_id,
        scope_id: collection.scope_id
      ]
      |> Fixtures.entity()
      |> then(fn entity ->
        entity
        |> Ecto.Changeset.change(%{properties: %{"custom_type" => true}})
        |> Config.repo().update!()
      end)

      {:ok, _relation} =
        %Relation{}
        |> Relation.changeset(%{
          from_entity_id: Config.repo().get_by!(Entity, name: "kai").id,
          to_entity_id: Config.repo().get_by!(Entity, name: "flux capacitor").id,
          relation_type: "depends_on",
          owner_id: collection.owner_id,
          scope_id: collection.scope_id
        })
        |> Config.repo().insert()

      report = Ontology.report()

      assert report.entity_types["person"] == 1
      assert report.entity_types["gizmo"] == 1
      assert report.relation_types["depends_on"] == 1
      assert report.custom_entity_types == 1
      assert report.custom_relation_types == 0
    end
  end
end
