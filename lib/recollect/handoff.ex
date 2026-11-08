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
  alias Recollect.Tokenizer

  @doc """
  Create a handoff for a scope.

  ## Options
  - `:what` - What you were working on (required)
  - `:next` - List of next steps (optional)
  - `:artifacts` - Files/links to continue with (optional)
  - `:blockers` - What's blocking progress (optional)
  - `:session_id` - Current session ID (optional)

  MEM-022: handoffs feed the brief, so they are budgeted. Strings are
  capped (with an explicit `…[truncated]` marker), lists at 10 items with
  an `[+N truncated]` marker, and if the total still exceeds
  `brief.token_budget` the tail items of blockers/artifacts/next are
  dropped (markers kept) until it fits. `what` is never dropped.
  """
  @token_budget_default 1_500
  @string_cap 300
  @list_cap 10
  @truncate_marker "…[truncated]"
  @list_marker "[+N truncated]"

  def create(scope_id, opts \\ []) do
    what = truncate_text(Keyword.fetch!(opts, :what))
    budget = Config.brief()[:token_budget] || @token_budget_default
    repo = Config.repo()

    lists =
      Map.new(
        %{
          next: Keyword.get(opts, :next, []),
          artifacts: Keyword.get(opts, :artifacts, []),
          blockers: Keyword.get(opts, :blockers, [])
        },
        fn {key, list} -> {key, cap_list(list)} end
      )

    {lists, overflowed} = fit_to_budget(what, lists, budget)

    now = DateTime.utc_now()

    Telemetry.span(
      [:recollect, :handoff, :create],
      %{
        scope_id: scope_id,
        next_count: length(lists.next),
        artifacts_count: length(lists.artifacts),
        truncated: overflowed
      },
      fn ->
        %HandoffRow{}
        |> Ecto.Changeset.change(%{
          scope_id: scope_id,
          session_id: Keyword.get(opts, :session_id),
          what: what,
          next: Jason.encode!(lists.next),
          artifacts: Jason.encode!(lists.artifacts),
          blockers: Jason.encode!(lists.blockers),
          created_at: now,
          updated_at: now
        })
        |> repo.insert()
      end
    )
  end

  defp cap_list(list) when is_list(list) do
    list
    |> Enum.take(@list_cap)
    |> Enum.map(&truncate_text/1)
    |> with_overflow_marker(length(list))
  end

  defp cap_list(_other), do: []

  defp with_overflow_marker(items, original) when length(items) < original do
    dropped = original - length(items)
    items ++ ["[+#{dropped} #{@list_marker}]"]
  end

  defp with_overflow_marker(items, _original), do: items

  defp truncate_text(text) when is_binary(text) do
    if String.length(text) > @string_cap do
      String.slice(text, 0, @string_cap) <> @truncate_marker
    else
      text
    end
  end

  defp truncate_text(other), do: other

  # Tail-trim blockers, then artifacts, then next (what never goes) until
  # the handoff fits `brief.token_budget`. Markers are added once after
  # trimming (re-adding per drop would fight the budget check).
  defp fit_to_budget(what, lists, budget) do
    {lists, trimmed} = trim_until_fit(what, lists, budget, [:blockers, :artifacts, :next], false)
    {maybe_mark(lists, trimmed), trimmed}
  end

  defp trim_until_fit(what, lists, budget, order, trimmed) do
    if over_budget?(what, lists, budget) and order != [] do
      [key | rest] = order
      items = lists[key]

      if length(items) > 1 do
        trim_until_fit(what, Map.put(lists, key, Enum.drop(items, -1)), budget, order, true)
      else
        # keep the last item so the truncation stays explicit
        trim_until_fit(what, lists, budget, rest, trimmed)
      end
    else
      {lists, trimmed}
    end
  end

  defp maybe_mark(lists, false), do: lists

  defp maybe_mark(lists, true) do
    Map.new(lists, fn {key, items} ->
      if items == [] do
        {key, items}
      else
        {key, List.replace_at(items, -1, "[handoff truncated to fit brief.token_budget]")}
      end
    end)
  end

  defp over_budget?(what, lists, budget) do
    parts = [what | Enum.flat_map(Map.values(lists), & &1)]
    Tokenizer.estimate(Enum.join(parts, "\n")) > budget
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
