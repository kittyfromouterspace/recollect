defmodule Recollect.Dream do
  @moduledoc """
  The dream orchestrator (MEM-023): an idempotent, locked, budgeted,
  resumable pipeline over the memory lifecycle's offline stages.

  ## Stages

  `verify` → `reconcile` → `promote` → `prune` (modules in
  `Recollect.Dream.{Verify,Reconcile,Promote,Prune}`); a run may request a
  subset or inject its own stage modules (each implements
  `run(scope_id, opts) :: {:ok, metrics} | {:error, reason}`, executed
  inside its own transaction).

  ## Idempotency

  The `input_hash` covers the event-ledger high-water mark (latest event
  timestamp + count), the engine config, and the requested stages — never
  entry `updated_at`, which dreams themselves mutate. A `:done` run with
  the same hash is returned as-is (`replayed: true`) unless `force: true`;
  failed and aborted runs never block a retry, and a rerun resumes past
  the stages the failed run already completed.

  ## Locking

  One run per scope: Postgres takes a session-level advisory lock on a
  dedicated connection for the whole run (`{:error, :locked}` when busy);
  SQLite/libSQL uses `:global.trans` (single-node). Contention surfaces as
  `{:error, :locked}` — the caller (queue) decides whether to retry.

  ## Budget and cancellation

  `:max_wall_ms` stops the run at a stage boundary with status `aborted`
  (never mid-stage), and `Dream.cancel/1` sets a flag stages can poll via
  `cancelled?/1`.
  """

  alias Recollect.Config
  alias Recollect.Dream.Run
  alias Recollect.Schema.DreamRun
  alias Recollect.Telemetry
  alias Recollect.Util

  @default_stages [:verify, :reconcile, :promote, :prune]

  @stage_registry %{
    verify: Recollect.Dream.Verify,
    reconcile: Recollect.Dream.Reconcile,
    promote: Recollect.Dream.Promote,
    prune: Recollect.Dream.Prune
  }

  @doc "Resolve `opts[:stages]` (atoms into the registry, modules pass through)."
  def resolve_stages(opts) do
    stages = Keyword.get(opts, :stages, @default_stages)

    Enum.map(stages, fn
      stage when is_atom(stage) ->
        case Map.fetch(@stage_registry, stage) do
          {:ok, mod} ->
            mod

          :error ->
            case Code.ensure_loaded(stage) do
              {:module, _} -> stage
              _ -> raise ArgumentError, "unknown dream stage: #{inspect(stage)}"
            end
        end

      other ->
        raise ArgumentError, "dream stages must be atoms or modules, got: #{inspect(other)}"
    end)
  end

  @doc """
  What a run would do, without writing anything: the input hash, the
  stages, whether a completed run already covers this input, and which
  stages a rerun would still execute (resume).
  """
  def plan(scope_id, opts \\ []) do
    stages = resolve_stages(opts)
    input_hash = Run.input_hash(scope_id, stages, opts)
    prior_done = Run.find_done(scope_id, input_hash, Keyword.get(opts, :force, false))
    remaining = Run.remaining_stages(scope_id, input_hash, stages)

    {:ok,
     %{
       input_hash: input_hash,
       stages: Enum.map(stages, &to_string/1),
       remaining: Enum.map(remaining, &to_string/1),
       cached: prior_done != nil,
       prior_done_id: prior_done && prior_done.id,
       dry_run: true
     }}
  end

  @doc """
  Run the dream for a scope.

  ## Options

  - `:stages` — subset or custom modules (default: all four stages)
  - `:force` — ignore a completed run with the same hash (default: false)
  - `:idempotency_key` — explicit fingerprint when the event ledger is disabled
  - `:owner_id` — attributed to the run row
  - `:max_wall_ms` — wall-clock budget; exceeded ⇒ status `aborted` at a
    stage boundary (default: `dream.max_wall_ms`, 30_000)
  - `:lock_fn` — override the scope lock (tests); wraps `fun` and returns
    `{:error, :locked}` when the scope is busy
  - `:staging_limit`, `:dream.*` stage knobs pass through to the stages

  Returns `{:ok, map}` with `:status` ("done" | "failed" | "aborted"),
  `:stages`, `:metrics`, and `:replayed` (true when a completed run with
  the same input hash was returned without work), or `{:error, :locked}`.
  """
  def run(scope_id, opts \\ []) do
    scope_id = Util.uuid_to_string(scope_id)
    stages = resolve_stages(opts)
    input_hash = Run.input_hash(scope_id, stages, opts)

    prior_done = Run.find_done(scope_id, input_hash, Keyword.get(opts, :force, false))

    if prior_done do
      {:ok,
       %{
         id: prior_done.id,
         scope_id: scope_id,
         status: "done",
         stages: prior_done.stages,
         metrics: prior_done.metrics,
         replayed: true
       }}
    else
      if Keyword.get(opts, :force, false), do: {:ok, _} = Run.clear_done(scope_id, input_hash)

      remaining = Run.remaining_stages(scope_id, input_hash, stages)

      lock_fn = Keyword.get(opts, :lock_fn) || default_lock_fn(scope_id, opts)

      case lock_fn.(fn -> execute(scope_id, input_hash, remaining, stages, opts) end) do
        {:error, :locked} = locked ->
          locked

        {:ok, result} ->
          {:ok, result}

        other ->
          other
      end
    end
  end

  @doc "Fetch a run by id."
  def status(run_id) do
    case Config.repo().get(DreamRun, Util.uuid_to_string(run_id)) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  @doc """
  Best-effort cancellation: stages and the orchestrator poll this flag
  between items/stages. A running stage finishes its transaction first.
  """
  def cancel(run_id) do
    :persistent_term.put({__MODULE__, :cancelled, Util.uuid_to_string(run_id)}, true)
    :ok
  end

  def cancelled?(run_id) do
    :persistent_term.get({__MODULE__, :cancelled, Util.uuid_to_string(run_id)}, false)
  end

  # Private

  defp execute(scope_id, input_hash, remaining, _all_stages, opts) do
    {:ok, run} = Run.start(scope_id, input_hash, remaining, opts)
    started_at = DateTime.utc_now()
    max_wall_ms = Keyword.get(opts, :max_wall_ms) || Config.dream()[:max_wall_ms] || 30_000
    stage_opts = Keyword.put(opts, :dream_run_id, run.id)

    {run, status, error, _reason} =
      Enum.reduce_while(remaining, {run, "running", nil, nil}, fn stage, {run, _status, _err, _rsn} ->
        cond do
          cancelled?(run.id) ->
            {:halt, {run, "aborted", "cancelled", :cancelled}}

          wall_exceeded?(started_at, max_wall_ms) ->
            {:halt, {run, "aborted", "wall budget exceeded", :budget}}

          true ->
            {run, outcome} = run_stage(run, scope_id, stage, stage_opts)

            case outcome do
              :ok ->
                {:cont, {run, "running", nil, nil}}

              {:error, :cancelled} ->
                {:halt, {run, "aborted", "cancelled", :cancelled}}

              {:error, reason} ->
                {:halt, {run, "failed", inspect(reason), nil}}
            end
        end
      end)

    final_status = if status == "running", do: "done", else: status

    {:ok, final} = Run.finish(run.id, final_status, error)

    Telemetry.event([:recollect, :dream, :stop], %{}, %{
      scope_id: scope_id,
      status: final.status,
      stages: Map.keys(final.stages || %{})
    })

    {:ok,
     %{
       id: final.id,
       scope_id: scope_id,
       status: final.status,
       stages: final.stages,
       metrics: final.metrics,
       error: final.error,
       replayed: false
     }}
  end

  # One stage, one transaction: its writes commit or vanish together, and a
  # failing stage leaves earlier stages recorded as completed (resumable).
  defp run_stage(run, scope_id, stage, stage_opts) do
    repo = Config.repo()

    result =
      try do
        repo.transaction(fn ->
          case stage.run(scope_id, stage_opts) do
            {:ok, metrics} -> {:ok, metrics}
            {:error, reason} -> repo.rollback({:stage_error, reason})
          end
        end)
      rescue
        e -> {:error, {:stage_raised, Exception.message(e)}}
      end

    case result do
      {:ok, {:ok, metrics}} ->
        {:ok, _} = Run.record_stage(run.id, stage_name(stage), "completed", metrics)
        {run, :ok}

      {:ok, {:rollback, {:stage_error, reason}}} ->
        {:ok, _} = Run.record_stage(run.id, stage_name(stage), "failed", %{"reason" => inspect(reason)})
        {run, {:error, reason}}

      {:error, {:stage_error, reason}} ->
        {:ok, _} = Run.record_stage(run.id, stage_name(stage), "failed", %{"reason" => inspect(reason)})
        {run, {:error, reason}}

      {:error, reason} ->
        {:ok, _} = Run.record_stage(run.id, stage_name(stage), "failed", %{"reason" => inspect(reason)})
        {run, {:error, {:stage_raised, inspect(reason)}}}
    end
  end

  defp stage_name(stage) when is_atom(stage) do
    stage
    |> to_string()
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end

  defp wall_exceeded?(_started_at, nil), do: false

  defp wall_exceeded?(started_at, max_wall_ms) do
    DateTime.diff(DateTime.utc_now(), started_at, :millisecond) >= max_wall_ms
  end

  defp default_lock_fn(scope_id, opts) do
    fn fun ->
      if Config.adapter().dialect() == :postgres do
        pg_lock(scope_id, opts, fun)
      else
        # SQLite/libSQL: single node — a :global transaction plus the
        # caller's DB transactions are enough.
        {{:recollect_dream, scope_id}, self()}
        |> :global.trans(fun, [node()], 30_000)
        |> case do
          {:ok, result} -> result
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp pg_lock(scope_id, opts, fun) do
    repo = Config.repo()

    repo.checkout(fn ->
      key = Run.lock_key(scope_id)
      wait_ms = Keyword.get(opts, :lock_wait_ms) || Config.dream()[:lock_wait_ms] || 0

      acquired =
        if wait_ms > 0 do
          # block, but no longer than the configured wait
          repo.query!("SET lock_timeout = $1", ["#{wait_ms}ms"])
          repo.query!("SELECT pg_advisory_lock($1)", [key])
          true
        else
          case repo.query!("SELECT pg_try_advisory_lock($1)", [key]) do
            %{rows: [[true]]} -> true
            _ -> false
          end
        end

      if acquired do
        try do
          fun.()
        after
          repo.query!("SELECT pg_advisory_unlock($1)", [key])
        end
      else
        {:error, :locked}
      end
    end)
  end
end
