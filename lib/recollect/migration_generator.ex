defmodule Recollect.MigrationGenerator do
  @moduledoc """
  Generates database-specific migration content for Recollect tables.

  This module provides adapter-aware migration generation, allowing
  Recollect to work with different database backends (PostgreSQL, libSQL).

  ## Usage

      # In a migration file
      defmodule MyApp.Repo.Migrations.CreateRecollectTables do
        use Ecto.Migration

        def up do
          Recollect.MigrationGenerator.generate_up(Recollect.DatabaseAdapter.LibSQL, dimensions: 768)
        end

        def down do
          Recollect.MigrationGenerator.generate_down()
        end
      end
  """

  alias Recollect.Config

  @doc """
  Generates the `up` migration content for creating all Recollect tables.

  ## Options

  - `:dimensions` — Vector embedding dimensions (default: 1536)
  - `:table_prefix` — Table prefix (default: "recollect_")
  """
  def generate_up(adapter \\ Config.adapter(), opts \\ []) do
    dimensions = Keyword.get(opts, :dimensions, 1536)
    prefix = Keyword.get(opts, :table_prefix, "recollect_")

    # Generate SQL parts
    extension_sql = generate_extension_sql(adapter)
    tier1_tables = generate_tier1_tables(adapter, dimensions, prefix)
    tier2_tables = generate_tier2_tables(adapter, dimensions, prefix)
    indexes = generate_indexes(adapter, dimensions, prefix)

    # Combine all parts
    [
      extension_sql,
      tier1_tables,
      tier2_tables,
      indexes
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Generates the `down` migration content for dropping all Recollect tables.
  """
  def generate_down(opts \\ []) do
    prefix = Keyword.get(opts, :table_prefix, "recollect_")

    """
    drop table(:#{prefix}evidence)
    drop table(:#{prefix}events)
    drop table(:#{prefix}handoffs)
    drop table(:#{prefix}entry_tags)
    drop table(:#{prefix}edges)
    drop table(:#{prefix}entries)
    drop table(:#{prefix}pipeline_runs)
    drop table(:#{prefix}relations)
    drop table(:#{prefix}entities)
    drop table(:#{prefix}chunks)
    drop table(:#{prefix}documents)
    drop table(:#{prefix}collections)
    """
  end

  # ── Extension SQL ──────────────────────────────────────────────────────

  defp generate_extension_sql(adapter) do
    sql = adapter.create_vector_extension_sql()

    if sql do
      "execute(\"#{sql}\")"
    else
      "# Vector support is built-in (libSQL)"
    end
  end

  # ── Tier 1: Full Pipeline Tables ────────────────────────────────────────

  defp generate_tier1_tables(adapter, dimensions, prefix) do
    uuid_type = adapter.uuid_type()
    _vector_type = adapter.vector_type(dimensions)

    # Use Ecto's type system for migrations
    uuid_type_atom =
      case uuid_type do
        :uuid -> :uuid
        :string -> :string
        :binary_id -> :binary_id
        _ -> :binary_id
      end

    """
    # ── Tier 1: Full Pipeline ──────────────────────────────────────────

    create table(:#{prefix}collections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :collection_type, :string, null: false, default: "user"
      add :owner_id, #{inspect(uuid_type_atom)}, null: false
      add :scope_id, #{inspect(uuid_type_atom)}
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create table(:#{prefix}documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string
      add :content, :text
      add :content_hash, :string
      add :source_type, :string, null: false, default: "manual"
      add :source_id, :string
      add :source_version, :string
      add :status, :string, null: false, default: "pending"
      add :failed_attempts, :integer, null: false, default: 0
      add :summary, :text
      #{generate_vector_column(adapter, :summary_embedding, dimensions)}
      add :token_count, :integer, default: 0
      add :metadata, :map, default: %{}
      add :owner_id, #{inspect(uuid_type_atom)}, null: false
      add :scope_id, #{inspect(uuid_type_atom)}
      add :collection_id, references(:#{prefix}collections, type: :binary_id, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:#{prefix}chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :sequence, :integer
      add :content, :text
      #{generate_vector_column(adapter, :embedding, dimensions)}
      add :token_count, :integer, default: 0
      add :start_offset, :integer, default: 0
      add :end_offset, :integer, default: 0
      add :metadata, :map, default: %{}
      add :owner_id, #{inspect(uuid_type_atom)}, null: false
      add :scope_id, #{inspect(uuid_type_atom)}
      add :document_id, references(:#{prefix}documents, type: :binary_id, on_delete: :delete_all), null: false
      add :embedding_model_id, :string
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("#{now_default(adapter)}")
    end

    create table(:#{prefix}entities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :entity_type, :string, null: false
      add :description, :text
      add :properties, :map, default: %{}
      add :mention_count, :integer, default: 1
      add :first_seen_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec
      #{generate_vector_column(adapter, :embedding, dimensions)}
      add :embedding_model_id, :string
      add :owner_id, #{inspect(uuid_type_atom)}, null: false
      add :scope_id, #{inspect(uuid_type_atom)}
      add :collection_id, references(:#{prefix}collections, type: :binary_id, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:#{prefix}relations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :relation_type, :string, null: false
      add :weight, :float, default: 1.0
      add :properties, :map, default: %{}
      add :owner_id, #{inspect(uuid_type_atom)}, null: false
      add :scope_id, #{inspect(uuid_type_atom)}
      add :from_entity_id, references(:#{prefix}entities, type: :binary_id, on_delete: :delete_all), null: false
      add :to_entity_id, references(:#{prefix}entities, type: :binary_id, on_delete: :delete_all), null: false
      add :source_chunk_id, references(:#{prefix}chunks, type: :binary_id, on_delete: :nilify_all)
      #{generate_vector_column(adapter, :triplet_embedding, dimensions)}
      add :triplet_embedding_model_id, :string
      timestamps(type: :utc_datetime_usec)
    end

    create table(:#{prefix}pipeline_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :status, :string, null: false, default: "pending"
      add :step_details, :map, default: %{}
      add :error, :text
      add :tokens_used, :integer, default: 0
      add :cost_usd, :float, default: 0.0
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :owner_id, #{inspect(uuid_type_atom)}, null: false
      add :scope_id, #{inspect(uuid_type_atom)}
      add :document_id, references(:#{prefix}documents, type: :binary_id, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime_usec)
    end
    """
  end

  # ── Tier 2: Lightweight Knowledge Tables ─────────────────────────────────

  defp generate_tier2_tables(adapter, dimensions, prefix) do
    uuid_type = adapter.uuid_type()

    uuid_type_atom =
      case uuid_type do
        :uuid -> :uuid
        :string -> :string
        :binary_id -> :binary_id
        _ -> :binary_id
      end

    """
    # ── Tier 2: Lightweight Knowledge ──────────────────────────────────

    create table(:#{prefix}entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope_id, #{inspect(uuid_type_atom)}
      add :owner_id, #{inspect(uuid_type_atom)}
      add :entry_type, :string, null: false, default: "note"
      add :content, :text, null: false
      add :summary, :text
      add :source, :string, default: "system"
      add :source_id, :string
      #{generate_vector_column(adapter, :embedding, dimensions)}
      add :metadata, :map, default: %{}
      add :access_count, :integer, default: 0
      add :last_accessed_at, :utc_datetime_usec
      add :confidence, :float, default: 1.0
      add :half_life_days, :float, default: 7.0
      add :pinned, :boolean, default: false
      add :emotional_valence, :string, default: "neutral"
      add :schema_fit, :float, default: 0.5
      add :outcome_score, :integer
      add :confidence_state, :string, default: "active"
      add :context_hints, :map, default: %{}
      add :embedding_model_id, :string
      timestamps(type: :utc_datetime_usec)
    end

    create table(:#{prefix}edges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :relation, :string, null: false
      add :weight, :float, default: 1.0
      add :metadata, :map, default: %{}
      add :source_entry_id, references(:#{prefix}entries, type: :binary_id, on_delete: :delete_all), null: false
      add :target_entry_id, references(:#{prefix}entries, type: :binary_id, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:#{prefix}handoffs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope_id, #{inspect(uuid_type_atom)}, null: false
      add :session_id, #{inspect(uuid_type_atom)}
      add :what, :text, null: false
      add :next, :text
      add :artifacts, :text
      add :blockers, :text
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:#{prefix}entry_tags, primary_key: false) do
      add :entry_id, references(:#{prefix}entries, type: :binary_id, on_delete: :delete_all), primary_key: true
      add :tag, :string, primary_key: true
      add :scope_id, #{inspect(uuid_type_atom)}
      add :owner_id, #{inspect(uuid_type_atom)}
    end

    create table(:#{prefix}events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_id, #{inspect(uuid_type_atom)}, null: false
      add :scope_id, #{inspect(uuid_type_atom)}
      add :session_id, #{inspect(uuid_type_atom)}
      add :agent, :string
      add :event_type, :string, null: false
      add :role, :string
      add :content, :text
      add :occurred_at, :utc_datetime_usec, null: false
      add :source_uri, :string
      add :source_ref, :string
      add :parent_event_id, references(:#{prefix}events, type: :binary_id, on_delete: :nilify_all)
      add :metadata, :map, default: %{}
      add :content_hash, :string, null: false
      timestamps(inserted_at: :created_at, updated_at: false)
    end

    create table(:#{prefix}evidence, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :entry_id, references(:#{prefix}entries, type: :binary_id, on_delete: :delete_all), null: false
      add :event_id, references(:#{prefix}events, type: :binary_id, on_delete: :nilify_all)
      add :relation, :string, null: false
      add :excerpt, :text
      add :source_type, :string
      add :source_ref, :string
      add :weight, :float, default: 1.0, null: false
      add :created_at, :utc_datetime_usec, null: false
    end
    """
  end

  # ── Indexes ────────────────────────────────────────────────────────────

  defp generate_indexes(adapter, dimensions, prefix) do
    """
    # ── Indexes ─────────────────────────────────────────────────────────

    create unique_index(:#{prefix}collections, [:owner_id, :name, :collection_type])
    create index(:#{prefix}collections, [:scope_id])

    create unique_index(:#{prefix}documents, [:collection_id, :source_type, :source_id])
    create index(:#{prefix}documents, [:owner_id])
    create index(:#{prefix}documents, [:scope_id])

    #{generate_vector_index(adapter, "#{prefix}documents", :summary_embedding, dimensions)}

    create index(:#{prefix}chunks, [:document_id])
    create index(:#{prefix}chunks, [:owner_id])
    create index(:#{prefix}chunks, [:scope_id])

    #{generate_vector_index(adapter, "#{prefix}chunks", :embedding, dimensions)}

    create unique_index(:#{prefix}entities, [:collection_id, :name, :entity_type])
    create index(:#{prefix}entities, [:owner_id])
    create index(:#{prefix}entities, [:scope_id])

    #{generate_vector_index(adapter, "#{prefix}entities", :embedding, dimensions)}

    create unique_index(:#{prefix}relations, [:from_entity_id, :to_entity_id, :relation_type])
    create index(:#{prefix}relations, [:owner_id])
    create index(:#{prefix}relations, [:scope_id])

    #{generate_vector_index(adapter, "#{prefix}relations", :triplet_embedding, dimensions)}

    #{generate_self_relation_constraint(adapter, "#{prefix}relations")}

    create index(:#{prefix}pipeline_runs, [:document_id])
    create index(:#{prefix}pipeline_runs, [:scope_id])

    create index(:#{prefix}entries, [:scope_id])
    create index(:#{prefix}entries, [:owner_id])
    create index(:#{prefix}entries, [:scope_id, :last_accessed_at])
    create unique_index(:#{prefix}entries, [:source, :source_id],
      name: :"#{prefix}entries_source_source_id_unique",
      where: "source_id IS NOT NULL"
    )

    #{generate_vector_index(adapter, "#{prefix}entries", :embedding, dimensions)}

    create unique_index(:#{prefix}edges, [:source_entry_id, :target_entry_id, :relation])

    create index(:#{prefix}handoffs, [:scope_id, :created_at])

    create index(:#{prefix}entry_tags, [:scope_id, :tag])
    create index(:#{prefix}entry_tags, [:tag])

    create index(:#{prefix}events, [:owner_id, :occurred_at])
    create index(:#{prefix}events, [:scope_id, :occurred_at])
    create index(:#{prefix}events, [:session_id, :occurred_at])
    create unique_index(:#{prefix}events, [:owner_id, :content_hash],
      name: :"#{prefix}events_owner_content_hash_idx"
    )

    create index(:#{prefix}evidence, [:entry_id])
    create index(:#{prefix}evidence, [:event_id])
    create unique_index(:#{prefix}evidence, [:entry_id, :relation, :source_type, :source_ref],
      name: :"#{prefix}evidence_unique_idx",
      where: "source_ref IS NOT NULL"
    )
    """
  end

  # ── Helper Functions ────────────────────────────────────────────────────

  # Dialect-correct "now" default. Postgres has no datetime('now'); SQLite
  # requires expression defaults to be parenthesised.
  defp now_default(adapter) do
    if adapter.dialect() == :postgres do
      "now()"
    else
      "(datetime('now'))"
    end
  end

  defp generate_vector_column(adapter, name, dimensions) do
    type_str = adapter.vector_type(dimensions)

    # For migrations, we need to use Ecto's type system
    # but handle special types like F32_BLOB for libSQL
    if adapter.dialect() == :postgres do
      "add :#{name}, :\"#{type_str}\""
    else
      # libSQL: F32_BLOB is a special type, use execute for raw SQL
      "add :#{name}, :string  # #{type_str} in libSQL - vectors stored as JSON text"
    end
  end

  defp generate_vector_index(adapter, table, column, _dimensions) do
    table
    |> String.to_atom()
    |> adapter.vector_index_sql(column, [])
    |> case do
      sql when is_binary(sql) ->
        if adapter.dialect() == :postgres do
          # Re-indent the (multi-line) SQL so every content line sits deeper
          # than the closing heredoc delimiter — otherwise the generated
          # migration compiles with "outdented heredoc" warnings.
          body =
            sql
            |> String.trim()
            |> String.split("\n")
            |> Enum.map_join("\n", &("  " <> String.trim_trailing(&1)))

          ~s(execute """\n#{body}\n""")
        else
          ~s(execute "#{String.replace(sql, "\"", "\\\"")}")
        end

      _ ->
        "# Vector index creation skipped"
    end
  end

  defp generate_self_relation_constraint(adapter, table) do
    if adapter.dialect() == :postgres do
      """
      create constraint(:#{table}, :no_self_relation,
        check: "from_entity_id != to_entity_id"
      )
      """
    else
      # SQLite doesn't support CHECK constraints across tables in the same way
      "# Self-relation check is handled at application level for SQLite"
    end
  end
end
