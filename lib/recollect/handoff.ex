defmodule Recollect.Handoff do
  @moduledoc """
  Session handoff for continuing work across sessions.

  Stores "what I was doing", "what's next", and "artifacts to continue with"
  so that when a session resumes, the context is immediately available.

  ## Usage

      # At end of session
      Recollect.Handoff.create(workspace_id,
        what: "Implementing user auth",
        next: ["Add login controller", "Create session middleware"],
        artifacts: ["lib/auth/user.ex", "lib/auth/token.ex"],
        blockers: ["Waiting on API spec"]
      )

      # At start of next session
      {:ok, handoff} = Recollect.Handoff.get(workspace_id)
  """

  import Ecto.Query

  alias Recollect.Config
  alias Recollect.Schema.Handoff, as: HandoffRow
  alias Recollect.Telemetry

  @doc """
  Create a handoff for a scope.

  ## Options
  - `:what` - What you were working on (required)
  - `:next` - List of next steps (optional)
  - `:artifacts` - Files/links to continue with (optional)
  - `:blockers` - What's blocking progress (optional)
  - `:session_id` - Current session ID (optional)
  """
  def create(scope_id, opts \\ []) do
    what = Keyword.fetch!(opts, :what)
    next = Keyword.get(opts, :next, [])
    artifacts = Keyword.get(opts, :artifacts, [])
    blockers = Keyword.get(opts, :blockers, [])
    session_id = Keyword.get(opts, :session_id)

    repo = Config.repo()
    now = DateTime.utc_now()

    # Telemetry.span returns the fun's result verbatim — return the query
    # result directly (wrapping it in a tuple leaks the wrapper to callers).
    Telemetry.span(
      [:recollect, :handoff, :create],
      %{scope_id: scope_id, next_count: length(next), artifacts_count: length(artifacts)},
      fn ->
        # The list columns are JSON-encoded text — the on-disk contract is
        # unchanged from the raw-SQL days.
        %HandoffRow{}
        |> Ecto.Changeset.change(%{
          scope_id: scope_id,
          session_id: session_id,
          what: what,
          next: Jason.encode!(next),
          artifacts: Jason.encode!(artifacts),
          blockers: Jason.encode!(blockers),
          created_at: now,
          updated_at: now
        })
        |> repo.insert()
      end
    )
  end

  @doc """
  Get the most recent handoff for a scope.
  """
  def get(scope_id) do
    repo = Config.repo()

    Telemetry.span([:recollect, :handoff, :get], %{scope_id: scope_id}, fn ->
      case repo.one(
             from(h in HandoffRow,
               where: h.scope_id == ^scope_id,
               order_by: [desc: h.created_at],
               limit: 1
             )
           ) do
        nil ->
          {:ok, nil}

        row ->
          {:ok, to_handoff(row)}
      end
    end)
  end

  @doc """
  Get handoffs since a date.
  """
  def recent(scope_id, since \\ ~D[2024-01-01]) do
    repo = Config.repo()

    rows =
      repo.all(
        from(h in HandoffRow,
          where: h.scope_id == ^scope_id and h.created_at >= ^since,
          order_by: [desc: h.created_at]
        )
      )

    {:ok, Enum.map(rows, &to_handoff/1)}
  end

  @doc """
  Delete old handoffs, keeping only the most recent N.
  """
  def cleanup(scope_id, keep: keep_count) do
    repo = Config.repo()

    keep_ids =
      from(h in HandoffRow,
        where: h.scope_id == ^scope_id,
        order_by: [desc: h.created_at],
        limit: ^keep_count,
        select: h.id
      )

    {deleted, _} =
      repo.delete_all(
        from(h in HandoffRow,
          where: h.scope_id == ^scope_id and h.id not in subquery(keep_ids)
        )
      )

    {:ok, %{deleted: deleted}}
  end

  # Private

  defp to_handoff(row) do
    %{
      id: row.id,
      what: row.what,
      next: decode_json_or_list(row.next, []),
      artifacts: decode_json_or_list(row.artifacts, []),
      blockers: decode_json_or_list(row.blockers, []),
      session_id: Map.get(row, :session_id),
      created_at: row.created_at
    }
  end

  defp decode_json_or_list(nil, default), do: default
  defp decode_json_or_list("", _default), do: []

  defp decode_json_or_list(json, default) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> default
    end
  end

  defp decode_json_or_list(other, default), do: other || default
end
