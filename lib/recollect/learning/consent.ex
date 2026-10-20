defmodule Recollect.Learner.Consent do
  @moduledoc """
  Per-agent, per-user-per-machine consent for reading local coding-agent data.

  Harvesting reads `~/.claude`, `~/.codex` and friends — session transcripts
  that can hold sensitive context. Before a harvest reads an agent's data on
  this machine, the user must grant permission (modelled on Worth's
  `Worth.Learning.Permissions`; ported from kfos_teamkit's consent store in
  B-2163). Consent is opt-in: `:granted` allows reading; `:denied` and
  `:unasked` both skip.

  Stored as a local JSON blob under the user's home, so the grant is
  inherently per user per machine (a harvest is a CLI/scheduler run, not a
  live MCP session, so this is a terminal/stored consent — not MCP
  elicitation, which only applies to a live remember/stage path).

  Wire it into a fetch via `filter/1`:

      CodingAgent.fetch_authorized_events(Consent.filter(), projects: ...)
  """

  alias Recollect.Learner.CodingAgent

  @doc "Known agents the gate covers (every registered CodingAgent provider)."
  def agents, do: Enum.map(CodingAgent.providers(), & &1.agent_name())

  @doc "Consent file path (override the directory with RECOLLECT_HOME, e.g. in tests)."
  def path do
    home = System.get_env("RECOLLECT_HOME") || Path.join(System.user_home!() || ".", ".config/recollect")
    Path.join(home, "consent.json")
  end

  @doc "`:granted | :denied | :unasked` for an agent."
  def check(agent) do
    case Map.get(load(), to_string(agent)) do
      "granted" -> :granted
      "denied" -> :denied
      _ -> :unasked
    end
  end

  @doc "True only when the user explicitly granted this agent."
  def granted?(agent), do: check(agent) == :granted

  def grant(agent), do: set(agent, "granted")
  def deny(agent), do: set(agent, "denied")

  def set(agent, status) when status in ["granted", "denied"] do
    load() |> Map.put(to_string(agent), status) |> save()
  end

  @doc "Status of every covered agent: `[%{agent: atom, status: atom}]`."
  def statuses do
    Enum.map(agents(), fn a -> %{agent: a, status: check(a)} end)
  end

  @doc """
  A provider filter for `CodingAgent.fetch_authorized_events/2` that allows
  only granted agents. An optional second filter (a 1-arity provider
  predicate, e.g. an agent-name selector) is ANDed in.
  """
  def filter(extra \\ nil) do
    fn provider ->
      granted?(provider.agent_name()) and (is_nil(extra) or extra.(provider))
    end
  end

  defp load do
    with {:ok, body} <- File.read(path()),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  defp save(map) do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), Jason.encode!(map, pretty: true))
    :ok
  end
end
