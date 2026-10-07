defmodule Recollect.Repo.Migrations.MipmapEmbeddingToVector do
  @moduledoc """
  `recollect_mipmaps.embedding` was created as `bytea`, but `Mipmap.persist/1`
  writes a pgvector and `Mipmap.retrieve/3` orders by `<=>` — every write
  failed to encode and every search errored (`operator does not exist:
  bytea <=> vector`). No mipmap ever persisted, so the column holds nothing
  worth converting; it is reset to NULL.
  """
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE recollect_mipmaps
      ALTER COLUMN embedding TYPE vector(1536) USING NULL
    """)
  end

  def down do
    execute("""
    ALTER TABLE recollect_mipmaps
      ALTER COLUMN embedding TYPE bytea USING NULL
    """)
  end
end
