defmodule Recollect.MipmapPersistTest do
  use Recollect.DataCase, async: false

  # persist/1 never worked against Postgres: the atom level crashed the
  # Postgrex encode (text column) and metadata went in as a JSON string.
  test "persist/1 stores every level as text with object metadata" do
    entry = %{
      id: Ecto.UUID.generate(),
      content: "Always URL-encode the DB password slash as %2F.",
      entry_type: "note",
      tags: [],
      emotional_valence: "neutral"
    }

    assert {:ok, 4} = Recollect.Mipmap.persist(entry)

    %{rows: rows} =
      Recollect.TestRepo.query!(
        "SELECT level, jsonb_typeof(metadata) FROM recollect_mipmaps WHERE entry_id = $1 ORDER BY level",
        [Recollect.Util.uuid_to_bin(entry.id)]
      )

    assert Enum.map(rows, &hd/1) == ~w(abstract anchor full summary)
    assert Enum.all?(rows, fn [_, type] -> type == "object" end)
  end
end
