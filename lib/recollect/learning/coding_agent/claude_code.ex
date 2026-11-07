defmodule Recollect.Learner.CodingAgent.ClaudeCode do
  @moduledoc """
  Provider for Claude Code (`~/.claude/`).

  Reads curated memory files with YAML frontmatter, CLAUDE.md project
  instructions, and session JSONL transcripts.

  ## Directory layout

      ~/.claude/projects/<slug>/
      ├── memory/
      │   ├── MEMORY.md               # index (skipped)
      │   ├── project_*.md            # project decisions
      │   ├── feedback_*.md           # rules/constraints
      │   └── user_*.md               # preferences
      ├── CLAUDE.md                   # project instructions
      └── *.jsonl                     # session transcripts
  """

  @behaviour Recollect.Learner.CodingAgent.Provider

  import Recollect.Learner.CodingAgent.Util, only: [resolve_paths: 1]

  alias Recollect.Learner.CodingAgent.Util

  @memory_type_map %{
    "project" => :development_insight,
    "feedback" => :decision,
    "user" => :preference,
    "human" => :note
  }

  @memory_valence_map %{
    "project" => :neutral,
    "feedback" => :negative,
    "user" => :positive,
    "human" => :neutral
  }

  @memory_half_life_map %{
    "project" => 45.0,
    "feedback" => 60.0,
    "user" => 90.0,
    "human" => 30.0
  }

  @impl true
  def agent_name, do: :claude_code

  @impl true
  def default_data_paths, do: ["~/.claude/projects"]

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
    dir = Util.expand(hd(resolve_paths(config)))
    projects = Keyword.get(opts, :projects)
    since = Keyword.get(opts, :since, %{})

    dir
    |> File.ls!()
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.filter(&File.dir?/1)
    |> maybe_filter_projects(projects)
    |> Enum.flat_map(&fetch_project(&1, since))
  end

  @impl true
  def extract(%{source: :memory_file} = event), do: extract_memory(event)
  def extract(%{source: :claude_md} = event), do: extract_claude_md(event)
  def extract(%{source: :session} = event), do: extract_session(event)
  def extract(_), do: {:skip, "unknown event type"}

  @impl true
  def summarize(events, _scope_id) do
    events
    |> Enum.filter(&(&1.source == :session))
    |> Enum.group_by(& &1.project)
    |> Enum.flat_map(&build_project_insight/1)
  end

  # --- memory files ---

  defp extract_memory(event) do
    %{frontmatter: fm, body: body, memory_type: mem_type} = event

    type = Map.get(@memory_type_map, mem_type, :note)
    valence = Map.get(@memory_valence_map, mem_type, :neutral)
    half_life = Map.get(@memory_half_life_map, mem_type, 30.0)

    name = Map.get(fm, "name", "Untitled")
    description = Map.get(fm, "description", "")

    content =
      if description == "",
        do: "#{name}\n\n#{body}",
        else: "#{name}\n\n#{description}\n\n#{body}"

    {:ok,
     %{
       content: content,
       entry_type: type,
       emotional_valence: valence,
       tags: ["claude", "memory", "type:#{mem_type}", Util.project_tag(event.project)],
       metadata: %{source: :claude_code, memory_type: mem_type, memory_name: name, project: event.project},
       half_life_days: half_life,
       confidence: 0.95,
       summary: if(description == "", do: name, else: description)
     }}
  end

  # --- CLAUDE.md ---

  defp extract_claude_md(event) do
    {:ok,
     %{
       content: "Project instructions (CLAUDE.md):\n\n#{event.content}",
       entry_type: :decision,
       emotional_valence: :neutral,
       tags: ["claude", "project_instructions", Util.project_tag(event.project)],
       metadata: %{source: :claude_code, project: event.project},
       half_life_days: 30.0,
       confidence: 0.9,
       summary: "CLAUDE.md for #{event.project}"
     }}
  end

  # --- sessions ---

  defp extract_session(%{user_prompts: []}), do: {:skip, "no user prompts"}

  defp extract_session(event) do
    summary = Enum.join(event.user_prompts, "\n• ")

    {:ok,
     %{
       content: "Session #{Util.short_id(event.session_id)} in #{event.project}: #{summary}",
       entry_type: :note,
       emotional_valence: :neutral,
       tags: ["claude", "session", Util.project_tag(event.project)],
       metadata: %{
         source: :claude_code,
         session_id: event.session_id,
         project: event.project,
         prompt_count: length(event.user_prompts)
       }
     }}
  end

  defp build_project_insight({project, sessions}) do
    prompts = sessions |> Enum.flat_map(& &1.user_prompts) |> Enum.take(15)

    [
      %{
        content:
          "Claude Code activity in #{project}: #{length(sessions)} sessions, #{length(prompts)} prompts\n\nTopics:\n#{Enum.map_join(prompts, "\n", &"  • #{&1}")}",
        entry_type: :development_insight,
        emotional_valence: :neutral,
        tags: ["claude", "session_activity", Util.project_tag(project)],
        metadata: %{
          source: :claude_code,
          insight_type: :session_activity,
          project: project,
          session_count: length(sessions)
        },
        half_life_days: 21.0,
        confidence: 0.8,
        summary: "#{project}: #{length(sessions)} Claude sessions"
      }
    ]
  end

  # --- fetching ---

  defp fetch_project(project_path, since) do
    project = Path.basename(project_path)
    # Per-project timestamp wins; "*" is the global fallback a unified
    # learner passes when it only has one since value (MEM-012).
    project_since =
      Map.get(since, project) || Map.get(since, to_string(project)) || Map.get(since, "*")

    fetch_memory_files(project_path, project, project_since) ++
      fetch_claude_md(project_path, project, project_since) ++
      fetch_sessions(project_path, project, project_since)
  end

  defp maybe_filter_projects(paths, nil), do: paths

  defp maybe_filter_projects(paths, projects) when is_list(projects) do
    project_set = MapSet.new(projects)
    Enum.filter(paths, &MapSet.member?(project_set, Path.basename(&1)))
  end

  defp fetch_memory_files(project_path, project, since) do
    memory_dir = Path.join(project_path, "memory")

    if File.dir?(memory_dir) do
      memory_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.reject(&(&1 == "MEMORY.md"))
      |> Enum.map(fn filename ->
        path = Path.join(memory_dir, filename)

        with {:ok, content} <- File.read(path) do
          if file_newer_than?(path, since) do
            {fm, body} = Util.parse_frontmatter(content)

            %{
              agent: :claude_code,
              source: :memory_file,
              project: project,
              path: path,
              filename: filename,
              frontmatter: fm,
              body: body,
              memory_type: detect_memory_type(filename),
              file_mtime: file_mtime(path)
            }
          end
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp fetch_claude_md(project_path, project, since) do
    path = Path.join(project_path, "CLAUDE.md")

    with {:ok, content} <- File.read(path),
         true <- content != "",
         true <- file_newer_than?(path, since) do
      [%{agent: :claude_code, source: :claude_md, project: project, content: content, file_mtime: file_mtime(path)}]
    else
      _ -> []
    end
  end

  defp fetch_sessions(project_path, project, since) do
    project_path
    |> File.ls!()
    |> Enum.filter(fn f -> String.ends_with?(f, ".jsonl") and File.regular?(Path.join(project_path, f)) end)
    |> Enum.filter(fn f ->
      path = Path.join(project_path, f)
      file_newer_than?(path, since)
    end)
    |> Enum.take(10)
    |> Enum.map(fn filename ->
      path = Path.join(project_path, filename)
      session_id = String.replace_suffix(filename, ".jsonl", "")

      with {:ok, content} <- File.read(path) do
        prompts =
          content
          |> Util.extract_jsonl_lines()
          |> Enum.flat_map(&Util.extract_user_text_from_json/1)
          |> Enum.take(20)

        if prompts != [] do
          %{
            agent: :claude_code,
            source: :session,
            project: project,
            session_id: session_id,
            user_prompts: prompts,
            file_mtime: file_mtime(path)
          }
        end
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp file_newer_than?(path, since), do: Util.file_newer_than?(path, since)

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, stat} -> Util.mtime_to_datetime(stat.mtime)
      _ -> nil
    end
  end

  defp detect_memory_type(filename) do
    name = String.downcase(filename)

    cond do
      String.starts_with?(name, "project_") -> "project"
      String.starts_with?(name, "feedback_") -> "feedback"
      String.starts_with?(name, "user_") -> "user"
      String.starts_with?(name, "human_") -> "human"
      true -> "project"
    end
  end
end
