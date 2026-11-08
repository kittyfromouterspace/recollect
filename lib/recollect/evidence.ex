defmodule Recollect.Evidence do
  @moduledoc """
  Links between claims (`Recollect.Schema.Entry`) and their evidence —
  an event from the ledger or a raw file reference.

  A claim may have evidence that supports, contradicts, or supersedes it, or
  it may be derived from another source. Links dedupe on
  `(entry_id, relation, source_type, source_ref)`, so relinking the same
  evidence is idempotent.
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Schema.Entry
  alias Recollect.Schema.Event, as: EventRow
  alias Recollect.Schema.Evidence, as: EvidenceRow
  alias Recollect.Telemetry
  alias Recollect.Util

  @doc """
  Link an entry to an event or reference.

  ## Options

  - `:event_id` — the ledger event that justifies the claim (validated to exist)
  - `:source_type` / `:source_ref` — e.g. `file` + path, `test` + test id,
    `url` + link (at least `source_ref` makes the link deduped)
  - `:excerpt` — the verbatim supporting quote
  - `:weight` — evidence strength (default 1.0, >= 0)

  Returns `{:ok, evidence}` — the link, existing one on dedupe.
  """
  def link(entry_id, relation, opts \\ [])

  def link(entry_id, relation, opts) do
    relation = to_string(relation)
    repo = Config.repo()

    with :ok <- validate_relation(relation),
         {:ok, entry_id} <- verify_entry(repo, entry_id),
         {:ok, event_id} <- maybe_event_id(repo, opts[:event_id]) do
      attrs = %{
        entry_id: entry_id,
        event_id: event_id,
        relation: relation,
        excerpt: opts[:excerpt],
        source_type: opts[:source_type],
        source_ref: opts[:source_ref],
        weight: opts[:weight] || 1.0,
        created_at: DateTime.utc_now()
      }

      Telemetry.span([:recollect, :evidence, :link], %{relation: relation}, fn ->
        link_rows(repo, attrs)
      end)
    end
  end

  @doc """
  Evidence rows for an entry, newest first, with their events preloaded
  (the event is `nil` for file/url-based evidence or if its event row was
  pruned).
  """
  def for_entry(entry_id) do
    entry_id = Util.uuid_to_string(entry_id)

    rows =
      Config.repo().all(
        from(ev in EvidenceRow,
          where: ev.entry_id == ^entry_id,
          left_join: e in assoc(ev, :event),
          preload: [event: e],
          order_by: [desc: ev.created_at],
          select: ev
        )
      )

    {:ok, rows}
  end

  # Private

  defp validate_relation(relation) do
    if relation in EvidenceRow.relations() do
      :ok
    else
      {:error, {:invalid_relation, relation}}
    end
  end

  defp verify_entry(repo, entry_id) do
    entry_id = Util.uuid_to_string(entry_id)

    case repo.get(Entry, entry_id) do
      %Entry{} -> {:ok, entry_id}
      nil -> {:error, :entry_not_found}
    end
  end

  defp maybe_event_id(_repo, nil), do: {:ok, nil}

  defp maybe_event_id(repo, event_id) do
    event_id = Util.uuid_to_string(event_id)

    case repo.get(EventRow, event_id) do
      %EventRow{} -> {:ok, event_id}
      nil -> {:error, :event_not_found}
    end
  end

  # Dedupe first (avoid relying on the partial unique index, which SQLite
  # can't use as an ON CONFLICT target), insert second, and race-resolve
  # third: if a concurrent writer inserts the same link, its unique-violation
  # is rescued and the already-inserted row is returned. The dedupe contract
  # only applies to ref'd evidence — the same contract the partial unique
  # index enforces at the DB level.
  defp link_rows(repo, %{source_ref: source_ref} = attrs) when not is_nil(source_ref) do
    case repo.one(dedup_query(attrs)) do
      %EvidenceRow{} = existing ->
        {:ok, existing}

      nil ->
        insert_link(repo, attrs)
    end
  end

  defp link_rows(repo, attrs) do
    insert_link(repo, attrs)
  end

  defp insert_link(repo, attrs) do
    changeset = EvidenceRow.changeset(%EvidenceRow{}, attrs)

    result =
      try do
        repo.insert(changeset)
      rescue
        # A concurrent writer inserted the same link between the dedupe
        # lookup and this insert — recover the winner's row.
        e in Ecto.ConstraintError ->
          if String.contains?(e.message, "recollect_evidence_unique_idx") do
            case repo.one(dedup_query(attrs)) do
              %EvidenceRow{} = existing -> {:ok, existing}
              nil -> {:error, {:constraint_error, attrs}}
            end
          else
            reraise e, __STACKTRACE__
          end
      end

    case result do
      {:ok, %EvidenceRow{}} = ok -> ok
      {:error, changeset} -> {:error, {:invalid_evidence, changeset}}
      other -> other
    end
  end

  defp dedup_query(attrs) do
    base =
      from(ev in EvidenceRow,
        where: ev.entry_id == ^attrs.entry_id and ev.relation == ^attrs.relation
      )

    base
    |> null_or_match(:source_type, attrs.source_type)
    |> null_or_match(:source_ref, attrs.source_ref)
  end

  # NULL never equals NULL in SQL — nil source_type is filtered explicitly.
  defp null_or_match(query, key, nil) do
    where(query, [ev], is_nil(field(ev, ^key)))
  end

  defp null_or_match(query, key, value) do
    where(query, [ev], field(ev, ^key) == ^value)
  end
end
