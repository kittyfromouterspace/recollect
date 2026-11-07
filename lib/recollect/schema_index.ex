defmodule Recollect.SchemaIndex do
  @moduledoc """
  ETS table for schema acceleration data.

  Rebuilt per scope during consolidation. Read by schema_fit computation on
  every entry creation. No GenServer owner — public table, written by
  consolidation, read by everyone.

  Keys are `{:tag_frequency, scope_id}` / `{:entry_count, scope_id}`; the
  `nil` scope_id holds the global aggregate used as a fallback when a scope
  has not been rebuilt yet.
  """

  import Ecto.Query

  alias Recollect.Schema.Entry
  alias Recollect.Schema.EntryTag

  @table :recollect_schema_index

  @doc "Initialize the ETS table."
  def init do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true}
    ])
  end

  @doc """
  Rebuild the tag-frequency index for one scope from `recollect_entry_tags`
  (joined to live entries so archived rows don't count).
  """
  def rebuild(scope_id) when is_binary(scope_id) do
    repo = Recollect.Config.repo()

    tag_freq =
      from(t in EntryTag,
        join: e in Entry,
        on: e.id == t.entry_id,
        where: t.scope_id == ^scope_id and e.entry_type != "archived",
        group_by: t.tag,
        select: {t.tag, count(t.entry_id)}
      )
      |> repo.all()
      |> Map.new()

    entry_count =
      repo.one(
        from(e in Entry,
          where: e.scope_id == ^scope_id and e.entry_type != "archived",
          select: count(e.id)
        )
      ) || 0

    :ets.insert(@table, {{:tag_frequency, scope_id}, tag_freq})
    :ets.insert(@table, {{:entry_count, scope_id}, entry_count})

    %{tag_clusters: map_size(tag_freq), entry_count: entry_count}
  end

  @doc "Rebuild the global (all-scope) aggregate, used as a fallback."
  def rebuild do
    repo = Recollect.Config.repo()

    tag_freq =
      from(t in EntryTag,
        join: e in Entry,
        on: e.id == t.entry_id,
        where: e.entry_type != "archived",
        group_by: t.tag,
        select: {t.tag, count(t.entry_id)}
      )
      |> repo.all()
      |> Map.new()

    entry_count =
      repo.one(
        from(e in Entry,
          where: e.entry_type != "archived",
          select: count(e.id)
        )
      ) || 0

    :ets.insert(@table, {{:tag_frequency, nil}, tag_freq})
    :ets.insert(@table, {{:entry_count, nil}, entry_count})

    %{tag_clusters: map_size(tag_freq), entry_count: entry_count}
  end

  @doc """
  Tag frequency map for a scope, falling back to the global aggregate.
  Returns %{} if the index is empty.
  """
  def tag_frequency(scope_id \\ nil) do
    scoped_lookup(:tag_frequency, scope_id, %{})
  end

  @doc """
  Live entry count for a scope, falling back to the global aggregate.
  Returns 0 if the index is empty.
  """
  def entry_count(scope_id \\ nil) do
    scoped_lookup(:entry_count, scope_id, 0)
  end

  defp scoped_lookup(kind, scope_id, default) do
    case :ets.lookup(@table, {kind, scope_id}) do
      [{{^kind, ^scope_id}, value}] -> value
      [] -> lookup_global(kind, scope_id, default)
    end
  rescue
    # Table not initialized (e.g. tests that never start the app tree)
    _ -> default
  end

  defp lookup_global(_kind, nil, default), do: default

  defp lookup_global(kind, _scope_id, default) do
    case :ets.lookup(@table, {kind, nil}) do
      [{{^kind, nil}, value}] -> value
      [] -> default
    end
  end
end
