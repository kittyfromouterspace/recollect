defmodule Recollect.Dream.Run do
  @moduledoc """
  Bookkeeping for dream runs (MEM-023): input hashing, run lifecycle, and
  per-stage progress. The hash deliberately EXCLUDES entry `updated_at` —
  dream runs mutate entries, so updated_at would make every rerun look
  like new input.
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Schema.DreamRun
  alias Recollect.Schema.Event
  alias Recollect.Util

  @doc """
  Fingerprint of everything that changes the outcome: the event-ledger
  high-water mark (latest event id + event count), the dream config, and
  the requested stages. When events are disabled, `idempotency_key` is
  required instead.
  """
  def input_hash(scope_id, stages, opts) do
    scope_id = Util.uuid_to_string(scope_id)
    idempotency_key = Keyword.get(opts, :idempotency_key)

    if Config.events()[:enabled] == false and is_nil(idempotency_key) do
      raise ArgumentError,
            "the event ledger is disabled — pass idempotency_key to Dream.run/2 for an explicit fingerprint"
    end

    parts =
      if idempotency_key do
        ["key", idempotency_key]
      else
        {latest_id, count} = event_high_water(scope_id)
        ["ledger", latest_id || "none", Integer.to_string(count)]
      end

    parts = parts ++ [config_fingerprint(), Enum.join(Enum.map(stages, &to_string/1), ",")]

    :sha256
    |> :crypto.hash(Enum.join(parts, "|"))
    |> Base.encode16(case: :lower)
  end

  defp event_high_water(scope_id) do
    repo = Config.repo()

    from(e in Event,
      where: e.scope_id == ^scope_id,
      select: %{latest: max(e.created_at), count: count(e.id)}
    )
    |> repo.one()
    |> case do
      nil -> {nil, 0}
      %{latest: latest, count: count} -> {latest && DateTime.to_iso8601(latest), count}
    end
  end

  defp config_fingerprint do
    inspected =
      :recollect
      |> Application.get_all_env()
      |> inspect()

    :sha256
    |> :crypto.hash(inspected)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc "Find a completed run for the hash; nil when absent or when forcing."
  def find_done(scope_id, input_hash, force?) do
    scope_id = Util.uuid_to_string(scope_id)
    repo = Config.repo()

    if force? do
      nil
    else
      repo.one(
        from(r in DreamRun,
          where: r.scope_id == ^scope_id and r.input_hash == ^input_hash and r.status == "done",
          order_by: [desc: r.finished_at],
          limit: 1
        )
      )
    end
  end

  @doc "Insert the run row in `running` state."
  def start(scope_id, input_hash, stages, opts) do
    scope_id = Util.uuid_to_string(scope_id)
    repo = Config.repo()
    now = DateTime.utc_now()

    %DreamRun{}
    |> DreamRun.changeset(%{
      owner_id: Util.uuid_to_string(Keyword.get(opts, :owner_id)),
      scope_id: scope_id,
      input_hash: input_hash,
      status: "running",
      stages: %{},
      metrics: %{requested_stages: Enum.map(stages, &to_string/1)},
      started_at: now
    })
    |> repo.insert()
  end

  @doc "Record one stage's completion or failure."
  def record_stage(run_id, stage, status, metrics \\ %{}) do
    run_id = Util.uuid_to_string(run_id)
    repo = Config.repo()
    run = repo.get!(DreamRun, run_id)

    stages =
      Map.put(run.stages || %{}, to_string(stage), %{
        status: to_string(status),
        metrics: metrics || %{},
        at: DateTime.to_iso8601(DateTime.utc_now())
      })

    run
    |> DreamRun.changeset(%{stages: stages})
    |> repo.update()
  end

  @doc "Finish a run: done | failed | aborted with an optional error."
  def finish(run_id, status, error \\ nil, extra_metrics \\ %{}) do
    run_id = Util.uuid_to_string(run_id)
    repo = Config.repo()
    run = repo.get!(DreamRun, run_id)

    metrics = Map.merge(run.metrics || %{}, extra_metrics)

    run
    |> DreamRun.changeset(%{
      status: to_string(status),
      finished_at: DateTime.utc_now(),
      error: error,
      metrics: metrics
    })
    |> repo.update()
  end

  @doc """
  Stages still to run on a rerun: everything not recorded `completed` in
  the latest non-done run with the same hash (resume support).
  """
  def remaining_stages(scope_id, input_hash, stages) do
    scope_id = Util.uuid_to_string(scope_id)
    repo = Config.repo()

    prior =
      repo.one(
        from(r in DreamRun,
          where:
            r.scope_id == ^scope_id and r.input_hash == ^input_hash and
              r.status in ["failed", "aborted"],
          order_by: [desc: r.started_at],
          limit: 1
        )
      )

    case prior do
      nil ->
        stages

      run ->
        completed = MapSet.new(for {s, %{"status" => "completed"}} <- run.stages || %{}, do: s)

        Enum.reject(stages, &(stage_name(&1) in completed))
    end
  end

  @doc "Short bookkeeping name for a stage module (`Recollect.Dream.Verify` → `verify`)."
  def stage_name(stage) when is_atom(stage) do
    stage
    |> to_string()
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end

  @doc "Remove prior done runs for this hash — `force: true` replaces the record."
  def clear_done(scope_id, input_hash) do
    scope_id = Util.uuid_to_string(scope_id)

    {count, _} =
      Config.repo().delete_all(
        from(r in DreamRun,
          where: r.scope_id == ^scope_id and r.input_hash == ^input_hash and r.status == "done"
        )
      )

    {:ok, count}
  end

  @doc "The scope-scoped advisory-lock key."
  def lock_key(scope_id) do
    :erlang.phash2({"recollect_dream", scope_id})
  end
end
