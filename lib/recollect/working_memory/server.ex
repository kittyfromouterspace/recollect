defmodule Recollect.WorkingMemory.Server do
  @moduledoc """
  GenServer holding a bounded working memory buffer for a single scope.

  State: %{scope_id: binary(), entries: [%{id, importance, content, metadata, inserted_at}], max: pos_integer()}
  """

  use GenServer

  @default_max 20

  def start_link(opts) do
    scope_id = Keyword.fetch!(opts, :scope_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(scope_id))
  end

  @impl true
  def init(opts) do
    max = Keyword.get(opts, :max_entries, @default_max)
    {:ok, %{scope_id: opts[:scope_id], entries: [], max: max}}
  end

  @doc "Push a new entry into the working memory buffer."
  def push(pid, content, opts \\ []) do
    GenServer.call(pid, {:push, content, opts})
  end

  @doc "Read all entries, sorted by importance DESC."
  def read(pid, _opts \\ []) do
    GenServer.call(pid, :read)
  end

  @doc "Clear all entries from working memory."
  def clear(pid) do
    GenServer.call(pid, :clear)
  end

  @doc """
  Atomically swap out all entries: returns them sorted by importance and
  leaves the server running with an empty buffer (MEM-022). A push that
  lands after the drain is still in the buffer — nothing is lost to a
  read/clear race.
  """
  def drain(pid) do
    GenServer.call(pid, :drain)
  end

  @doc "Get the scope_id for this server."
  def scope_id(pid) do
    GenServer.call(pid, :scope_id)
  end

  @impl true
  def handle_call({:push, content, opts}, _from, state) do
    entry = %{
      id: generate_id(),
      importance: Keyword.get(opts, :importance, 0.0),
      content: content,
      metadata: Keyword.get(opts, :metadata, %{}),
      inserted_at: DateTime.utc_now()
    }

    entries = [entry | state.entries]

    entries =
      if length(entries) > state.max do
        entries
        |> Enum.sort_by(fn e -> {e.importance, e.inserted_at} end)
        |> Enum.drop(1)
      else
        entries
      end

    {:reply, {:ok, entry}, %{state | entries: entries}}
  end

  def handle_call(:read, _from, state) do
    sorted = Enum.sort_by(state.entries, fn e -> {-e.importance, e.inserted_at} end)
    {:reply, {:ok, sorted}, state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, length(state.entries), %{state | entries: []}}
  end

  # MEM-022: single atomic swap — the read and the clear can't interleave,
  # so promote() can never miss an entry or wipe one it didn't persist.
  def handle_call(:drain, _from, state) do
    sorted = Enum.sort_by(state.entries, fn e -> {-e.importance, e.inserted_at} end)
    {:reply, {:ok, sorted}, %{state | entries: []}}
  end

  def handle_call(:scope_id, _from, state) do
    {:reply, {:ok, state.scope_id}, state}
  end

  defp via_tuple(scope_id) do
    {:via, Registry, {Recollect.WorkingMemory.Registry, scope_id}}
  end

  defp generate_id do
    8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
