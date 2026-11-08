defmodule Recollect.Event do
  @moduledoc """
  The raw event ledger (L0). Append-only, NOT embedded by default: events are
  the verifiable substrate — `Recollect.Schema.Entry` (L1) claims are what
  search reads, and every claim can trace back to at least one event or file
  reference through `Recollect.Schema.Evidence`.

  Recording the same event twice (same content/source within an owner) is
  idempotent: the pre-existing row is returned.
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Schema.Event, as: EventRow
  alias Recollect.Schema.Evidence
  alias Recollect.Telemetry
  alias Recollect.Util

  @doc """
  Record a raw event in the ledger.

  ## Options

  - `:owner_id` (required) — UUID of the owning user
  - `:event_type` (required) — `message | tool_call | tool_result | file_change |
    test_run | commit | state | custom`
  - `:content` or `:source_uri` — at least one must be present; an event with
    neither carries nothing verifiable
  - `:occurred_at` — when it happened (default: now)
  - `:scope_id`, `:session_id`, `:agent`, `:role`, `:source_ref`,
    `:parent_event_id`, `:metadata` — optional context

  Returns `{:ok, event}` — the newly recorded row, or the pre-existing row
  when an identical event was already recorded for this owner.
  """
  def record(opts) when is_list(opts) do
    event_type = opts[:event_type]
    owner_id = Util.uuid_to_string(opts[:owner_id])
    content = opts[:content]
    source_uri = opts[:source_uri]
    source_ref = opts[:source_ref]
    content_hash = content_hash(content, source_uri, source_ref)

    cond do
      is_nil(owner_id) ->
        {:error, :owner_id_required}

      is_nil(event_type) or event_type not in EventRow.event_types() ->
        {:error, {:invalid_event_type, event_type}}

      blank?(content) and blank?(source_uri) ->
        {:error, :missing_content}

      is_nil(content_hash) ->
        {:error, :missing_content}

      true ->
        do_record(%{
          owner_id: owner_id,
          scope_id: Util.uuid_to_string(opts[:scope_id]),
          session_id: Util.uuid_to_string(opts[:session_id]),
          agent: opts[:agent],
          event_type: to_string(event_type),
          role: opts[:role],
          content: content,
          occurred_at: opts[:occurred_at] || DateTime.utc_now(),
          source_uri: source_uri,
          source_ref: source_ref,
          parent_event_id: Util.uuid_to_string(opts[:parent_event_id]),
          metadata: opts[:metadata] || %{},
          content_hash: content_hash,
          created_at: DateTime.utc_now()
        })
    end
  end

  @doc """
  List ledger events for a scope.

  ## Options

  - `:since` / `:until` — bound `occurred_at`
  - `:session_id` — restrict to one session
  - `:event_type` — restrict to one type
  - `:limit` — max rows (default: 200)
  - `:order` — `:asc | :desc` by `occurred_at` (default: `:desc`)
  """
  def list(scope_id, opts \\ []) do
    scope_id = Util.uuid_to_string(scope_id)
    since = Keyword.get(opts, :since)
    until = Keyword.get(opts, :until)
    session_id = Util.uuid_to_string(opts[:session_id])
    event_type = Keyword.get(opts, :event_type)
    limit = Keyword.get(opts, :limit, 200)
    order = if opts[:order] == :asc, do: :asc, else: :desc

    query =
      from(e in EventRow,
        where: e.scope_id == ^scope_id,
        order_by: [{^order, e.occurred_at}],
        limit: ^limit,
        select: e
      )

    query =
      if since do
        where(query, [e], e.occurred_at >= ^since)
      else
        query
      end

    query =
      if until do
        where(query, [e], e.occurred_at <= ^until)
      else
        query
      end

    query =
      if session_id do
        where(query, [e], e.session_id == ^session_id)
      else
        query
      end

    query =
      if event_type do
        where(query, [e], e.event_type == ^to_string(event_type))
      else
        query
      end

    {:ok, Config.repo().all(query)}
  end

  @doc """
  Delete events older than `events.retention_days` (default 30) — where
  "older" is `occurred_at`, so a backfilled transcript ages out on its own
  schedule. Events referenced by evidence survive: their claims must stay
  traceable.
  """
  def prune(opts \\ []) when is_list(opts) do
    retention_days =
      Keyword.get(opts, :retention_days) || Config.events()[:retention_days] || 30

    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)
    repo = Config.repo()

    {count, _} =
      repo.delete_all(
        from(e in EventRow,
          where: e.occurred_at < ^cutoff,
          # NULL event_ids in the IN-list would make NOT IN never match —
          # filter them out so unlinked evidence rows don't shield every event.
          where: e.id not in subquery(from(ev in Evidence, where: not is_nil(ev.event_id), select: ev.event_id))
        )
      )

    {:ok, %{pruned: count}}
  end

  # Private

  defp do_record(attrs) do
    Telemetry.span([:recollect, :event, :record], %{event_type: attrs.event_type}, fn ->
      repo = Config.repo()

      # Idempotent ledger insert: look for the identical (owner_id,
      # content_hash) event first — recording the same event twice must
      # yield one logical row. The unique index covers the race: a
      # concurrent same-hash insert raises, and the winner's row is
      # re-fetched (Ecto's changeset insert cannot report `DO NOTHING` to
      # us — it hands back the unsaved struct with its client-side id).
      case existing(repo, attrs.owner_id, attrs.content_hash) do
        %EventRow{} = event ->
          {:ok, event}

        nil ->
          insert_new(repo, attrs)
      end
    end)
  end

  defp insert_new(repo, attrs) do
    changeset = EventRow.changeset(%EventRow{}, attrs)

    result =
      try do
        repo.insert(changeset)
      rescue
        e in Ecto.ConstraintError ->
          if String.contains?(e.message, "recollect_events_owner_content_hash_idx") do
            case existing(repo, attrs.owner_id, attrs.content_hash) do
              %EventRow{} = event -> {:ok, event}
              nil -> {:error, {:constraint_error, attrs}}
            end
          else
            reraise e, __STACKTRACE__
          end
      end

    case result do
      {:ok, %EventRow{}} = ok -> ok
      {:error, changeset} -> {:error, {:invalid_event, changeset}}
      other -> other
    end
  end

  defp existing(repo, owner_id, content_hash) do
    repo.one(
      from(e in EventRow,
        where: e.owner_id == ^owner_id and e.content_hash == ^content_hash
      )
    )
  end

  # SHA-256 over the verifiable parts (content, then source URI, then source
  # ref), NUL-separated to avoid boundary ambiguity. Any identical recording
  # therefore hashes identically across runs.
  defp content_hash(content, source_uri, source_ref) do
    parts = Enum.reject([content, source_uri, source_ref], &blank?/1)

    case parts do
      [] ->
        nil

      parts ->
        joined = Enum.join(parts, "\u0000")
        :sha256 |> :crypto.hash(joined) |> Base.encode16(case: :lower)
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
