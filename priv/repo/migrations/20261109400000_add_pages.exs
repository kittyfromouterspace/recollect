defmodule Recollect.Repo.Migrations.AddPages do
  @moduledoc false
  use Ecto.Migration

  # MEM-027: the representation layer — cited wiki pages with slugs,
  # token counts, and source hashes. Also joins the recall-anchor page_id
  # FK deferred from MEM-021.
  def change do
    create table(:recollect_pages, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:owner_id, :binary_id, null: false)
      add(:scope_id, :binary_id)
      add(:slug, :string, null: false)
      add(:title, :string, null: false)
      add(:kind, :string, default: "topic", null: false)
      add(:body_md, :text, null: false)
      add(:summary, :text)
      add(:token_count, :integer, null: false)
      add(:version, :integer, default: 1, null: false)
      add(:source_hash, :string, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:recollect_pages, [:scope_id, :slug], name: :recollect_pages_scope_slug_idx))

    create(index(:recollect_pages, [:scope_id, :kind], name: :recollect_pages_kind_idx))

    create table(:recollect_page_sources, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:page_id, references(:recollect_pages, type: :binary_id, on_delete: :delete_all), null: false)
      add(:entry_id, references(:recollect_entries, type: :binary_id, on_delete: :nilify_all))
      add(:event_id, references(:recollect_events, type: :binary_id, on_delete: :nilify_all))
      add(:source_type, :string, null: false)
      add(:source_ref, :string)
      add(:role, :string, default: "supporting", null: false)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(index(:recollect_page_sources, [:page_id]))

    create(
      unique_index(:recollect_page_sources, [:page_id, :source_type, :source_ref],
        name: :recollect_page_sources_unique_idx,
        where: "source_ref IS NOT NULL"
      )
    )

    alter table(:recollect_recall_anchors) do
      add(:page_id, references(:recollect_pages, type: :binary_id, on_delete: :delete_all))
    end
  end
end
