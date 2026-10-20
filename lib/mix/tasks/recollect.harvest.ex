defmodule Mix.Tasks.Recollect.Harvest do
  @shortdoc "Harvest local coding-agent sessions into project memory (dry-run/jsonl/mcp)"

  @moduledoc """
  DB-less harvest runner, available in any checkout that has the recollect
  dep. Reads this machine's coding-agent transcripts via
  `Recollect.Learner.Harvest` and hands the extracted notes to a sink:

      mix recollect.harvest --project mark_mesh                      # preview (dry-run)
      mix recollect.harvest --project mark_mesh --sink jsonl --out memories.jsonl
      OPS_CENTER_API_KEY=sk-… mix recollect.harvest --project mark_mesh --sink mcp

  The MCP sink pushes each note to the memory server's `stage_memory` tool
  (default https://ops-center.kfos.nz/mcp), whose scheduled sleep distills
  them into permanent project memory. The JSONL sink writes a transport file
  for server-side import. Host apps with a store (ops_center, home) ship their
  own tasks with store sinks on top of the same pipeline.

  ## Options

    * `--project SLUG` — harvest only sessions whose name matches the slug
    * `--all-sessions` / `--match STR` — bypass the slug mapping
    * `--agent NAME` — only this agent (claude_code | codex | opencode | gemini)
    * `--full` — ignore the incremental checkpoint
    * `--limit N` — cap extracted notes
    * `--sink dry-run|jsonl|mcp` (default dry-run)
    * `--out FILE` — JSONL output file (implies `--sink jsonl`)
    * `--url URL` / `--api-key KEY` — MCP sink endpoint/auth
      (env: OPS_CENTER_MCP_URL, OPS_CENTER_API_KEY / KFOS_API_KEY)
    * `--no-consent` — skip the per-agent consent gate (not recommended)

  Consent management (terminal/stored, per user per machine):

    * `--consent-status` — show the consent state of every known agent
    * `--grant AGENT` / `--deny AGENT` — set consent, then exit
  """

  use Mix.Task

  alias Recollect.Learner.Consent
  alias Recollect.Learner.Harvest

  @switches [
    project: :string,
    agent: :string,
    match: :string,
    all_sessions: :boolean,
    full: :boolean,
    limit: :integer,
    sink: :string,
    out: :string,
    url: :string,
    api_key: :string,
    consent: :boolean,
    grant: :string,
    deny: :string,
    consent_status: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: @switches)
    {:ok, _} = Application.ensure_all_started(:req)

    cond do
      opts[:grant] -> set_consent(opts[:grant], :grant)
      opts[:deny] -> set_consent(opts[:deny], :deny)
      opts[:consent_status] -> print_consent_status()
      true -> harvest(opts)
    end
  end

  defp harvest(opts) do
    if !(opts[:project] or opts[:all_sessions] or opts[:match]) do
      Mix.raise("--project SLUG is required (or pass --all-sessions / --match STR)")
    end

    sink = sink_for(opts)

    result =
      Harvest.run(
        project: opts[:project],
        agents: agent_opt(opts[:agent]),
        match: opts[:match],
        all_sessions: opts[:all_sessions] || false,
        full: opts[:full] || false,
        limit: opts[:limit],
        sink: sink,
        consent: if(Keyword.get(opts, :consent, true), do: :enforce, else: :off),
        log: &IO.puts/1
      )

    IO.puts(
      "\nproject=#{opts[:project] || "(all)"} sink=#{describe_sink(sink)} " <>
        "records=#{result.count} sink_result=#{inspect(result.sink_result)}"
    )
  end

  defp agent_opt(nil), do: :all
  defp agent_opt(name), do: String.to_atom(name)

  defp sink_for(opts) do
    case opts[:sink] || if(opts[:out], do: "jsonl", else: "dry-run") do
      "dry-run" ->
        :dry_run

      "jsonl" ->
        path = opts[:out] || Mix.raise("--sink jsonl needs --out FILE")
        {Recollect.Learner.Harvest.Sink.Jsonl, [path: path]}

      "mcp" ->
        mcp_opts = [project: opts[:project], url: opts[:url], api_key: opts[:api_key]]

        if !opts[:project] do
          Mix.raise("--sink mcp needs --project SLUG (the target scope)")
        end

        {Recollect.Learner.Harvest.Sink.Mcp, mcp_opts}

      other ->
        Mix.raise("unknown --sink #{other} (dry-run | jsonl | mcp)")
    end
  end

  defp describe_sink(:dry_run), do: "dry-run"
  defp describe_sink({mod, _opts}), do: inspect(mod)
  defp describe_sink(other), do: inspect(other)

  defp set_consent(agent, action) do
    agent = String.to_atom(agent)

    if agent in Consent.agents() do
      apply(Consent, action, [agent])
      IO.puts("#{action}ed #{agent} (stored in #{Consent.path()})")
    else
      Mix.raise("unknown agent #{agent} — known: #{Enum.map_join(Consent.agents(), ", ", &to_string/1)}")
    end
  end

  defp print_consent_status do
    for %{agent: agent, status: status} <- Consent.statuses() do
      IO.puts("  #{agent}: #{status}")
    end

    IO.puts("(stored in #{Consent.path()})")
  end
end
