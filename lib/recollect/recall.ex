defmodule Recollect.Recall do
  @moduledoc """
  Just-in-time recall keyed by path/symbol (MEM-021): store pointers, not
  prose. `index/2` attaches anchors to entries; `for_path/3` and
  `for_symbol/3` resolve an anchor to cited memory blocks; `boost_entries/4`
  gives anchored entries a modest score boost inside `Recollect.Search`.

  Anchors are scoped through their entry — they never leak across scopes.
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Schema.Entry
  alias Recollect.Schema.RecallAnchor
  alias Recollect.Telemetry
  alias Recollect.Util

  @doc """
  Attach anchors to an entry, idempotently on
  `(entry_id, anchor_type, anchor_value)`.

  Accepts a keyword list (`path: "lib/x.ex", symbol: "Mod.fun"`), maps
  (`%{type: :path, value: ..., confidence: 0.8}`) or
  `%{anchor_type: ..., anchor_value: ...}` maps. Unknown/blank anchors are
  skipped. Returns `{:ok, %{indexed: newly_inserted, total: given}}`.
  """
  def index(entry_id, anchors) when is_list(anchors) do
    entry_id = Util.uuid_to_string(entry_id)
    repo = Config.repo()

    case repo.get(Entry, entry_id) do
      nil ->
        {:error, :entry_not_found}

      _entry ->
        specs = normalize_anchors(anchors)

        rows =
          Enum.map(specs, fn {type, value, confidence} ->
            %{
              id: Ecto.UUID.generate(),
              entry_id: entry_id,
              anchor_type: to_string(type),
              anchor_value: value,
              confidence: confidence,
              created_at: DateTime.utc_now()
            }
          end)

        Telemetry.span([:recollect, :recall, :index], %{entry_id: entry_id}, fn ->
          case rows do
            [] ->
              {:ok, %{indexed: 0, total: 0}}

            rows ->
              {count, _} =
                repo.insert_all(RecallAnchor, rows,
                  on_conflict: :nothing,
                  conflict_target: [:entry_id, :anchor_type, :anchor_value]
                )

              {:ok, %{indexed: count, total: length(rows)}}
          end
        end)
    end
  end

  @doc """
  Resolve a file path to entries: exact match first, then prefix, then
  basename. Returns `{:ok, [%{entry_id, anchor_value, confidence,
  entry_type, excerpt}]}`.
  """
  def for_path(path, scope_id, opts \\ []) when is_binary(path) do
    Telemetry.span([:recollect, :recall, :for_path], %{path: path}, fn ->
      scope_id = Util.uuid_to_string(scope_id)
      limit = Keyword.get(opts, :limit, 10)

      exact = matching(scope_id, "path", path, limit)
      prefix = matching(scope_id, "path", prefix_of(path), limit)
      basename = matching(scope_id, "path", "%/" <> basename_of(path), limit)

      {:ok, merge_hits([exact, prefix, basename], limit)}
    end)
  end

  @doc """
  Resolve a symbol (`Mod`, `Mod.fun`, `Mod.fun/2`) to entries anchored as
  `symbol`/`module`/`function`. Exact match first, then suffix match.
  """
  def for_symbol(symbol, scope_id, opts \\ []) when is_binary(symbol) do
    Telemetry.span([:recollect, :recall, :for_symbol], %{symbol: symbol}, fn ->
      scope_id = Util.uuid_to_string(scope_id)
      limit = Keyword.get(opts, :limit, 10)

      types = ["symbol", "module", "function"]

      exact = matching(scope_id, types, symbol, limit)
      suffix = matching(scope_id, types, "%" <> symbol, limit)

      {:ok, merge_hits([exact, suffix], limit)}
    end)
  end

  @doc """
  Give anchored entries a modest score boost inside search results —
  a nudge, not an override. Entries already in `results` gain `+boost`
  and an `anchored: true` marker; anchored entries missing from the
  results are appended at the current minimum score.
  """
  def boost_entries(results, path, scope_id, boost \\ 0.05) do
    {:ok, hits} = for_path(path, scope_id, limit: 20)

    anchored_ids = MapSet.new(Enum.map(hits, & &1.entry_id))

    boosted =
      Enum.map(results, fn row ->
        id = row["id"]

        if id && MapSet.member?(anchored_ids, id) do
          row
          |> Map.put("score", (row["score"] || 0.0) + boost)
          |> Map.put("anchored", true)
        else
          row
        end
      end)

    present = MapSet.new(Enum.map(boosted, & &1["id"]))

    floor_score =
      boosted
      |> Enum.map(&(&1["score"] || 0.0))
      |> case do
        [] -> 0.3
        scores -> Enum.min(scores)
      end

    appended =
      hits
      |> Enum.reject(&MapSet.member?(present, &1.entry_id))
      |> Enum.map(fn hit ->
        %{
          "id" => hit.entry_id,
          "content" => hit.excerpt,
          "entry_type" => hit.entry_type || "note",
          "score" => floor_score,
          "anchored" => true,
          "result_type" => :entry
        }
      end)

    Enum.sort_by(boosted ++ appended, &(&1["score"] || 0.0), :desc)
  end

  @doc """
  Backfill anchors from `metadata["path"]`, `metadata["file"]`, and
  evidence rows with `source_type: "file"`. Returns
  `{:ok, %{entries: scanned, anchors: indexed}}`.
  """
  def backfill(opts \\ []) do
    scope_id = Util.uuid_to_string(opts[:scope_id])
    repo = Config.repo()

    entries =
      from(e in Entry,
        where: not is_nil(e.metadata),
        select: %{id: e.id, metadata: e.metadata, scope: e.scope_id}
      )
      |> then(fn q ->
        if scope_id, do: where(q, [e], e.scope_id == ^scope_id), else: q
      end)
      |> repo.all()

    {indexed, scanned} =
      Enum.reduce(entries, {0, 0}, fn entry, {acc, scanned} ->
        paths = Enum.reject([entry.metadata["path"], entry.metadata["file"]], &(is_nil(&1) or &1 == ""))

        case paths do
          [] ->
            {acc, scanned}

          paths ->
            anchors =
              paths
              |> Enum.map(fn path ->
                path = to_string(path)
                [{:path, path}, {:path, Path.basename(path)}]
              end)
              |> List.flatten()

            case index(entry.id, anchors) do
              {:ok, %{indexed: n}} -> {acc + n, scanned + 1}
              _ -> {acc, scanned}
            end
        end
      end)

    {:ok, %{entries: scanned, anchors: indexed}}
  end

  # Private

  defp normalize_anchors(anchors) do
    anchors
    |> Enum.flat_map(fn
      {type, value} when is_atom(type) ->
        [{type, value, 0.5}]

      %{type: type, value: value} = m ->
        [{type, value, m[:confidence] || 0.5}]

      %{anchor_type: type, anchor_value: value} = m ->
        [{type, value, m[:confidence] || 0.5}]

      _other ->
        []
    end)
    |> Enum.reject(fn {_type, value, _confidence} -> is_nil(value) or value == "" end)
    |> Enum.uniq_by(fn {type, value, _} -> {to_string(type), value} end)
  end

  defp matching(scope_id, types, pattern, limit) do
    from(a in RecallAnchor,
      join: e in Entry,
      on: e.id == a.entry_id,
      where:
        a.anchor_type in ^List.wrap(types) and
          e.scope_id == ^scope_id and
          is_nil(e.deleted_at) and
          e.entry_type != "archived" and
          like(a.anchor_value, ^pattern),
      order_by: [desc: a.confidence, asc: a.anchor_value],
      limit: ^limit,
      select: %{
        entry_id: e.id,
        content: e.content,
        summary: e.summary,
        entry_type: e.entry_type,
        anchor_value: a.anchor_value,
        confidence: a.confidence
      }
    )
    |> Config.repo().all()
    |> Enum.map(&to_hit/1)
  end

  defp to_hit(row) do
    excerpt =
      row.summary || (row.content && String.slice(row.content, 0, 160))

    %{
      entry_id: row.entry_id,
      anchor_value: row.anchor_value,
      confidence: row.confidence,
      entry_type: row.entry_type,
      excerpt: excerpt
    }
  end

  # Keep the highest-confidence hit per entry across strategies; exact
  # matches naturally outrank prefix/basename because they come first.
  defp merge_hits(hit_lists, limit) do
    hit_lists
    |> Enum.concat()
    |> Enum.uniq_by(& &1.entry_id)
    |> Enum.take(limit)
  end

  defp prefix_of(path), do: path <> "%"
  defp basename_of(path), do: Path.basename(path)
end
