defmodule Recollect.Page do
  @moduledoc """
  CRUD and citation access for cited wiki pages (MEM-027).

  A page is created with its sources in one transaction — a page without
  at least one source is rejected, so every statement in the
  representation layer traces back to an entry, event, file, or URL.

  `token_count` and `source_hash` are computed from the body: the token
  count through the shared `Recollect.Tokenizer` model (budget math), the
  source hash for incremental updates (MEM-028 re-synthesizes only when
  the body actually changed).
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Schema.Entry
  alias Recollect.Schema.Event
  alias Recollect.Schema.Page
  alias Recollect.Schema.PageSource
  alias Recollect.Telemetry
  alias Recollect.Tokenizer
  alias Recollect.Util

  @slug_format ~r/^[a-z0-9\-\/]+$/

  @doc "Required slug format."
  def slug_format, do: @slug_format

  @doc """
  Create a page with its sources, atomically.

  `attrs` needs `:owner_id`, `:slug`, `:title`, `:body_md` (plus optional
  `:scope_id`, `:kind`, `:summary`). `sources` is a list of maps with
  `:source_type` (`entry | event | url | file`) and optional `:entry_id`,
  `:event_id`, `:source_ref`, `:role`.

  `token_count` and `source_hash` are computed from the body. Returns
  `{:error, :no_sources}` when the source list is empty; slug-format and
  duplicate-slug failures return a changeset.
  """
  def create(attrs, sources) when is_list(sources) do
    cond do
      sources == [] ->
        {:error, :no_sources}

      scope_full?(attrs) ->
        {:error, :page_cap_reached}

      true ->
        # created_at is a create-only attr — updates never touch it
        attrs = Map.put(page_attrs(Map.new(attrs)), :created_at, DateTime.utc_now())
        repo = Config.repo()

        guard =
          compression_guard(attrs[:token_count], source_tokens(sources, repo), attrs[:scope_id])

        if guard.valid do
          do_create(repo, attrs, sources)
        else
          warn_rejected(guard, attrs[:slug])
          {:error, {:compression_guard, guard}}
        end
    end
  end

  def create(_attrs, _not_a_list), do: {:error, :no_sources}

  defp do_create(repo, attrs, sources) do
    fn ->
      page =
        %Page{}
        |> Page.changeset(attrs)
        |> repo.insert()
        |> case do
          {:ok, page} -> page
          {:error, cs} -> repo.rollback(cs)
        end

      Enum.each(normalize_sources(sources), fn source_attrs ->
        source_attrs = Map.put(source_attrs, :page_id, page.id)

        %PageSource{}
        |> PageSource.changeset(source_attrs)
        |> repo.insert!()
      end)

      %{page | sources: normalize_sources(sources)}
    end
    |> repo.transaction()
    |> case do
      {:ok, page} -> {:ok, page}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Fetch a page with its sources preloaded."
  def get(page_id) do
    repo = Config.repo()

    case repo.get(Page, Util.uuid_to_string(page_id)) do
      nil -> {:error, :not_found}
      page -> {:ok, repo.preload(page, :sources)}
    end
  end

  @doc """
  List pages for a scope.

  Options: `:kind`, `:limit` (default 50).
  """
  def list(scope_id, opts \\ []) do
    scope_id = Util.uuid_to_string(scope_id)
    kind = Keyword.get(opts, :kind)
    limit = Keyword.get(opts, :limit, 50)

    query =
      from(p in Page,
        where: p.scope_id == ^scope_id,
        order_by: [desc: p.updated_at],
        limit: ^limit,
        preload: [:sources]
      )

    query =
      if kind do
        where(query, [p], p.kind == ^to_string(kind))
      else
        query
      end

    {:ok, Config.repo().all(query)}
  end

  @doc """
  Update a page: when the body changes, `token_count` and `source_hash`
  recompute and `version` bumps. Sources are managed separately via
  `add_source/2`.
  """
  def update(page_or_id, attrs) do
    repo = Config.repo()

    page =
      case page_or_id do
        %Page{} = p ->
          {:ok, p}

        id ->
          Page
          |> repo.get(Util.uuid_to_string(id), preload: [:sources])
          |> case do
            nil -> {:error, :not_found}
            p -> {:ok, p}
          end
      end

    case page do
      {:error, reason} ->
        {:error, reason}

      {:ok, page} ->
        attrs = page_attrs(attrs)

        body_changed? =
          is_binary(attrs[:body_md]) and attrs[:body_md] != page.body_md

        attrs =
          if body_changed? do
            Map.merge(attrs, %{
              token_count: Tokenizer.estimate(attrs[:body_md]),
              source_hash: body_hash(attrs[:body_md]),
              version: (page.version || 1) + 1,
              updated_at: DateTime.utc_now()
            })
          else
            Map.put(attrs, :updated_at, DateTime.utc_now())
          end

        # MEM-029: the compression guard applies on update too — a body
        # change may not outgrow the page's cited sources. Summary-only
        # updates keep the existing token count.
        sources = repo.all(from(s in PageSource, where: s.page_id == ^page.id))
        new_count = attrs[:token_count] || page.token_count
        guard = compression_guard(new_count, source_tokens_from_rows(sources, repo), page.scope_id)

        if guard.valid do
          page
          |> Page.changeset(attrs)
          |> repo.update()
          |> case do
            {:ok, updated} -> {:ok, updated}
            {:error, cs} -> {:error, cs}
          end
        else
          warn_rejected(guard, page.slug)
          {:error, {:compression_guard, guard}}
        end
    end
  end

  @doc "Delete a page; its sources cascade."
  def delete(page_or_id) do
    repo = Config.repo()

    case fetch_page(repo, page_or_id) do
      {:ok, page} -> repo.delete(page)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The raw source rows for a page."
  def sources(page_or_id) do
    page_id = page_id!(page_or_id)

    {:ok,
     Config.repo().all(
       from(s in PageSource,
         where: s.page_id == ^page_id,
         order_by: [asc: s.created_at]
       )
     )}
  end

  @doc """
  Citation strings for a page: `[p1] entry:<entry_id>`, ordered primary →
  supporting → contradicting — the display form used by the brief.
  """
  def citations(page_or_id) do
    with {:ok, sources} <- sources(page_or_id) do
      ordered =
        Enum.sort_by(sources, fn s ->
          Enum.find_index(PageSource.roles(), &(&1 == s.role))
        end)

      {:ok,
       Enum.map(ordered, fn s ->
         %{
           source_type: s.source_type,
           role: s.role,
           ref: s.source_ref || s.entry_id || s.event_id,
           display: "[p] #{s.source_type}:#{s.source_ref || s.entry_id || s.event_id}"
         }
       end)}
    end
  end

  @doc """
  Search pages by vector similarity over their cited entries (MEM-030).

  Pages don't store embeddings directly; instead we vector-search entries
  and return the pages that cite matching entries, ranked by best entry
  match score.

  ## Options
  - `:limit` — Max results (default: 10)
  - `:min_score` — Minimum similarity 0.0-1.0 (default: 0.0)

  Returns `{:ok, results}` where each result is a map with `:id`, `:slug`,
  `:title`, `:summary`, `:score`, and `:sources`.
  """
  def search(query_text, scope_id, opts \\ []) do
    scope_id = Util.uuid_to_string(scope_id)
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)

    case Recollect.Pipeline.Embedder.embed_query(query_text) do
      {:ok, embedding} ->
        embedding_str = embedding_to_str(embedding)

        case Recollect.Search.Vector.search_entries_by_embedding(embedding_str, scope_id,
               limit: limit * 5,
               min_score: min_score
             ) do
          {:ok, entry_results} ->
            # Find pages that cite matching entries
            page_scores = find_pages_for_entries(Config.repo(), entry_results)

            pages =
              page_scores
              |> Enum.sort_by(&(-&1.score))
              |> Enum.take(limit)
              |> Enum.map(fn %{page: page, score: score, entry_ids: _entry_ids} ->
                %{
                  id: page.id,
                  slug: page.slug,
                  title: page.title,
                  summary: page.summary,
                  score: score,
                  sources: page_source_list(page.id),
                  citation: "[p] #{page.slug}"
                }
              end)

            {:ok, pages}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Add one source to an existing page."
  def add_source(page_or_id, source_attrs) do
    repo = Config.repo()

    with {:ok, page} <- fetch_page(repo, page_or_id) do
      attrs =
        source_attrs
        |> source_attrs_map()
        |> source_attrs()
        |> Map.put(:page_id, page.id)

      %PageSource{}
      |> PageSource.changeset(attrs)
      |> repo.insert()
    end
  end

  # Private

  defp fetch_page(repo, page_or_id)

  defp fetch_page(_repo, %Page{} = page), do: {:ok, page}

  defp fetch_page(repo, id) do
    case repo.get(Page, Util.uuid_to_string(id)) do
      nil -> {:error, :not_found}
      page -> {:ok, repo.preload(page, :sources)}
    end
  end

  defp page_id!(%Page{id: id}), do: id
  defp page_id!(id), do: Util.uuid_to_string(id)

  defp source_attrs_map(spec) when is_map(spec), do: spec
  defp source_attrs_map(spec) when is_list(spec), do: Map.new(spec)

  defp normalize_sources(sources) do
    Enum.map(sources, fn spec ->
      source_attrs(source_attrs_map(spec))
    end)
  end

  defp source_attrs(spec) do
    %{
      entry_id: Util.uuid_to_string(spec[:entry_id]),
      event_id: Util.uuid_to_string(spec[:event_id]),
      source_type: spec[:source_type] && to_string(spec[:source_type]),
      source_ref: spec[:source_ref],
      role: to_string(spec[:role] || "supporting"),
      created_at: DateTime.utc_now()
    }
  end

  defp page_attrs(attrs) do
    attrs = Map.new(attrs)
    body = attrs[:body_md] || attrs["body_md"]

    %{}
    |> put_if(:owner_id, uuid_or_nil(attrs[:owner_id] || attrs["owner_id"]))
    |> put_if(:scope_id, uuid_or_nil(attrs[:scope_id] || attrs["scope_id"]))
    |> put_if(:slug, attrs[:slug] || attrs["slug"])
    |> put_if(:title, attrs[:title] || attrs["title"])
    |> put_if(:kind, attrs[:kind] && to_string(attrs[:kind]))
    |> put_if(:body_md, body)
    |> put_if(:summary, attrs[:summary] || attrs["summary"])
    |> put_if(:token_count, body && Tokenizer.estimate(body))
    |> put_if(:source_hash, attrs[:source_hash] || (body && body_hash(body)))
    |> put_if(:version, attrs[:version])
    |> Map.put(:updated_at, DateTime.utc_now())
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp uuid_or_nil(nil), do: nil
  defp uuid_or_nil(id), do: Util.uuid_to_string(id)

  defp body_hash(nil), do: ""

  defp body_hash(body) do
    :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
  end

  # ── Compression guard (MEM-029) ──────────────────────────────────────

  @doc """
  Dry-run validation: does this page satisfy the source requirement and
  the compression guard? Returns a report — never writes.

      page.token_count <= max(200, source_tokens * pages.compression_ratio)
  """
  def check(page_or_id) do
    repo = Config.repo()

    case fetch_page(repo, page_or_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, page} ->
        sources = repo.all(from(s in PageSource, where: s.page_id == ^page.id))
        guard = compression_guard(page.token_count, source_tokens_from_rows(sources, repo), page.scope_id)

        {:ok,
         %{
           valid: guard.valid,
           page_token_count: page.token_count,
           source_tokens: guard.source_tokens,
           max_allowed: guard.limit,
           compression_ratio: guard.ratio,
           has_sources: sources != [],
           reasons: guard.reasons
         }}
    end
  end

  # Guard report: valid when the page has sources and fits
  # max(200, source_tokens * pages.compression_ratio).
  defp compression_guard(page_token_count, source_tokens, scope_id) do
    ratio = Config.pages()[:compression_ratio] || 0.5
    limit = max(200, trunc(source_tokens * ratio))

    reasons =
      []
      |> reject_if(scope_id == nil, :missing_scope)
      |> reject_if(page_token_count > limit, :compression_guard_exceeded)

    %{
      valid: reasons == [],
      page_token_count: page_token_count || 0,
      source_tokens: source_tokens,
      limit: limit,
      ratio: ratio,
      reasons: reasons
    }
  end

  defp reject_if(reasons, true, reason), do: reasons ++ [reason]
  defp reject_if(reasons, false, _reason), do: reasons

  # Source tokens come from the CITED entries/events only — never the
  # whole corpus. url/file sources contribute nothing (nothing to read).
  defp source_tokens(sources, repo) when is_list(sources) do
    sources
    |> Enum.map(fn source ->
      spec = source_attrs_map(source)
      token_count_for_source(spec[:source_type], spec[:entry_id], spec[:event_id], repo)
    end)
    |> Enum.sum()
  end

  defp source_tokens(_page_or_id_or_other, _repo), do: 0

  # Stored-sources variant used by update/check.
  defp source_tokens_from_rows(rows, repo) do
    rows
    |> Enum.map(fn row ->
      token_count_for_source(row.source_type, row.entry_id, row.event_id, repo)
    end)
    |> Enum.sum()
  end

  defp token_count_for_source("entry", entry_id, _event_id, repo) when not is_nil(entry_id) do
    case repo.get(Entry, entry_id) do
      nil -> 0
      entry -> Tokenizer.estimate(entry.content || "")
    end
  end

  defp token_count_for_source("event", _entry_id, event_id, repo) when not is_nil(event_id) do
    case repo.get(Event, event_id) do
      nil -> 0
      event -> Tokenizer.estimate(event.content || "")
    end
  end

  defp token_count_for_source(_type, _entry_id, _event_id, _repo), do: 0

  defp scope_full?(attrs) do
    attrs_map = Map.new(attrs)
    scope_id = uuid_or_nil(attrs_map[:scope_id] || attrs_map["scope_id"])
    max_pages = Config.pages()[:max_pages_per_scope] || 100

    if scope_id do
      count =
        Config.repo().aggregate(
          from(p in Page, where: p.scope_id == ^scope_id),
          :count,
          :id
        )

      count >= max_pages
    else
      false
    end
  end

  defp warn_rejected(guard, slug) do
    require Logger

    Logger.warning(
      "Recollect.Page: rejected page #{inspect(slug)} — compression guard " <>
        "(#{guard.page_token_count} tokens > max #{guard.limit} from #{guard.source_tokens} source tokens)"
    )

    Telemetry.event(
      [:recollect, :page, :guard, :reject],
      %{page_token_count: guard.page_token_count, limit: guard.limit},
      %{
        source_tokens: guard.source_tokens
      }
    )
  end

  # ── Page search helpers (MEM-030) ───────────────────────────────────

  defp embedding_to_str(embedding) when is_list(embedding) do
    adapter = Config.adapter()
    result = adapter.format_embedding(embedding)

    if is_binary(result), do: result, else: "[#{Enum.map_join(embedding, ",", &Float.to_string/1)}]"
  end

  defp find_pages_for_entries(repo, entry_results) do
    entry_ids =
      entry_results
      |> Enum.map(fn r -> r["id"] || r[:id] end)
      |> Enum.reject(&is_nil/1)
      # Ecto :binary_id fields need string UUIDs, not raw binaries
      |> Enum.map(&Util.uuid_to_string/1)

    if entry_ids == [] do
      []
    else
      page_entry_ids =
        from(s in PageSource,
          where: s.entry_id in ^entry_ids,
          select: {s.page_id, s.entry_id}
        )
        |> repo.all()
        |> Enum.group_by(fn {page_id, _entry_id} -> page_id end)
        |> Map.new(fn {page_id, rows} -> {page_id, Enum.map(rows, &elem(&1, 1))} end)

      # Score each page by its best matching entry score
      entry_score_map =
        Enum.reduce(entry_results, %{}, fn r, acc ->
          id = r["id"] || r[:id]
          score = r["score"] || r[:score] || 0.0
          Map.put(acc, Util.uuid_to_string(id), score)
        end)

      Enum.map(page_entry_ids, fn {page_id, cited_entry_ids} ->
        page = repo.get(Page, page_id)

        best_score =
          cited_entry_ids
          |> Enum.map(fn eid -> Map.get(entry_score_map, eid, 0.0) end)
          |> Enum.max()
          |> Kernel.+(0.0)

        %{page: page, score: best_score, entry_ids: cited_entry_ids}
      end)
    end
  end

  defp page_source_list(page_id) do
    repo = Config.repo()
    query = from(s in PageSource, where: s.page_id == ^page_id, select: {s.source_type, s.source_ref, s.role})
    repo.all(query)
  end
end
