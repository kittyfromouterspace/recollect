defmodule Recollect.Learner.CodingAgent do
  @moduledoc """
  Unified learner for all coding agents (Claude Code, Codex, Gemini CLI, Goose, OpenCode).

  Each agent has a **provider module** under `Recollect.Learner.CodingAgent.*`
  that knows how to read that agent's specific directory layout. This module
  implements the `Recollect.Learner` behaviour, dispatches to all enabled
  providers, and aggregates results.

  ## Adding a new agent

  1. Create `lib/recollect/learning/coding_agent/my_agent.ex`
  2. Implement the provider callbacks (see `Recollect.Learner.CodingAgent.Provider`)
  3. Add the module to `@providers` below

  ## Provider registry

  | Agent       | Module                          | Default data dir(s)                   |
  |-------------|---------------------------------|---------------------------------------|
  | Claude Code | `CodingAgent.ClaudeCode`        | `~/.claude/projects/`                 |
  | Codex       | `CodingAgent.Codex`             | `~/.codex/`                           |
  | Gemini CLI  | `CodingAgent.Gemini`            | `~/.gemini/`                          |
  | OpenCode    | `CodingAgent.OpenCode`          | `~/.local/share/opencode/`            |
  | Goose       | `CodingAgent.Goose`             | `~/.config/goose/`                    |

  Data paths can be overridden by passing an `:agent_configs` map
  (keyed by agent name) through the opts. This allows the caller
  (e.g. Worth) to inject paths from a central registry (e.g. AgentEx)
  without creating a circular dependency.
  """

  @behaviour Recollect.Learner

  alias Recollect.Telemetry

  @providers [
    Recollect.Learner.CodingAgent.ClaudeCode,
    Recollect.Learner.CodingAgent.Codex,
    Recollect.Learner.CodingAgent.Gemini,
    Recollect.Learner.CodingAgent.OpenCode
  ]

  @impl true
  def source, do: :coding_agents

  @impl true
  def fetch_since(_since, scope_id) do
    start_time = System.monotonic_time()

    events =
      provider_configs()
      |> Enum.filter(fn {mod, config} -> mod.available?(config) end)
      |> Enum.flat_map(fn {mod, config} -> mod.fetch_events(config) end)

    duration =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    Telemetry.event(
      [:recollect, :learn, :coding_agents, :fetch, :stop],
      %{duration_ms: duration, events_found: length(events)},
      %{scope_id: scope_id}
    )

    {:ok, events}
  end

  @impl true
  def extract(event) do
    provider = provider_for(event.agent)

    if provider do
      provider.extract(event)
    else
      {:skip, "unknown agent: #{event.agent}"}
    end
  end

  @impl true
  def detect_patterns(_events), do: []

  @impl true
  def summarize(events, scope_id) do
    events
    |> Enum.group_by(& &1.agent)
    |> Enum.flat_map(fn {agent, agent_events} ->
      provider = provider_for(agent)

      if provider && function_exported?(provider, :summarize, 2) do
        provider.summarize(agent_events, scope_id)
      else
        default_summarize(agent, agent_events)
      end
    end)
  end

  @doc "Run the full coding agent learning pipeline."
  def run(opts \\ []) do
    scope_id = Keyword.get(opts, :scope_id)

    with {:ok, events} <- fetch_since("1970-01-01", scope_id) do
      results = Enum.map(events, &process_event(&1, scope_id))

      learned = Enum.count(results, &match?({:ok, _}, &1))
      skipped = Enum.count(results, &match?({:skip, _}, &1))

      {:ok,
       %{
         fetched: length(events),
         learned: learned,
         skipped: skipped
       }}
    end
  end

  @doc "List available providers and their status."
  def status(overrides \\ %{}) do
    Enum.map(provider_configs(overrides), fn {mod, config} ->
      {mod.agent_name(), mod.available?(config), config.data_paths}
    end)
  end

  @doc "Get the list of provider modules."
  def providers, do: @providers

  @doc """
  Build `[{module, config}]` tuples for all providers.

  `overrides` is a map of `%{agent_name => %{data_paths: [...]}}`.
  Providers not in the overrides map use their `default_data_paths/0`.
  """
  def provider_configs(overrides \\ %{}) do
    Enum.map(@providers, fn mod ->
      name = mod.agent_name()
      override = Map.get(overrides, name, %{})
      paths = Map.get(override, :data_paths, mod.default_data_paths())
      {mod, %{data_paths: paths}}
    end)
  end

  @doc """
  Fetch events only from providers that pass the given filter.

  `filter_fn` receives the provider module and returns `true` to include it.
  Used by Worth to gate providers behind user permission checks.
  """
  def fetch_authorized_events(filter_fn) when is_function(filter_fn, 1) do
    {:ok, _} = fetch_authorized_events(filter_fn, projects: nil, since: nil)
  end

  @doc """
  Fetch events from authorized providers with optional project and time filtering.

  ## Options

  - `:projects` — map of `%{agent_name => [project_slug, ...]}` to filter by.
    If a provider has no entry, all its projects are included.
  - `:since` — map of `%{agent_name => %{project_slug => timestamp_string, ...}}`
    to only fetch events newer than the given timestamps.
  - `:agent_configs` — map of `%{agent_name => %{data_paths: [...]}}` to override
    default data paths. Injected by Worth from agent_ex's central registry.
  """
  def fetch_authorized_events(filter_fn, opts) when is_function(filter_fn, 1) and is_list(opts) do
    start_time = System.monotonic_time()
    projects = Keyword.get(opts, :projects)
    since = Keyword.get(opts, :since)
    agent_configs = Keyword.get(opts, :agent_configs, %{})

    events =
      agent_configs
      |> provider_configs()
      |> Enum.filter(fn {provider, config} ->
        provider.available?(config) and filter_fn.(provider)
      end)
      |> Enum.flat_map(fn {provider, config} ->
        agent = provider.agent_name()
        provider_projects = if projects, do: Map.get(projects, agent)
        provider_since = if since, do: Map.get(since, to_string(agent), %{})

        provider_opts = []

        provider_opts =
          if provider_projects, do: Keyword.put(provider_opts, :projects, provider_projects), else: provider_opts

        provider_opts =
          if provider_since && map_size(provider_since) > 0,
            do: Keyword.put(provider_opts, :since, provider_since),
            else: provider_opts

        provider.fetch_events(config, provider_opts)
      end)

    duration =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    Telemetry.event(
      [:recollect, :learn, :coding_agents, :fetch, :stop],
      %{duration_ms: duration, events_found: length(events)},
      %{scope_id: nil, authorized_only: true}
    )

    {:ok, events}
  end

  defp provider_for(agent) when is_atom(agent) do
    Enum.find(@providers, &(&1.agent_name() == agent))
  end

  defp default_summarize(agent, events) do
    by_project = Enum.group_by(events, &Map.get(&1, :project, "unknown"))

    Enum.flat_map(by_project, fn {project, project_events} ->
      count = length(project_events)

      if count < 2 do
        []
      else
        [
          %{
            content: "#{agent} activity in #{project}: #{count} events",
            entry_type: :development_insight,
            emotional_valence: :neutral,
            tags: [to_string(agent), "session_activity", "project:#{project}"],
            metadata: %{
              source: :coding_agents,
              agent: agent,
              insight_type: :agent_session_activity,
              project: project,
              event_count: count
            },
            half_life_days: 21.0,
            confidence: 0.7,
            summary: "#{project}: #{count} #{agent} events"
          }
        ]
      end
    end)
  end

  defp process_event(event, _scope_id) do
    case extract(event) do
      {:ok, extract} ->
        Recollect.remember(extract.content,
          entry_type: extract.entry_type,
          emotional_valence: extract.emotional_valence,
          tags: extract.tags,
          metadata: extract.metadata,
          source: "system"
        )

      {:skip, _} = skip ->
        skip
    end
  end
end
