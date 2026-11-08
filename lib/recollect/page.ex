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
  alias Recollect.Schema.Page
  alias Recollect.Schema.PageSource
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
    if sources == [] do
      {:error, :no_sources}
    else
      # created_at is a create-only attr — updates never touch it
      attrs = Map.put(page_attrs(Map.new(attrs)), :created_at, DateTime.utc_now())
      repo = Config.repo()

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
  end

  def create(_attrs, _not_a_list), do: {:error, :no_sources}

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

        page
        |> Page.changeset(attrs)
        |> repo.update()
        |> case do
          {:ok, updated} -> {:ok, updated}
          {:error, cs} -> {:error, cs}
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
    |> put_if(:source_hash, body && body_hash(body))
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
end
