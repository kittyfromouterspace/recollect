defmodule Recollect.Export do
  @moduledoc """
  Export Recollect data to a portable format for migration or backup.

  Supports exporting all Recollect tables to JSONL format, which can then be
  imported into any supported database backend (PostgreSQL or libSQL).

  ## Usage

      # Export all data
      Recollect.Export.export_all("/path/to/backup.jsonl")

      # Export specific tables
      Recollect.Export.export_table(:recollect_entries, "/path/to/entries.jsonl")

  ## Export Format

  Data is exported as JSON Lines (JSONL), where each line is a JSON object
  representing one row with metadata about its table and schema version.

  Example:
      {"table": "recollect_entries", "version": "0.2.0", "data": {"id": "...", "content": "..."}}
      {"table": "recollect_chunks", "version": "0.2.0", "data": {"id": "...", "content": "..."}}
  """

  alias Recollect.Config

  require Logger

  @version "0.2.0"
  @tables [
    :recollect_collections,
    :recollect_documents,
    :recollect_chunks,
    :recollect_entities,
    :recollect_relations,
    :recollect_pipeline_runs,
    :recollect_entries,
    :recollect_edges
  ]

  @doc """
  Export all Recollect tables to a JSONL file.

  ## Options

  - `:batch_size` — Number of rows to fetch per query (default: 1000)
  - `:tables` — List of tables to export (default: all)
  - `:scope_id` — Optional scope filter for multi-tenant exports
  - `:owner_id` — Optional owner filter for user-specific exports

  ## Example

      Recollect.Export.export_all("/tmp/recollect_backup.jsonl")
      # {:ok, %{bytes: 1234567, tables: 8, rows: 15432}}
  """
  def export_all(path, opts \\ []) do
    tables = Keyword.get(opts, :tables, @tables)
    batch_size = Keyword.get(opts, :batch_size, 1000)

    path
    |> File.open([:write, :utf8], fn file ->
      # Write header
      header = %{
        type: "header",
        version: @version,
        exported_at: DateTime.to_iso8601(DateTime.utc_now()),
        adapter: Config.adapter() |> Module.split() |> List.last(),
        dimensions: Config.dimensions()
      }

      IO.puts(file, Jason.encode!(header))

      # Export each table
      results =
        Enum.map(tables, fn table ->
          count = export_table_to_file(file, table, batch_size, opts)
          {table, count}
        end)

      # Write footer
      total_rows = Enum.sum(Enum.map(results, fn {_, count} -> count end))

      footer = %{
        type: "footer",
        total_rows: total_rows,
        tables_exported: length(tables)
      }

      IO.puts(file, Jason.encode!(footer))

      {:ok, %{tables: results, total_rows: total_rows}}
    end)
    |> case do
      {:ok, {:ok, result}} ->
        {:ok, Map.put(result, :path, path)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Export a single table to a JSONL file.

  ## Example

      Recollect.Export.export_table(:recollect_entries, "/tmp/entries.jsonl")
  """
  def export_table(table, path, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 1000)

    path
    |> File.open([:write, :utf8], fn file ->
      count = export_table_to_file(file, table, batch_size, opts)
      {:ok, %{table: table, rows: count}}
    end)
    |> case do
      {:ok, {:ok, result}} -> {:ok, Map.put(result, :path, path)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Private Functions ─────────────────────────────────────────────────

  defp export_table_to_file(file, table, batch_size, opts) do
    repo = Config.repo()
    adapter = Config.adapter()

    # Dialect-aware placeholders (MEM-011): import.ex already builds its
    # INSERTs through adapter.placeholder/1; export now does the same.
    scope_ph = adapter.placeholder(1)
    owner_ph = adapter.placeholder(if(opts[:scope_id], do: 2, else: 1))

    query =
      case {opts[:scope_id], opts[:owner_id]} do
        {nil, nil} ->
          "SELECT * FROM #{table}"

        {_scope_id, nil} ->
          "SELECT * FROM #{table} WHERE scope_id = #{scope_ph}"

        {nil, _owner_id} ->
          "SELECT * FROM #{table} WHERE owner_id = #{owner_ph}"

        {_scope_id, _owner_id} ->
          "SELECT * FROM #{table} WHERE scope_id = #{scope_ph} AND owner_id = #{owner_ph}"
      end

    params =
      case {opts[:scope_id], opts[:owner_id]} do
        {nil, nil} -> []
        {scope_id, nil} -> [scope_id]
        {nil, owner_id} -> [owner_id]
        {scope_id, owner_id} -> [scope_id, owner_id]
      end

    # Stream results and write to file
    repo
    |> Ecto.Adapters.SQL.query!(query, params)
    |> stream_results(batch_size)
    |> Enum.reduce(0, fn row, count ->
      record = %{
        table: table,
        version: @version,
        data: row
      }

      IO.puts(file, Jason.encode!(record))
      count + 1
    end)
  end

  defp stream_results(%{rows: rows, columns: columns}, _batch_size) do
    # Convert each row to a map
    Enum.map(rows, fn row ->
      row
      |> Recollect.Util.row_to_map(columns)
      |> transform_row()
    end)
  end

  # Transform special types for JSON serialization
  defp transform_row(row) when is_map(row) do
    Map.new(row, fn {key, value} ->
      {key, transform_value(value)}
    end)
  end

  # Handle Ecto.UUID binary format (for PostgreSQL)
  defp transform_value(<<_::128>> = binary) do
    # Try to decode as UUID
    case Ecto.UUID.load(binary) do
      {:ok, uuid} -> uuid
      :error -> Base.encode16(binary, case: :lower)
    end
  end

  # Handle DateTime structs
  defp transform_value(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  # Handle NaiveDateTime structs
  defp transform_value(%NaiveDateTime{} = ndt) do
    NaiveDateTime.to_iso8601(ndt)
  end

  # Handle Decimals
  defp transform_value(%Decimal{} = decimal) do
    Decimal.to_string(decimal)
  end

  # Handle Pgvector vectors (PostgreSQL only)
  defp transform_value(%{__struct__: struct, embedding: embedding})
       when struct in [Pgvector.Ecto.Vector] and is_list(embedding) do
    embedding
  end

  # Pass through other values
  defp transform_value(value), do: value
end
