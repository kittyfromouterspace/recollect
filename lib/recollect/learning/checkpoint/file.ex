defmodule Recollect.Learner.Checkpoint.File do
  @moduledoc """
  JSON-file checkpoint store for DB-less harvest runs (laptops, escripts).

  Lives under the current user's home (`~/.config/recollect/checkpoints.json`;
  `RECOLLECT_HOME` overrides the directory, e.g. in tests), so the cursor is
  inherently per user per machine. Shape:

      %{
        "lenz@taschenbuch" => %{
          "claude_code" => %{"-home-lenz-code-mark_mesh" => "2026-10-20T10:00:00Z"}
        }
      }
  """

  @behaviour Recollect.Learner.Checkpoint

  @doc "Path to the checkpoint file (override the directory with RECOLLECT_HOME)."
  def path do
    home = System.get_env("RECOLLECT_HOME") || Path.join(System.user_home!() || ".", ".config/recollect")
    Path.join(home, "checkpoints.json")
  end

  @impl true
  def since_map(node_id) do
    case Map.get(load(), node_id) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  @impl true
  def record(node_id, mapping, %DateTime{} = timestamp) when is_map(mapping) do
    iso = DateTime.to_iso8601(timestamp)

    node =
      Enum.reduce(mapping, Map.get(load(), node_id, %{}), fn {agent, keys}, acc ->
        agent_map = Map.get(acc, to_string(agent), %{})

        Map.put(
          acc,
          to_string(agent),
          Enum.reduce(keys, agent_map, fn key, m -> Map.put(m, to_string(key), iso) end)
        )
      end)

    load()
    |> Map.put(node_id, node)
    |> save()
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
