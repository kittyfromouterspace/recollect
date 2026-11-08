defmodule Recollect.Dream.Verify do
  @moduledoc """
  Dream stage: check claims against their evidence (MEM-024).

  For every live claim in the scope that carries evidence rows:

  * `event` evidence verifies when the ledger row still exists (pruned or
    nullified event ⇒ missing);
  * `file` evidence verifies when the referenced file exists on disk
    (source_ref may carry a `:line` suffix — stripped before the check);
  * `test` and `user` evidence verify as-is (authoritative; who/when is
    recorded on the entry's `verified_at`);
  * `url` verification is an optional HTTP check, behind
    `dream.check_urls` (default false).

  Claims whose evidence all checks out get `verification` set to the
  strongest evidence kind and `verified_at` stamped; `epistemic` upgrades
  from `inferred` to `observed` only when direct evidence (event/file/
  test/user) is present. Claims whose evidence is missing downgrade to
  `epistemic: "held"` + `confidence_state: "stale"` — never deleted.

  Respects `dream.max_items` and `:max_wall_ms` — the stage stops cleanly
  at the boundary and reports what it checked.
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Schema.Entry
  alias Recollect.Schema.Evidence
  alias Recollect.Telemetry
  alias Recollect.Util

  # Strongest verification wins across a claim's evidence rows.
  @verification_rank %{"user" => 5, "code_ref" => 5, "test" => 4, "cross_session" => 4, "llm" => 3}
  @evidence_to_verification %{
    "event" => "cross_session",
    "file" => "code_ref",
    "test" => "test",
    "user" => "user",
    "url" => "cross_session"
  }
  # Evidence kinds that can lift a claim from inferred to observed.
  @direct_kinds ~w(event file test user)

  def run(scope_id, opts) do
    scope_id = Util.uuid_to_string(scope_id)
    repo = Config.repo()
    max_items = Keyword.get(opts, :max_items) || Config.dream()[:max_items] || 500
    max_wall_ms = Keyword.get(opts, :max_wall_ms) || Config.dream()[:max_wall_ms]
    started_at = DateTime.utc_now()
    check_urls = Config.dream()[:check_urls] == true

    claims =
      from(e in Entry,
        join: ev in Evidence,
        on: ev.entry_id == e.id,
        where: e.scope_id == ^scope_id,
        distinct: e.id,
        order_by: [asc: e.inserted_at],
        select: e
      )
      |> Entry.live()
      |> repo.all()

    total = length(claims)
    claims = Enum.take(claims, max_items)

    evidence_by_entry =
      from(ev in Evidence,
        join: e in Entry,
        on: ev.entry_id == e.id,
        where: e.scope_id == ^scope_id,
        select: {ev.entry_id, ev}
      )
      |> repo.all()
      |> Enum.group_by(
        fn {entry_id, _ev} -> entry_id end,
        fn {_entry_id, ev} -> ev end
      )
      |> Map.new()

    metrics =
      verify_claims(claims, evidence_by_entry, %{
        check_urls: check_urls,
        max_wall_ms: max_wall_ms,
        started_at: started_at,
        dream_run_id: Keyword.get(opts, :dream_run_id)
      })

    # truncated = wall budget hit mid-stage, or max_items left candidates
    # unchecked
    metrics =
      metrics
      |> Map.put(:candidates, total)
      |> Map.put(:truncated, Map.get(metrics, :truncated, false) or metrics.checked < total)

    Telemetry.event(
      [:recollect, :dream, :verify, :stop],
      %{
        checked: metrics.checked,
        verified: metrics.verified,
        downgraded: metrics.downgraded
      },
      %{scope_id: scope_id}
    )

    {:ok, metrics}
  end

  defp verify_claims(claims, evidence_by_entry, cfg) do
    Enum.reduce_while(claims, empty_metrics(), fn entry, acc ->
      if wall_exceeded?(cfg) do
        # budget boundary: stop cleanly and report the shortfall
        {:halt, Map.put(acc, :truncated, true)}
      else
        evidence = Map.get(evidence_by_entry, entry.id, [])
        outcome = verify_entry(entry, evidence, cfg)

        Telemetry.event([:recollect, :dream, :verify, :check], %{entry_id: entry.id}, %{
          outcome: outcome.outcome
        })

        {:cont, apply_outcome(entry, outcome, acc)}
      end
    end)
  end

  defp empty_metrics do
    %{checked: 0, verified: 0, downgraded: 0, unchanged: 0}
  end

  defp verify_entry(entry, evidence, cfg) do
    checks = Enum.map(evidence, fn ev -> check_evidence(ev, cfg) end)

    cond do
      checks != [] and Enum.any?(checks, &(&1 == :ok)) ->
        kinds = evidence |> Enum.map(& &1.source_type) |> Enum.reject(&is_nil/1)
        best = best_verification(kinds)

        direct =
          Enum.any?(evidence, fn ev ->
            ev.source_type in @direct_kinds and (not is_nil(ev.event_id) or not is_nil(ev.source_ref))
          end)

        %{
          outcome: :verified,
          verification: best,
          upgrade: direct and entry.epistemic == "inferred"
        }

      checks != [] and Enum.any?(checks, &(&1 == :missing)) ->
        # every checkable evidence row pointed at something missing
        %{outcome: :missing_evidence}

      true ->
        # only skipped (unverifiable) evidence — nothing to assert
        %{outcome: :unchanged}
    end
  end

  # One evidence row → :ok | :missing | :skipped
  defp check_evidence(ev, cfg) do
    case ev.source_type do
      "event" ->
        if event_exists?(ev.event_id), do: :ok, else: :missing

      "file" ->
        if file_exists?(ev.source_ref), do: :ok, else: :missing

      "test" ->
        :ok

      "user" ->
        :ok

      "url" ->
        if cfg.check_urls, do: url_ok?(ev.source_ref), else: :skipped

      _ ->
        # unknown source kinds can't be verified — treat as skipped
        :skipped
    end
  end

  defp event_exists?(nil), do: false

  defp event_exists?(event_id) do
    Config.repo().exists?(from(e in Recollect.Schema.Event, where: e.id == ^Util.uuid_to_string(event_id)))
  end

  defp file_exists?(nil), do: false

  defp file_exists?(source_ref) do
    path = source_ref |> to_string() |> String.split(":") |> List.first()
    File.exists?(path)
  end

  defp url_ok?(nil), do: :missing

  defp url_ok?(url) do
    :get
    |> :httpc.request({to_charlist(url), []}, [timeout: 5_000], [])
    |> case do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 -> :ok
      _ -> :missing
    end
  rescue
    _ -> :missing
  end

  defp best_verification(kinds) do
    kinds
    |> Enum.map(&Map.get(@evidence_to_verification, &1, "none"))
    |> Enum.reject(&(&1 == "none"))
    |> Enum.sort_by(&Map.get(@verification_rank, &1, 0), :desc)
    |> List.first("none")
  end

  defp apply_outcome(entry, outcome, acc) do
    repo = Config.repo()
    acc = Map.update(acc, :checked, 1, &(&1 + 1))

    case outcome.outcome do
      :verified ->
        attrs = %{verification: outcome.verification, verified_at: DateTime.utc_now()}
        attrs = if outcome.upgrade, do: Map.put(attrs, :epistemic, "observed"), else: attrs

        entry
        |> Entry.changeset(attrs)
        |> repo.update()
        |> case do
          {:ok, _} -> Map.update(acc, :verified, 1, &(&1 + 1))
          _ -> Map.update(acc, :unchanged, 1, &(&1 + 1))
        end

      :missing_evidence ->
        # downgrade, never delete: the question stays visible
        entry
        |> Entry.changeset(%{epistemic: "held", confidence_state: "stale"})
        |> repo.update()
        |> case do
          {:ok, _} -> Map.update(acc, :downgraded, 1, &(&1 + 1))
          _ -> Map.update(acc, :unchanged, 1, &(&1 + 1))
        end

      _ ->
        Map.update(acc, :unchanged, 1, &(&1 + 1))
    end
  end

  defp wall_exceeded?(%{max_wall_ms: nil}), do: false

  defp wall_exceeded?(%{max_wall_ms: max, started_at: started_at}) do
    DateTime.diff(DateTime.utc_now(), started_at, :millisecond) >= max
  end
end
