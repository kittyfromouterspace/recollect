defmodule Recollect.Learner.ProjectMapping do
  @moduledoc """
  Maps coding-agent project keys to project slugs, in both directions.

  Each coding agent stores sessions under its own project key — Claude Code
  uses the checkout path with `/` → `-` (`-home-lenz-code-mark_mesh`),
  OpenCode uses a bare slug (`mark_mesh`), Codex records the session cwd.
  A harvest needs to answer two questions:

    * "which agent project keys belong to slug X?" — `relevant_agent_projects/2`,
      the fetch-time filter for `Recollect.Learner.CodingAgent.fetch_authorized_events/2`
    * "which project does agent key K belong to?" — `scope_for_key/2`, the
      store-time grouping, resolved against real checkouts on disk

  Consolidated in B-2163 from `OpsCenter.Agent.Memory.ProjectMapping` (itself
  adapted from Worth's `Worth.Learning.ProjectMapping`) and home's
  `Home.Memory.Importer.project_scope/1`, which previously drifted
  independently.
  """

  alias Recollect.Learner.CodingAgent

  @common_segments ~w(home code users tmp var opt usr src work projects repos)

  @doc """
  Discover the agent project keys present on this machine.

  Returns `%{agent_name => [project_key]}` for every available provider.
  Pass `:agent_configs` (see `Recollect.Learner.CodingAgent.provider_configs/1`)
  to override data paths, e.g. in tests.
  """
  def discover(opts \\ []) do
    opts
    |> Keyword.get(:agent_configs, %{})
    |> CodingAgent.provider_configs()
    |> Enum.filter(fn {mod, config} -> mod.available?(config) end)
    |> Enum.map(fn {mod, config} ->
      keys =
        config
        |> mod.fetch_events()
        |> Enum.map(&Map.get(&1, :project))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&to_string/1)
        |> Enum.uniq()
        |> Enum.sort()

      {mod.agent_name(), keys}
    end)
    |> Enum.reject(fn {_agent, keys} -> keys == [] end)
    |> Map.new()
  end

  @doc """
  The agent project keys relevant to a project slug.

  Returns `%{agent_name => [project_key]}` (only agents/keys that match),
  suitable as the `:projects` option to
  `Recollect.Learner.CodingAgent.fetch_authorized_events/2`. Pass a
  pre-computed `discovered` map to avoid re-scanning the filesystem
  (and for tests).
  """
  def relevant_agent_projects(project_slug, discovered \\ nil) do
    discovered = discovered || discover()

    discovered
    |> Enum.map(fn {agent, keys} ->
      {agent, Enum.filter(keys, &matches_slug?(project_slug, &1))}
    end)
    |> Enum.reject(fn {_agent, keys} -> keys == [] end)
    |> Map.new()
  end

  @doc """
  True when an agent project key plausibly belongs to a project slug.

  Word-level match after normalising separators and dropping common path
  segments — `mark_mesh` matches `-home-lenz-code-mark_mesh` and `mark-mesh`.
  """
  def matches_slug?(project_slug, agent_key) do
    slug_words = significant_words(project_slug)
    key_words = significant_words(agent_key)

    slug_words != [] and Enum.all?(slug_words, &(&1 in key_words))
  end

  @doc """
  Resolve an agent project key to a project name ("scope").

  Provider-specific encodings like `-home-lenz-code-ops-center` or
  `/home/lenz/code/ops_center` are matched against real checkouts under the
  code root (default `~/code`, override with `:code_root`): the shortest
  trailing suffix (dashes mapped to underscores, e.g. `["mark", "mesh"]` →
  `"mark_mesh"`) that names a real checkout directory wins. Falls back to the
  key's last segment; `nil`, `"unknown"`, and empty keys map to `"shared"`.
  """
  def scope_for_key(key, opts \\ [])

  def scope_for_key(key, _opts) when key in [nil, "", "unknown"], do: "shared"

  def scope_for_key(key, opts) when is_binary(key) do
    segments =
      key
      |> String.trim_leading("-")
      |> String.replace("-", "/")
      |> String.split("/", trim: true)

    resolve_project_name(segments, code_root(opts))
  end

  def scope_for_key(other, opts), do: scope_for_key(to_string(other), opts)

  defp code_root(opts), do: opts[:code_root] || Path.expand("~/code")

  defp resolve_project_name([], _root), do: "shared"
  defp resolve_project_name(["unknown"], _root), do: "shared"

  defp resolve_project_name(segments, root) do
    1..min(3, length(segments))
    |> Enum.map(fn n -> segments |> Enum.take(-n) |> Enum.join("_") end)
    |> Enum.find(fn candidate -> File.dir?(Path.join(root, candidate)) end)
    |> case do
      nil -> List.last(segments)
      name -> name
    end
  end

  defp significant_words(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[-_\.]/, " ")
    |> String.split()
    |> Enum.reject(&(&1 in @common_segments))
  end
end
