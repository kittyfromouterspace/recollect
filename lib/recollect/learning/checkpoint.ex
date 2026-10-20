defmodule Recollect.Learner.Checkpoint do
  @moduledoc """
  Behaviour for per-user-per-machine incremental-harvest cursors.

  `node_id/0` identifies this machine + OS user (e.g. `"lenz@taschenbuch"`) —
  checkpoints are scoped to it, so one laptop advancing its cursor never hides
  another laptop's unimported sessions. `since_map/1` produces the `:since`
  filter `Recollect.Learner.CodingAgent.fetch_authorized_events/2` expects
  (`%{agent_name => %{project_key => iso8601}}`); `record/3` advances the
  cursors after a successful harvest.

  Two implementations exist: `Recollect.Learner.Checkpoint.File` (DB-less,
  ships here) and `OpsCenter.Agent.Memory.Checkpoint` (DB-backed, fleet side).

  Consolidated in B-2163 from kfos_teamkit's JSON-file checkpoint and
  ops_center's DB-backed one.
  """

  @doc "The `:since` map for a node: `%{agent_name => %{project_key => iso8601}}`."
  @callback since_map(node_id :: String.t()) :: %{String.t() => %{String.t() => String.t()}}

  @doc """
  Advance the node's cursors for a harvested `mapping`
  (`%{agent_name => [project_key]}`) to `timestamp`.
  """
  @callback record(node_id :: String.t(), mapping :: map(), timestamp :: DateTime.t()) ::
              :ok | {:error, term()}

  @doc "Stable identity for this machine + OS user, e.g. `\"lenz@taschenbuch\"`."
  def node_id do
    user = System.get_env("USER") || System.get_env("USERNAME") || "unknown"

    host =
      case :inet.gethostname() do
        {:ok, h} -> List.to_string(h)
        _ -> "unknown-host"
      end

    "#{user}@#{host}"
  end
end
