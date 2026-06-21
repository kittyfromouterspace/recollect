defmodule Recollect.Graph.PostgresGraphTest do
  @moduledoc """
  Regression: graph queries must accept UUID *string* ids (e.g. a host app's
  constant owner_id) — they were bound straight to `$::uuid` params, which
  Postgrex rejects ("expected a binary of 16 bytes"), crashing tier `:both`
  search whenever entities exist.
  """
  use Recollect.DataCase, async: false

  alias Recollect.Graph.PostgresGraph

  test "get_neighbors/3 accepts string uuids (no EncodeError) and returns [] on an empty graph" do
    owner = Ecto.UUID.generate()
    entity = Ecto.UUID.generate()

    assert {:ok, []} = PostgresGraph.get_neighbors(owner, entity, 1)
  end

  test "get_relations/2 accepts string uuids" do
    owner = Ecto.UUID.generate()
    entity = Ecto.UUID.generate()

    assert {:ok, []} = PostgresGraph.get_relations(owner, entity)
  end

  test "also accepts already-binary uuids (idempotent conversion)" do
    owner = Ecto.UUID.generate() |> Ecto.UUID.dump() |> elem(1)
    entity = Ecto.UUID.generate() |> Ecto.UUID.dump() |> elem(1)

    assert {:ok, []} = PostgresGraph.get_neighbors(owner, entity, 1)
    assert {:ok, []} = PostgresGraph.get_relations(owner, entity)
  end
end
