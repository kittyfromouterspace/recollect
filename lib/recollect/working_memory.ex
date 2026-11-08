defmodule Recollect.WorkingMemory do
  @moduledoc """
  Working memory layer (Tier 0). **Deprecated — removal scheduled for 1.0.**

  A bounded buffer for current-session notes, separate from long-term
  knowledge. Session-scoped, no embeddings, importance-based eviction.

  Implemented as a GenServer per scope via DynamicSupervisor.

  **Ephemeral and not replicated:** the buffer lives in one node's RAM and
  dies with it. For anything that must survive a restart or work across a
  fleet, use `Recollect.Staging` (MEM-040) — the durable staging tier this
  module is superseded by. Every public function here emits a deprecation
  warning; hosts should move to `Staging.stage/3` + `Staging.drain/2` (or
  `Sleep.promote(from_staging: true)`).
  """

  alias Recollect.WorkingMemory.Server

  @default_max 20
  @deprecated_key :recollect_working_memory_deprecation_logged

  defp warn_deprecated do
    if :persistent_term.get(@deprecated_key, false) do
      :ok
    else
      require Logger

      Logger.warning(
        "Recollect.WorkingMemory is deprecated (ephemeral, not replicated) — " <>
          "use Recollect.Staging instead; removal scheduled for 1.0"
      )

      :persistent_term.put(@deprecated_key, true)
      :ok
    end
  end

  @doc """
  Push a new entry into working memory for a scope.

  Starts the scope GenServer if not running. If the scope exceeds
  max entries, the lowest-importance entry is evicted.

  ## Options
  - `:importance` - Float 0.0-1.0, default 0.0
  - `:metadata` - Map, default %{}
  """
  def push(scope_id, content, opts \\ []) do
    warn_deprecated()
    pid = ensure_scope(scope_id)
    Server.push(pid, content, opts)
  end

  @doc """
  Read working memory entries for a scope, sorted by importance DESC.
  """
  def read(scope_id, opts \\ []) do
    warn_deprecated()

    case whereis_scope(scope_id) do
      nil -> {:ok, []}
      pid -> Server.read(pid, opts)
    end
  end

  @doc """
  Clear working memory for a scope and terminate the GenServer.
  """
  def clear(scope_id) do
    warn_deprecated()

    case whereis_scope(scope_id) do
      nil ->
        {:ok, 0}

      pid ->
        count = Server.clear(pid)
        DynamicSupervisor.terminate_child(working_memory_supervisor(), pid)
        {:ok, count}
    end
  end

  @doc """
  Atomically drain the scope's buffer: returns the entries (importance
  DESC) and empties it without killing the server, so pushes concurrent
  with a drain land safely in the fresh buffer. Used by `Sleep.promote/1`
  (MEM-022) instead of the read/clear pair.
  """
  def drain(scope_id) do
    case whereis_scope(scope_id) do
      nil -> {:ok, []}
      pid -> Server.drain(pid)
    end
  end

  @doc "Semantic alias for clear, used at session boundaries."
  def flush(scope_id) do
    warn_deprecated()
    clear(scope_id)
  end

  @doc """
  Load handoff into working memory on session resume.

  Pushes handoff items as working-memory entries so the session can
  immediately continue from where it left off.

  MEM-022: bounded and de-prioritized — at most
  `brief.max_items_per_section` items (default 5), all at importance
  LOWER than live session notes, so a large handoff can never evict the
  session's own notes from the 20-slot buffer.
  """
  def load_handoff(scope_id) do
    alias Recollect.Telemetry

    warn_deprecated()
    max_items = Recollect.Config.brief()[:max_items_per_section] || 5

    case Recollect.Handoff.get(scope_id) do
      {:ok, handoff} when not is_nil(handoff) ->
        items =
          [
            {"Handoff: #{handoff.what}", 0.6}
          ]
          |> Enum.concat(Enum.map(handoff.next, &{"Next: #{&1}", 0.5}))
          |> Enum.concat(Enum.map(handoff.artifacts, &{"Artifact: #{&1}", 0.4}))
          |> Enum.take(max_items)

        Enum.each(items, fn {content, importance} ->
          push(scope_id, content, importance: importance)
        end)

        pushed = length(items)

        Telemetry.event(
          [:recollect, :handoff, :load, :stop],
          %{pushed: pushed, next_count: length(handoff.next), artifacts_count: length(handoff.artifacts)},
          %{scope_id: scope_id}
        )

        {:ok,
         %{
           what: handoff.what,
           next_count: length(handoff.next),
           artifacts_count: length(handoff.artifacts),
           pushed: pushed
         }}

      _ ->
        {:ok, nil}
    end
  end

  @doc "List all active scope IDs."
  def active_scopes do
    working_memory_supervisor()
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} ->
      case Server.scope_id(pid) do
        {:ok, scope_id} -> scope_id
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp ensure_scope(scope_id) do
    case whereis_scope(scope_id) do
      nil -> start_scope(scope_id)
      pid -> pid
    end
  end

  defp start_scope(scope_id) do
    max =
      :recollect
      |> Application.get_env(:working_memory, [])
      |> Keyword.get(:max_entries_per_scope, @default_max)

    child_spec = {Server, scope_id: scope_id, max_entries: max}

    case DynamicSupervisor.start_child(working_memory_supervisor(), child_spec) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp whereis_scope(scope_id) do
    working_memory_registry()
    |> Registry.lookup(scope_id)
    |> case do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp working_memory_supervisor, do: Recollect.WorkingMemory.Supervisor
  defp working_memory_registry, do: Recollect.WorkingMemory.Registry
end
