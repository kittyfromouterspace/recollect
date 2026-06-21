defmodule Recollect.Learner.CodingAgent.Codex do
  @moduledoc """
  Provider for OpenAI Codex CLI (`~/.codex/`).

  Reads session transcripts (JSONL with `rollout-*.jsonl` files organized
  by date), the user instructions file, and the project config.

  ## Directory layout

      ~/.codex/
      ├── sessions/
      │   └── YYYY/MM/DD/rollout-*.jsonl   # session transcripts
      ├── memories/                         # Codex memory files (if any)
      ├── instructions.md                   # global user instructions
      ├── config.toml                       # project trust levels
      └── history.jsonl                     # recent prompts index
  """

  @behaviour Recollect.Learner.CodingAgent.Provider

  import Recollect.Learner.CodingAgent.Util, only: [resolve_paths: 1]

  alias Recollect.Learner.CodingAgent.Util

  @impl true
  def agent_name, do: :codex

  @impl true
  def default_data_paths, do: ["~/.codex"]

  @impl true
  def available?(config \\ %{}) do
    case resolve_paths(config) do
      [] -> false
      [path | _] -> Util.dir_exists?(path)
    end
  end

  @impl true
  def fetch_events(config \\ %{}), do: fetch_events(config, [])

  @impl true
  def fetch_events(config, opts) do
    base = Util.expand(hd(resolve_paths(config)))

    instruction_events = fetch_instructions(base)
    session_events = fetch_sessions(base, opts)
    history_events = fetch_history(base)

    maybe_filter_projects(instruction_events ++ session_events ++ history_events, Keyword.get(opts, :projects))
  end

  # Honor the `:projects` filter (parity with the Claude Code provider). Codex
  # derives a session's project from its `cwd`, so this keeps only sessions whose
  # project is in the allow-list — and drops project-less events (global
  # instructions, `project: "unknown"` history prompts) that would otherwise be
  # mis-attributed to whatever project a caller is harvesting.
  defp maybe_filter_projects(events, nil), do: events

  defp maybe_filter_projects(events, projects) when is_list(projects) do
    allowed = MapSet.new(projects)
    Enum.filter(events, fn event -> Map.get(event, :project) in allowed end)
  end

  @impl true
  def extract(%{source: :instructions} = event), do: extract_instructions(event)
  def extract(%{source: :session} = event), do: extract_session(event)
  def extract(%{source: :history_prompt} = event), do: extract_history_prompt(event)
  def extract(_), do: {:skip, "unknown"}

  @impl true
  def summarize(events, _scope_id) do
    events
    |> Enum.filter(&(&1.source == :session or &1.source == :history_prompt))
    |> Enum.group_by(&Map.get(&1, :project, "unknown"))
    |> Enum.filter(fn {_project, evts} -> length(evts) >= 2 end)
    |> Enum.map(fn {project, evts} ->
      prompts = evts |> Enum.flat_map(&Map.get(&1, :user_prompts, [])) |> Enum.take(10)

      %{
        content:
          "Codex activity in #{project}: #{length(evts)} interactions\n\nTopics:\n#{Enum.map_join(prompts, "\n", &"  • #{&1}")}",
        entry_type: :development_insight,
        emotional_valence: :neutral,
        tags: ["codex", "session_activity", Util.project_tag(project)],
        metadata: %{source: :codex, insight_type: :session_activity, project: project, event_count: length(evts)},
        half_life_days: 21.0,
        confidence: 0.7,
        summary: "#{project}: #{length(evts)} Codex interactions"
      }
    end)
  end

  # --- extract ---

  defp extract_instructions(%{content: content}) do
    if content == "" do
      {:skip, "empty instructions"}
    else
      {:ok,
       %{
         content: "Codex user instructions:\n\n#{content}",
         entry_type: :decision,
         emotional_valence: :neutral,
         tags: ["codex", "instructions"],
         metadata: %{source: :codex},
         half_life_days: 30.0,
         confidence: 0.85,
         summary: "Codex global instructions"
       }}
    end
  end

  defp extract_session(%{user_prompts: []}), do: {:skip, "no user prompts"}

  defp extract_session(%{user_prompts: prompts, project: project, session_id: sid}) do
    {:ok,
     %{
       content: "Codex session #{Util.short_id(sid)} in #{project}: #{Enum.join(prompts, "\n• ")}",
       entry_type: :note,
       emotional_valence: :neutral,
       tags: ["codex", "session", Util.project_tag(project)],
       metadata: %{source: :codex, session_id: sid, project: project}
     }}
  end

  defp extract_history_prompt(%{text: text, project: project}) do
    {:ok,
     %{
       content: "Codex prompt: #{text}",
       entry_type: :note,
       emotional_valence: :neutral,
       tags: ["codex", "prompt", Util.project_tag(project)],
       metadata: %{source: :codex, project: project},
       summary: text
     }}
  end

  # --- fetching ---

  defp fetch_instructions(base) do
    path = Path.join(base, "instructions.md")

    with {:ok, content} <- Util.read_file(path, 5000),
         true <- String.trim(content) != "" do
      [%{agent: :codex, source: :instructions, content: content}]
    else
      _ -> []
    end
  end

  defp fetch_sessions(base, opts) do
    sessions_dir = Path.join(base, "sessions")

    if File.dir?(sessions_dir) do
      since = Keyword.get(opts, :since, %{})

      sessions_dir
      |> Path.join("**/*.jsonl")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        case since do
          s when is_map(s) and map_size(s) > 0 ->
            since_dt = s |> Map.values() |> Enum.sort() |> Enum.at(0)

            case since_dt && DateTime.from_iso8601(since_dt) do
              {:ok, dt, _} ->
                case File.stat(path) do
                  {:ok, stat} ->
                    file_dt = Util.mtime_to_datetime(stat.mtime)
                    DateTime.after?(file_dt, dt)

                  _ ->
                    true
                end

              _ ->
                true
            end

          _ ->
            true
        end
      end)
      |> Enum.take(20)
      |> Enum.map(&parse_codex_session/1)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp parse_codex_session(path) do
    with {:ok, content} <- File.read(path) do
      lines = Util.extract_jsonl_lines(content)

      cwd =
        Enum.find_value(lines, fn obj ->
          get_in(obj, ["payload", "cwd"]) ||
            get_in(obj, ["payload", "git", "branch"])
        end)

      project =
        case cwd do
          nil -> Path.basename(Path.dirname(path))
          dir -> Path.basename(dir)
        end

      session_id =
        path
        |> Path.basename(".jsonl")
        |> String.replace(~r/^rollout-/, "")
        |> String.replace(~r/^.*T/, "")

      user_prompts =
        lines
        |> Enum.filter(fn obj ->
          get_in(obj, ["type"]) == "response_item" and
            get_in(obj, ["payload", "role"]) == "user"
        end)
        |> Enum.flat_map(fn obj ->
          obj
          |> get_in(["payload", "content"])
          |> List.wrap()
          |> Enum.filter(&(is_map(&1) and &1["type"] == "input_text"))
          |> Enum.map(& &1["text"])
          |> Enum.reject(&String.starts_with?(&1, "<"))
          |> Enum.reject(&(&1 == ""))
        end)
        |> Enum.take(20)

      if user_prompts != [] do
        %{agent: :codex, source: :session, project: project, session_id: session_id, user_prompts: user_prompts}
      end
    end
  end

  defp fetch_history(base) do
    path = Path.join(base, "history.jsonl")

    case Util.read_file(path) do
      {:ok, content} ->
        content
        |> Util.extract_jsonl_lines()
        |> Enum.map(fn obj ->
          text = Map.get(obj, "text", "")
          session_id = Map.get(obj, "session_id", "unknown")

          if text != "" do
            %{
              agent: :codex,
              source: :history_prompt,
              text: text,
              session_id: session_id,
              project: "unknown",
              user_prompts: [text]
            }
          end
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end
end
