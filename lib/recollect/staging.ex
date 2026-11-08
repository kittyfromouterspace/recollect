defmodule Recollect.Staging do
  @moduledoc """
  The durable staging tier (MEM-040): candidate notes survive node restarts
  and work across a fleet, unlike the ephemeral per-node `WorkingMemory`
  (deprecated; removal scheduled for 1.0).

  * `stage/3` — insert a candidate note (secret-guarded unless disabled)
  * `drain/2` — atomically claim staged rows (Postgres:
    `FOR UPDATE SKIP LOCKED`; SQLite: transaction serialization), so two
    concurrent distillers can never claim the same rows
  * `restage/1` — put failed rows back to `staged` for retry
  * `prune/1` — retention GC for drained rows
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Guards
  alias Recollect.Schema.Staging
  alias Recollect.Telemetry
  alias Recollect.Util

  @default_retention_days 7
  @default_max_items 1_000

  @doc """
  Insert a candidate note. Runs the engine-level secret guard unless
  disabled (`allow_secrets: true`); guarded content never lands.

  Options: `:owner_id` (required), `:source`, `:priority` (0..1, default
  0.5), `:metadata`, `:allow_secrets`.

  Returns `{:ok, row}` or `{:error, :possible_secret | :staging_backlog_full |
  changeset}`.
  """
  def stage(scope_id, content, opts \\ []) do
    case Guards.check(content, opts) do
      :ok ->
        do_stage(scope_id, content, opts)

      {:error, :possible_secret} = error ->
        require Logger

        Logger.warning("Recollect.Staging: staged content rejected — looks like a credential")

        error
    end
  end

  defp do_stage(scope_id, content, opts) do
    scope_id = Util.uuid_to_string(scope_id)
    owner_id = Util.uuid_to_string(Keyword.fetch!(opts, :owner_id))
    repo = Config.repo()
    max_items = Config.staging()[:max_items] || @default_max_items

    staged_count =
      repo.aggregate(
        from(s in Staging, where: s.scope_id == ^scope_id and s.status == "staged"),
        :count
      )

    if staged_count >= max_items do
      {:error, :staging_backlog_full}
    else
      %Staging{}
      |> Staging.changeset(%{
        owner_id: owner_id,
        scope_id: scope_id,
        content: content,
        metadata: Keyword.get(opts, :metadata, %{}),
        source: Keyword.get(opts, :source),
        priority: Keyword.get(opts, :priority, 0.5),
        status: "staged",
        inserted_at: DateTime.utc_now()
      })
      |> repo.insert()
    end
  end

  @doc """
  Read staged rows for a scope without claiming them — the dry-run view
  of `drain/2`.
  """
  def staged(scope_id, opts \\ []) do
    scope_id = Util.uuid_to_string(scope_id)
    limit = Keyword.get(opts, :limit, 500)

    {:ok,
     Config.repo().all(
       from(s in Staging,
         where: s.scope_id == ^scope_id and s.status == "staged",
         order_by: [asc: s.inserted_at],
         limit: ^limit
       )
     )}
  end

  @doc """
  Atomically claim up to `:limit` (default 100) staged rows for a scope:
  they flip to `status: "drained"` with `drained_at` set inside one
  transaction, so concurrent distillers claim disjoint sets.
  """
  def drain(scope_id, opts \\ []) do
    scope_id = Util.uuid_to_string(scope_id)
    limit = Keyword.get(opts, :limit, 100)
    repo = Config.repo()

    Telemetry.span([:recollect, :staging, :drain], %{scope_id: scope_id}, fn ->
      {:ok, claim(repo, scope_id, limit)}
    end)
  end

  defp claim(repo, scope_id, limit) do
    fn ->
      query =
        from(s in Staging,
          where: s.scope_id == ^scope_id and s.status == "staged",
          order_by: [asc: s.inserted_at],
          limit: ^limit
        )

      # Postgres: SKIP LOCKED makes concurrent distillers disjoint.
      # SQLite/libSQL: the repo transaction serializes them.
      query =
        if Config.adapter().dialect() == :postgres do
          lock(query, "FOR UPDATE SKIP LOCKED")
        else
          query
        end

      rows = repo.all(query)

      if rows != [] do
        now = DateTime.utc_now()

        repo.update_all(
          from(s in Staging, where: s.id in ^Enum.map(rows, & &1.id)),
          set: [status: "drained", drained_at: now]
        )
      end

      rows
    end
    |> repo.transaction()
    |> case do
      {:ok, rows} -> rows
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Put drained rows back to `staged` (drained_at cleared) for retry — used
  by `Sleep.promote/1` with `from_staging: true` when a promotion fails.
  """
  def restage(ids) when is_list(ids) do
    ids = Enum.map(ids, &Util.uuid_to_string/1)
    repo = Config.repo()

    {count, _} =
      repo.update_all(
        from(s in Staging, where: s.id in ^ids and s.status == "drained"),
        set: [status: "staged", drained_at: nil]
      )

    {:ok, %{restaged: count}}
  end

  @doc """
  Retention GC: delete drained rows older than `staging.retention_days`
  (default 7). Staged rows are never pruned.
  """
  def prune(opts \\ []) do
    repo = Config.repo()
    retention_days = Keyword.get(opts, :retention_days) || Config.staging()[:retention_days] || @default_retention_days
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    {count, _} =
      repo.delete_all(
        from(s in Staging,
          where: s.status == "drained" and not is_nil(s.drained_at) and s.drained_at < ^cutoff
        )
      )

    {:ok, %{pruned: count}}
  end
end
