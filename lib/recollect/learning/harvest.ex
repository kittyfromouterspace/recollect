defmodule Recollect.Learner.Harvest do
  @moduledoc """
  Shared harvest pipeline: read this machine's coding-agent sessions, keep the
  ones relevant to a project, extract raw notes, and hand them to a sink.

  Consolidated in B-2163 from three drifting copies: ops_center's
  `mix ops_center.memory.harvest` (B-244/B-245), home's
  `Home.Memory.Importer`, and kfos_teamkit's `mix kfos.memory.harvest`.

  Pipeline: `Recollect.Learner.ProjectMapping` resolves which agent project
  keys belong to the slug → `Recollect.Learner.CodingAgent.fetch_authorized_events/2`
  fetches them (consent-gated, project- and since-filtered) →
  `CodingAgent.extract/1` turns events into records → a sink consumes them.

  ## Record shape

  Each record is `%{project, agent, source, content, tags, metadata, entry_type}`
  where `project` is the *origin* agent project key (e.g.
  `-home-lenz-code-mark_mesh`) — the sink decides the target scope.

  ## Sinks

    * `:collect` (default) — return the records, hand them nowhere
    * `:dry_run` — log each record via `:log`; implies a full preview (no
      checkpoint read, no checkpoint write)
    * `{Recollect.Learner.Harvest.Sink.Jsonl, path: "..."}`
    * `{Recollect.Learner.Harvest.Sink.Mcp, url: ..., api_key: ..., project: ...}`
    * any module implementing `Recollect.Learner.Harvest.Sink` (e.g.
      ops_center's stage+sleep store sink, home's distill+store sink)

  ## Options

    * `:project` — slug to harvest (required unless `:all_sessions` or `:match`)
    * `:agents` — `:all` (default), one agent name atom, or a list of them
    * `:match` — only sessions whose project key contains this string
      (bypasses the slug mapping)
    * `:all_sessions` — import every discovered session (bypasses the mapping)
    * `:full` — ignore the incremental checkpoint
    * `:since` — explicit since map (overrides the checkpoint read)
    * `:checkpoint` — a `Recollect.Learner.Checkpoint` implementation
      (default `Recollect.Learner.Checkpoint.File`)
    * `:record` — set to `false` to never advance cursors
    * `:consent` — `:enforce` (default: only consented agents are read, per
      `Recollect.Learner.Consent`) or `:off`
    * `:limit` — cap extracted records
    * `:agent_configs` — provider data-path overrides (see
      `CodingAgent.provider_configs/1`; used in tests)
    * `:node_id` — originating machine identity (default `Checkpoint.node_id/0`)
    * `:log` — `fn binary -> any` progress logger (default: silent)

  Returns a summary map with `:records`, `:matched` (the slug-matched
  `%{agent => [key]}`, for cursor bookkeeping), `:count`, and `:sink_result`.
  """

  alias Recollect.Learner.Checkpoint
  alias Recollect.Learner.CodingAgent
  alias Recollect.Learner.Consent
  alias Recollect.Learner.ProjectMapping

  @signal_words ~w(because decision decided fix fixed trap gotcha never always must avoid root cause lesson)

  @type record :: %{
          project: String.t() | nil,
          agent: atom(),
          source: atom() | nil,
          content: String.t(),
          tags: [String.t()],
          metadata: map(),
          entry_type: atom() | String.t()
        }

  @doc "Run a harvest pass. See the moduledoc for the option list."
  def run(opts) do
    log = Keyword.get(opts, :log, fn _ -> :ok end)
    node = opts[:node_id] || Checkpoint.node_id()
    checkpoint = Keyword.get(opts, :checkpoint, Checkpoint.File)
    dry_run? = opts[:sink] == :dry_run
    started_at = DateTime.utc_now()

    warn_unconsented(opts, log)

    {filter, matched} = resolve_filter(opts, log)
    since = resolve_since(opts, checkpoint, node, dry_run?)

    records =
      case filter do
        :none ->
          []

        projects ->
          {:ok, events} =
            CodingAgent.fetch_authorized_events(provider_filter(opts),
              projects: projects,
              since: since,
              agent_configs: Keyword.get(opts, :agent_configs, %{})
            )

          events
          |> filter_by_match(opts[:match])
          |> Enum.flat_map(&extract_record/1)
          |> maybe_limit(opts[:limit])
      end

    sink_result = push_sink(records, opts, log)
    maybe_advance(checkpoint, node, matched, records, sink_result, started_at, dry_run?, opts, log)

    %{
      project: opts[:project],
      node: node,
      records: records,
      matched: matched,
      count: length(records),
      sink_result: sink_result
    }
  end

  @doc """
  Cheap signal heuristic for staging buffers and heuristic distiller
  fallbacks: length plus durable-knowledge keywords. LLM distillers ignore it
  when credentials are configured.
  """
  def importance(content) do
    text = String.downcase(content)
    word_hits = Enum.count(@signal_words, &String.contains?(text, &1))
    length_score = min(String.length(content) / 400.0, 0.5)
    min(length_score + word_hits * 0.2, 1.0)
  end

  # nil ⇒ no project filter (all sessions). A map ⇒ per-agent allowed keys
  # (every discovered agent constrained; unmatched agents get [] so nothing
  # leaks in). :none ⇒ nothing matched and no override, so import nothing.
  defp resolve_filter(opts, log) do
    cond do
      opts[:all_sessions] ->
        {nil, nil}

      opts[:match] ->
        {nil, nil}

      project = opts[:project] ->
        discovered = ProjectMapping.discover(agent_configs: Keyword.get(opts, :agent_configs, %{}))
        relevant = ProjectMapping.relevant_agent_projects(project, discovered)

        if map_size(relevant) == 0 do
          log.(
            "no agent sessions matched project \"#{project}\" by name — " <>
              "pass --all-sessions or --match STR to import anyway"
          )

          {:none, nil}
        else
          for {agent, keys} <- relevant, do: log.("matched #{agent}: #{Enum.join(keys, ", ")}")

          # Constrain every discovered agent: matched keys, or [] (import nothing).
          full = Map.new(discovered, fn {agent, _keys} -> {agent, Map.get(relevant, agent, [])} end)
          {full, relevant}
        end

      true ->
        raise ArgumentError, "project is required unless :all_sessions or :match is given"
    end
  end

  defp resolve_since(opts, checkpoint, node, dry_run?) do
    cond do
      # dry-run always previews the full relevant set; it never reads the cursor.
      dry_run? or opts[:full] -> nil
      Keyword.has_key?(opts, :since) -> opts[:since]
      true -> checkpoint.since_map(node)
    end
  end

  defp provider_filter(opts) do
    consent? = Keyword.get(opts, :consent, :enforce) != :off

    agents =
      case Keyword.get(opts, :agents, :all) do
        :all -> nil
        name when is_atom(name) -> [name]
        names when is_list(names) -> names
      end

    fn provider ->
      name = provider.agent_name()
      (is_nil(agents) or name in agents) and (not consent? or Consent.granted?(name))
    end
  end

  defp warn_unconsented(opts, log) do
    if Keyword.get(opts, :consent, :enforce) != :off do
      requested =
        case Keyword.get(opts, :agents, :all) do
          :all -> Consent.agents()
          name when is_atom(name) -> [name]
          names when is_list(names) -> names
        end

      for agent <- requested, not Consent.granted?(agent) do
        log.("skipping #{agent}: no consent yet — grant with `mix recollect.harvest --grant #{agent}`")
      end
    end
  end

  defp filter_by_match(events, nil), do: events

  defp filter_by_match(events, match) do
    Enum.filter(events, fn event ->
      event |> Map.get(:project, "") |> to_string() |> String.contains?(match)
    end)
  end

  defp extract_record(event) do
    case CodingAgent.extract(event) do
      {:ok, extract} ->
        [
          %{
            project: Map.get(event, :project),
            agent: Map.get(event, :agent),
            source: Map.get(event, :source),
            content: extract.content,
            tags: Map.get(extract, :tags, []),
            metadata: Map.get(extract, :metadata, %{}),
            entry_type: Map.get(extract, :entry_type, :note)
          }
        ]

      {:skip, _reason} ->
        []
    end
  end

  defp maybe_limit(records, nil), do: records
  defp maybe_limit(records, n) when is_integer(n), do: Enum.take(records, n)

  defp push_sink(records, opts, log) do
    case Keyword.get(opts, :sink, :collect) do
      :collect ->
        {:ok, %{collected: length(records)}}

      :dry_run ->
        for record <- records do
          log.("• [#{record.agent}] #{record.content |> String.slice(0, 110) |> String.replace("\n", " ")}")
        end

        {:ok, %{previewed: length(records)}}

      {module, sink_opts} when is_atom(module) ->
        module.push(records, sink_opts)

      module when is_atom(module) ->
        module.push(records, [])
    end
  end

  # Advance this node’s cursors only after a clean, real (non-dry) slug-mapped
  # run that actually produced records — an empty/failed run must not hide
  # unimported sessions.
  defp maybe_advance(checkpoint, node, matched, records, sink_result, started_at, dry_run?, opts, log) do
    sink_ok? = match?({:ok, _}, sink_result) or sink_result == :ok

    if not dry_run? and Keyword.get(opts, :record, true) and is_map(matched) and
         map_size(matched) > 0 and records != [] and sink_ok? do
      :ok = checkpoint.record(node, matched, started_at)
      log.("checkpoint advanced for #{node}")
    end
  end
end
