defmodule Recollect.Dream.Reconcile do
  @moduledoc """
  Dream stage: reconcile detected contradictions dialectically (MEM-025).

  For every open conflict pair, the two claims become thesis/antithesis in
  CANONICAL order (lexicographically smaller id = thesis), and the stage
  attempts an LLM synthesis backed by both claims' content. When a
  synthesis is reachable:

  * a new synthesis claim is created (stable source_id — reruns dedupe);
  * both old claims keep their content and get `valid_to` stamped (their
    half-life is NOT zeroed);
  * `supersedes` edges run from the synthesis to each old claim;
  * the conflict rows resolve with the synthesis as the winner.

  When no synthesis is reachable (no LLM configured, the call fails, or
  the model answers UNRESOLVABLE), the reconciliation persists as
  `unresolved` — the contradiction stays visible, both claims remain, and
  the open conflict rows are left open.

  Single-flight: the canonical-pair unique index means reruns never
  duplicate a reconciliation.
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Knowledge
  alias Recollect.Schema.Conflict
  alias Recollect.Schema.Entry
  alias Recollect.Schema.Reconciliation
  alias Recollect.Telemetry
  alias Recollect.Util

  def run(scope_id, opts) do
    scope_id = Util.uuid_to_string(scope_id)
    repo = Config.repo()

    conflicts =
      repo.all(
        from(c in Conflict,
          where: c.scope_id == ^scope_id and c.status == "open",
          order_by: [desc: c.score]
        )
      )

    metrics = %{conflicts_seen: length(conflicts), reconciled: 0, unresolved: 0, skipped: 0}

    metrics =
      Enum.reduce(conflicts, metrics, fn conflict, acc ->
        {thesis_id, antithesis_id} = canonical_pair(conflict.entry_a_id, conflict.entry_b_id)

        already =
          repo.get_by(Reconciliation,
            scope_id: scope_id,
            thesis_entry_id: thesis_id,
            antithesis_entry_id: antithesis_id
          )

        if already do
          # single-flight: the pair is reconciled (or recorded unresolved)
          Map.update(acc, :skipped, 1, &(&1 + 1))
        else
          thesis = repo.get(Entry, thesis_id)
          antithesis = repo.get(Entry, antithesis_id)

          if is_nil(thesis) or is_nil(antithesis) do
            Map.update(acc, :skipped, 1, &(&1 + 1))
          else
            reconcile_pair(scope_id, thesis, antithesis, conflict, acc, opts)
          end
        end
      end)

    Telemetry.event(
      [:recollect, :dream, :reconcile, :stop],
      %{
        conflicts_seen: metrics.conflicts_seen,
        reconciled: metrics.reconciled,
        unresolved: metrics.unresolved
      },
      %{scope_id: scope_id}
    )

    {:ok, metrics}
  end

  # Private

  # Canonical order: the lexicographically smaller entry id is the thesis,
  # so (a, b) and (b, a) reconcile to the same row.
  defp canonical_pair(a, b) do
    [thesis, antithesis] = Enum.sort([a, b])
    {thesis, antithesis}
  end

  defp reconcile_pair(scope_id, thesis, antithesis, conflict, acc, opts) do
    case attempt_synthesis(thesis, antithesis, opts) do
      {:ok, text} ->
        {:ok, synthesis_entry} =
          Knowledge.remember(text,
            scope_id: scope_id,
            owner_id: conflict.owner_id || opts[:owner_id],
            entry_type: "note",
            tags: ["synthesis", "reconciled"],
            source: "system",
            source_id: "reconcile:#{thesis.id}:#{antithesis.id}",
            metadata: %{
              "thesis_id" => thesis.id,
              "antithesis_id" => antithesis.id,
              "reconciled_at" => DateTime.to_iso8601(DateTime.utc_now())
            }
          )

        repo = Config.repo()
        now = DateTime.utc_now()

        repo.transaction(fn ->
          # both old claims lose to the synthesis — content preserved,
          # validity closed, half-life untouched
          Enum.each([thesis, antithesis], fn old ->
            old
            |> Entry.changeset(%{valid_to: now})
            |> repo.update!()
          end)

          {:ok, _} = Knowledge.connect(synthesis_entry.id, thesis.id, "supersedes")
          {:ok, _} = Knowledge.connect(synthesis_entry.id, antithesis.id, "supersedes")

          # the conflict pair is now resolved in favor of the synthesis
          repo.update_all(
            from(c in Conflict,
              where:
                c.scope_id == ^scope_id and c.status == "open" and
                  ((c.entry_a_id == ^thesis.id and c.entry_b_id == ^antithesis.id) or
                     (c.entry_a_id == ^antithesis.id and c.entry_b_id == ^thesis.id))
            ),
            set: [status: "resolved", resolved_by: synthesis_entry.id, updated_at: now]
          )

          insert_reconciliation(scope_id, thesis, antithesis, synthesis_entry.id,
            reasoning: "synthesis reconciled thesis and antithesis",
            unresolved: false,
            status: "reconciled"
          )
        end)

        Map.update(acc, :reconciled, 1, &(&1 + 1))

      {:error, reason} ->
        # conservative fallback: both claims remain, the question stays open
        insert_reconciliation(scope_id, thesis, antithesis, nil,
          reasoning: "no synthesis reachable (#{inspect(reason)}); both claims remain, unresolved",
          unresolved: true,
          status: "unresolved"
        )

        Map.update(acc, :unresolved, 1, &(&1 + 1))
    end
  end

  defp insert_reconciliation(scope_id, thesis, antithesis, synthesis_entry_id, attrs) do
    %Reconciliation{}
    |> Reconciliation.changeset(%{
      scope_id: scope_id,
      thesis_entry_id: thesis.id,
      antithesis_entry_id: antithesis.id,
      synthesis_entry_id: synthesis_entry_id,
      reasoning: Keyword.fetch!(attrs, :reasoning),
      unresolved: Keyword.fetch!(attrs, :unresolved),
      status: Keyword.fetch!(attrs, :status),
      created_at: DateTime.utc_now()
    })
    |> Config.repo().insert()
    |> case do
      {:ok, _} -> :ok
      # lost the single-flight race to a concurrent distiller — fine
      {:error, _changeset} -> :ok
    end
  end

  # LLM synthesis: `synthesis_fn` (tests/hosts) overrides the configured
  # extraction llm_fn. The model must produce one reconciling sentence or
  # answer UNRESOLVABLE.
  defp attempt_synthesis(thesis, antithesis, opts) do
    llm_fn = Keyword.get(opts, :synthesis_fn) || Config.extraction_opts()[:llm_fn]

    if llm_fn do
      messages = [
        {:system, "You reconcile contradictory memory claims. Reply with ONE sentence that
          reconciles both claims if possible. If they cannot be reconciled, reply exactly:
          UNRESOLVABLE"},
        {:user, "Thesis: #{thesis.content}\n\nAntithesis: #{antithesis.content}"}
      ]

      llm_opts = Keyword.put(Config.extraction_opts(), :max_tokens, 200)

      messages
      |> llm_fn.(llm_opts)
      |> case do
        {:ok, text} when is_binary(text) ->
          trimmed = String.trim(text)

          cond do
            trimmed == "" -> {:error, :empty_synthesis}
            String.contains?(String.upcase(trimmed), "UNRESOLVABLE") -> {:error, :unresolvable}
            true -> {:ok, trimmed}
          end

        {:ok, other} ->
          {:error, {:bad_synthesis, other}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_llm_configured}
    end
  end
end
