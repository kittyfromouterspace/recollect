defmodule Recollect.Knowledge do
  @moduledoc """
  Lightweight knowledge API (Tier 2).
  Simple store-embed-search for entries and edges.
  """

  import Ecto.Query

  alias Recollect.Classification
  alias Recollect.Config
  alias Recollect.Context.Detector
  alias Recollect.Guards
  alias Recollect.Pipeline.Embedder
  alias Recollect.Schema.Edge
  alias Recollect.Schema.Entry
  alias Recollect.Schema.EntryTag
  alias Recollect.SchemaFit
  alias Recollect.Strength
  alias Recollect.Valence

  require Logger

  @doc """
  Store a knowledge entry with auto-embedding.

  Automatically captures current context (git repo, path, OS) unless
  explicitly provided via `:context_hints` option.

  Optionally auto-classifies content using LLM-free pattern matching
  via `Recollect.Classification`. Enable with `:auto_classify` option.
  """
  def remember(content, opts \\ []) do
    metadata = %{
      entry_type: Keyword.get(opts, :entry_type, "note"),
      scope_id: Keyword.get(opts, :scope_id),
      owner_id: Keyword.get(opts, :owner_id)
    }

    Recollect.Telemetry.span([:recollect, :remember], metadata, fn ->
      repo = Config.repo()

      valence = Valence.infer(opts)
      tags = Keyword.get(opts, :tags, [])
      scope_id = Keyword.get(opts, :scope_id)

      # Engine-level secret guard (MEM-036): content and string metadata are
      # checked before insert. Hosts that pre-scrub can pass
      # allow_secrets: true; guards can be disabled via config.
      metadata_payload = Keyword.get(opts, :metadata, %{})

      with :ok <- Guards.check(content, opts),
           :ok <- Guards.check(metadata_payload, opts) do
        write_entry(content, opts, tags, scope_id, context_hints_for(opts))
      else
        {:error, :possible_secret} = error ->
          require Logger

          Logger.warning("Recollect.Knowledge: remember rejected — content looks like it contains a credential")

          error
      end
    end)
  end

  defp context_hints_for(opts) do
    if opts[:context_hints] do
      opts[:context_hints]
    else
      Detector.detect()
    end
  end

  defp write_entry(content, opts, tags, scope_id, context_hints) do
    repo = Config.repo()

    valence = Valence.infer(opts)

    # Auto-classify content using LLM-free classification
    {entry_type, classification_confidence} =
      if Keyword.get(opts, :auto_classify, false) do
        Classification.classify(content, context_hints)
      else
        {Keyword.get(opts, :entry_type, "note"), nil}
      end

    base_half_life = Keyword.get(opts, :half_life_days) || 7.0
    # MEM-006: only the cheap tag fit runs synchronously on the write path;
    # the content-fit sample refines schema_fit asynchronously after commit.
    tags = normalize_tags(tags)
    schema_fit = SchemaFit.compute_tag_fit(tags, scope_id)
    adjusted_half_life = Strength.adjust_for_schema_fit(base_half_life, schema_fit)

    attrs = %{
      content: content,
      scope_id: scope_id,
      owner_id: Keyword.get(opts, :owner_id),
      entry_type: to_string(entry_type),
      summary: Keyword.get(opts, :summary),
      source: Keyword.get(opts, :source, "system"),
      source_id: Keyword.get(opts, :source_id),
      metadata: opts |> Keyword.get(:metadata, %{}) |> maybe_add_classification(classification_confidence),
      confidence: Keyword.get(opts, :confidence, 1.0),
      half_life_days: adjusted_half_life,
      pinned: Keyword.get(opts, :pinned, false),
      emotional_valence: Atom.to_string(valence),
      schema_fit: schema_fit,
      confidence_state: "active",
      context_hints: context_hints
    }

    case insert_entry_with_tags(repo, attrs, tags) do
      {:ok, entry} ->
        Embedder.embed_entry_async(entry)
        SchemaFit.refine_content_fit_async(entry.id, content, scope_id)
        {:ok, entry}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Entry + tags commit together (MEM-005): a remember that stores the row
  # but drops the tags is the bug this replaces. Validation failures roll the
  # transaction back into the usual {:error, changeset} — never a raise.
  defp insert_entry_with_tags(repo, attrs, tags) do
    repo.transaction(fn ->
      case %Entry{} |> Entry.changeset(attrs) |> repo.insert() do
        {:ok, entry} ->
          tags = normalize_tags(tags)

          if tags != [] do
            rows =
              Enum.map(tags, fn tag ->
                %{entry_id: entry.id, tag: tag, scope_id: entry.scope_id, owner_id: entry.owner_id}
              end)

            repo.insert_all(EntryTag, rows,
              on_conflict: :nothing,
              conflict_target: [:entry_id, :tag]
            )
          end

          %{entry | tags: tags}

        {:error, changeset} ->
          repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Normalize a tag list: binaries only, trimmed, downcased, empties dropped,
  deduped, capped at 20 tags of at most 64 chars each.
  """
  def normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.map(&String.slice(&1, 0, 64))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(20)
  end

  def normalize_tags(_), do: []

  @doc "List the normalized tags stored for an entry."
  def tags(entry_id) do
    Config.repo().all(
      from(t in EntryTag,
        where: t.entry_id == ^entry_id,
        order_by: [asc: t.tag],
        select: t.tag
      )
    )
  end

  @doc """
  Replace an entry's tag set atomically. Returns the normalized tags stored.
  """
  def set_tags(entry_id, tags) when is_list(tags) do
    repo = Config.repo()

    repo.transaction(fn ->
      entry = repo.get!(Entry, entry_id)
      tags = normalize_tags(tags)

      repo.delete_all(from(t in EntryTag, where: t.entry_id == ^entry.id))

      if tags != [] do
        rows =
          Enum.map(tags, fn tag ->
            %{entry_id: entry.id, tag: tag, scope_id: entry.scope_id, owner_id: entry.owner_id}
          end)

        repo.insert_all(EntryTag, rows,
          on_conflict: :nothing,
          conflict_target: [:entry_id, :tag]
        )
      end

      tags
    end)
  end

  defp maybe_add_classification(metadata, nil), do: metadata

  defp maybe_add_classification(metadata, confidence) when is_float(confidence) do
    Map.put(metadata, :classification_confidence, confidence)
  end

  defp superseded_half_life(opts) do
    case Keyword.get(opts, :superseded_half_life) do
      days when is_number(days) and days > 0 -> days * 1.0
      _ -> 0.01
    end
  end

  @doc "Delete a knowledge entry."
  def forget(entry_id) do
    Recollect.Telemetry.span([:recollect, :forget], %{entry_id: entry_id}, fn ->
      repo = Config.repo()

      case repo.get(Entry, entry_id) do
        nil -> {:error, :not_found}
        entry -> repo.delete(entry)
      end
    end)
  end

  @doc "Create an edge between two entries."
  def connect(source_id, target_id, relation, opts \\ []) do
    Recollect.Telemetry.span([:recollect, :connect], %{relation: relation}, fn ->
      repo = Config.repo()

      attrs = %{
        source_entry_id: source_id,
        target_entry_id: target_id,
        relation: relation,
        weight: Keyword.get(opts, :weight, 1.0),
        metadata: Keyword.get(opts, :metadata, %{})
      }

      %Edge{} |> Edge.changeset(attrs) |> repo.insert()
    end)
  end

  @doc "Get recent entries for a scope."
  def recent(scope_id, opts \\ []) do
    Recollect.Telemetry.span([:recollect, :recent], %{scope_id: scope_id}, fn ->
      repo = Config.repo()
      limit = Keyword.get(opts, :limit, 20)

      repo.all(
        from(e in Entry,
          where: e.scope_id == ^scope_id and e.entry_type != "archived",
          order_by: [desc: e.inserted_at],
          limit: ^limit
        )
      )
    end)
  end

  @doc """
  Get recent entries for an owner across all scopes (global brain).

  Entries with `scope_id = nil` are treated as general knowledge
  not bound to any workspace. They appear in this query.
  """
  def recent_by_owner(owner_id, opts \\ []) do
    repo = Config.repo()
    limit = Keyword.get(opts, :limit, 50)

    repo.all(
      from(e in Entry,
        where: e.owner_id == ^owner_id and e.entry_type != "archived",
        order_by: [desc: e.inserted_at],
        limit: ^limit
      )
    )
  end

  @doc """
  Search entries by owner across all scopes (global brain search).

  Results from the current workspace scope are prioritized higher.
  Use `:scope_priority` to set the active workspace for boosting.

  Returns `{:ok, results}` with `result_type: :entry` and `scope_id` on each result.
  """
  def search_by_owner(query_text, owner_id, opts \\ []) do
    Recollect.Telemetry.span(
      [:recollect, :search_by_owner],
      %{owner_id: owner_id},
      fn ->
        Recollect.Search.Vector.search_entries_by_owner(query_text, owner_id, opts)
      end
    )
  end

  @doc """
  Mark `new_entry_id` as superseding `old_entry_id`.

  Creates a `"supersedes"` edge new → old and stamps the old entry's
  metadata with `superseded_at` (ISO8601) and `superseded_by`. Unless
  `keep_strength: true` is passed, the old entry's `half_life_days` and
  `confidence` are zeroed so decay and ranking treat it as spent.

  Superseded entries are excluded from vector entry results and edge
  traversal by default; pass `include_superseded: true` to search to opt
  out.
  """
  def supersede(new_entry_id, old_entry_id, opts \\ []) when is_list(opts) do
    Recollect.Telemetry.span(
      [:recollect, :supersede],
      %{new_entry_id: new_entry_id, old_entry_id: old_entry_id},
      fn ->
        repo = Config.repo()

        case repo.get(Entry, old_entry_id) do
          nil ->
            {:error, :not_found}

          %Entry{} = old ->
            with {:ok, _edge} <- connect(new_entry_id, old_entry_id, "supersedes") do
              metadata =
                (old.metadata || %{})
                |> Map.put("superseded_at", DateTime.to_iso8601(DateTime.utc_now()))
                |> Map.put("superseded_by", new_entry_id)

              attrs =
                if Keyword.get(opts, :keep_strength, false) do
                  %{metadata: metadata}
                else
                  # half_life_days: 0.0 is truthy in Elixir and made
                  # Strength.decay_factor/2 divide by zero (ArithmeticError).
                  # A small positive half-life expresses "spent" without
                  # crashing any decay/outcome pass that touches the row.
                  %{metadata: metadata, half_life_days: superseded_half_life(opts), confidence: 0.0}
                end

              old
              |> Entry.changeset(attrs)
              |> repo.update()
            end
        end
      end
    )
  end

  @doc """
  Apply supersession: demote old entries matching entity+relation pattern.
  New entry supersedes old ones by setting their confidence to 0.1.
  """

  def supersede(scope_id, entity, relation, _new_value) do
    Recollect.Telemetry.span(
      [:recollect, :supersede],
      %{scope_id: scope_id, entity: entity, relation: relation},
      fn ->
        repo = Config.repo()

        # Find entries matching the pattern in content
        pattern = "%#{entity}%#{relation}%"

        repo.update_all(
          from(e in Entry, where: e.scope_id == ^scope_id and e.confidence > 0.1 and ilike(e.content, ^pattern)),
          set: [confidence: 0.1, updated_at: DateTime.utc_now()]
        )
      end
    )
  end

  @doc """
  Check if new content contradicts existing knowledge.

  Extracts entity claims from the content and checks against
  existing entries in the scope. Returns:
    - `:ok` — no conflicts found
    - `{:conflict, [conflicts]}` — list of conflicts with details

  ## Example

      iex> Recollect.Knowledge.check_contradiction("Kai works on auth", scope_id, owner_id)
      {:conflict, [%{existing: "Maya works on auth", type: :attribution_conflict}]}
  """
  def check_contradiction(content, scope_id, owner_id) do
    start_time = System.monotonic_time()
    claims = Classification.extract_claims(content)

    result =
      if claims == [] do
        :ok
      else
        conflicts =
          Enum.flat_map(claims, fn claim ->
            check_claim_against_entries(claim, scope_id, owner_id)
          end)

        if conflicts == [] do
          :ok
        else
          {:conflict, conflicts}
        end
      end

    duration = System.monotonic_time() - start_time

    Recollect.Telemetry.event([:recollect, :contradiction_check, :stop], %{
      duration: duration,
      claims_count: length(claims),
      has_conflicts: match?({:conflict, _}, result)
    })

    result
  end

  defp check_claim_against_entries(claim, scope_id, owner_id) do
    repo = Config.repo()
    entity = claim[:entity]

    # Find entries mentioning this entity
    pattern = "%#{entity}%"

    entries =
      repo.all(
        from(e in Entry,
          where:
            e.scope_id == ^scope_id and e.owner_id == ^owner_id and e.entry_type != "archived" and e.confidence > 0.3 and
              ilike(e.content, ^pattern)
        )
      )

    # Check each entry for contradictions
    entries
    |> Enum.map(fn entry ->
      case detect_contradiction(claim, entry) do
        nil -> nil
        type -> %{existing: entry.content, type: type, claim: claim}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp detect_contradiction(claim, entry) do
    entity = claim[:entity]
    entry_content = String.downcase(entry.content)
    claim_entity = String.downcase(entity)

    # Skip if entry doesn't mention the claim entity
    if String.contains?(entry_content, claim_entity) do
      claim_pred = claim[:predicate]
      entry_content = entry.content

      # Attribution conflicts: different people for same work
      if claim_pred in [:works_on, :assigned_to] do
        detect_attribution_conflict(claim, entry_content)
        # Status conflicts: complete vs in-progress
      else
        detect_status_conflict(claim, entry_content)
      end
    end
  end

  defp detect_attribution_conflict(claim, entry_content) do
    entity = claim[:entity]
    claim_object = String.downcase(claim[:object])
    entity_lower = String.downcase(entity)

    # Check if entry mentions a different person for the same work
    # by looking for capitalized words that could be names near the claim object
    name_pattern = ~r/\b([A-Z][a-z]+)\b/

    names_in_entry =
      name_pattern
      |> Regex.scan(entry_content)
      |> Enum.map(fn [name] -> String.downcase(name) end)
      |> Enum.reject(&(&1 == entity_lower))

    other_mentioned =
      Enum.find(names_in_entry, fn name ->
        String.contains?(entry_content, claim_object) and
          String.contains?(entry_content, name)
      end)

    if other_mentioned do
      :attribution_conflict
    end
  end

  defp detect_status_conflict(claim, entry_content) do
    claim_object = String.downcase(claim[:object])
    entry_lower = String.downcase(entry_content)

    # Check for complete/done vs in-progress
    claim_complete? =
      String.contains?(claim_object, "complete") ||
        String.contains?(claim_object, "done") ||
        String.contains?(claim_object, "finished")

    entry_complete? =
      String.contains?(entry_lower, "complete") ||
        String.contains?(entry_lower, "done") ||
        String.contains?(entry_lower, "finished")

    entry_in_progress? =
      String.contains?(entry_lower, "in progress") ||
        String.contains?(entry_lower, "working on") ||
        String.contains?(entry_lower, "assigned to")

    # Conflict: claim says complete but entry says in-progress
    cond do
      claim_complete? && entry_in_progress? -> :status_conflict
      entry_complete? && !claim_complete? -> :status_conflict
      true -> nil
    end
  end
end
