defmodule Recollect.Learner.Git.StackDetector do
  @moduledoc """
  Detects the project's technology stack from config files and tracks
  framework transitions across git history.

  Two modes of operation:

  1. **Snapshot** — reads current config files to determine the present stack
  2. **Diff** — walks git history for config-file changes to discover
     transitions (additions and removals of build tools, test runners,
     frameworks, etc.)

  When a technology is removed (e.g. webpack disappears, esbuild appears),
  the detector returns a `%{type: :deprecation, from: ..., to: ...}` transition
  that the caller feeds into `Recollect.Invalidation.invalidate/3` to weaken
  memories about the old technology.
  """

  @config_files [
    "package.json",
    "mix.exs",
    "Gemfile",
    "requirements.txt",
    "pyproject.toml",
    "Cargo.toml",
    "go.mod",
    "pom.xml",
    "build.gradle"
  ]

  @technology_map %{
    "webpack" => %{category: :build_tool, names: ["webpack"]},
    "vite" => %{category: :build_tool, names: ["vite"]},
    "rollup" => %{category: :build_tool, names: ["rollup"]},
    "esbuild" => %{category: :build_tool, names: ["esbuild"]},
    "parcel" => %{category: :build_tool, names: ["parcel"]},
    "turbo" => %{category: :build_tool, names: ["turbo"]},
    "babel" => %{category: :transpiler, names: ["babel", "@babel/core"]},
    "typescript" => %{category: :language, names: ["typescript", "tslib"]},
    "jest" => %{category: :test_framework, names: ["jest"]},
    "vitest" => %{category: :test_framework, names: ["vitest"]},
    "mocha" => %{category: :test_framework, names: ["mocha"]},
    "pytest" => %{category: :test_framework, names: ["pytest"]},
    "exunit" => %{category: :test_framework, names: []},
    "tailwind" => %{category: :css_framework, names: ["tailwindcss"]},
    "sass" => %{category: :css_preprocessor, names: ["sass", "node-sass"]},
    "eslint" => %{category: :linter, names: ["eslint"]},
    "prettier" => %{category: :formatter, names: ["prettier"]},
    "react" => %{category: :ui_framework, names: ["react"]},
    "vue" => %{category: :ui_framework, names: ["vue"]},
    "svelte" => %{category: :ui_framework, names: ["svelte"]},
    "angular" => %{category: :ui_framework, names: ["@angular/core"]},
    "phoenix" => %{category: :web_framework, names: ["phoenix"]},
    "rails" => %{category: :web_framework, names: ["rails"]},
    "next" => %{category: :meta_framework, names: ["next"]},
    "nuxt" => %{category: :meta_framework, names: ["nuxt"]},
    "postgres" => %{category: :database, names: ["postgres", "pg", "ecto_sql"]},
    "mysql" => %{category: :database, names: ["mysql", "mysql2"]},
    "sqlite" => %{category: :database, names: ["sqlite3"]},
    "redis" => %{category: :cache, names: ["redis", "redix"]},
    "docker" => %{category: :containerization, names: []},
    "cypress" => %{category: :e2e_framework, names: ["cypress"]},
    "playwright" => %{category: :e2e_framework, names: ["playwright"]},
    "storybook" => %{category: :dev_tool, names: ["storybook"]}
  }

  @category_transitions %{
    build_tool: [
      {"webpack", "vite"},
      {"webpack", "esbuild"},
      {"webpack", "rollup"},
      {"webpack", "parcel"},
      {"webpack", "turbo"},
      {"rollup", "vite"},
      {"rollup", "esbuild"},
      {"gulp", "webpack"},
      {"grunt", "webpack"},
      {"grunt", "gulp"}
    ],
    test_framework: [
      {"jest", "vitest"},
      {"mocha", "jest"},
      {"mocha", "vitest"},
      {"karma", "jest"},
      {"enzyme", "react-testing-library"},
      {"jasmine", "jest"}
    ],
    css_framework: [
      {"sass", "tailwind"},
      {"less", "tailwind"},
      {"styled-components", "tailwind"},
      {"css-modules", "tailwind"}
    ],
    linter: [
      {"tslint", "eslint"},
      {"eslint", "biome"}
    ],
    ui_framework: [
      {"jquery", "react"},
      {"jquery", "vue"},
      {"jquery", "svelte"}
    ],
    transpiler: [
      {"babel", "swc"},
      {"babel", "esbuild"}
    ],
    meta_framework: [
      {"create-react-app", "vite"},
      {"create-react-app", "next"},
      {"nuxt", "next"}
    ]
  }

  @doc """
  Detect the current technology stack by reading config files on disk.

  Returns a map of `%{technology => %{category: atom, evidence: [String.t()]}}`.
  """
  def detect_current do
    evidence = collect_evidence()

    evidence
    |> Enum.flat_map(fn {tech_id, items} ->
      case Map.get(@technology_map, tech_id) do
        nil -> []
        info -> [{tech_id, %{category: info.category, evidence: items}}]
      end
    end)
    |> Map.new()
  end

  @doc """
  Detect technology transitions from git history by comparing config files
  at two points in time.

  Returns a list of `%{type: :deprecation, from: tech, to: tech, category: atom, evidence: String.t()}`.
  """
  def detect_transitions(since \\ "30 days ago") do
    current_stack = detect_current()
    past_stack = detect_at(since)

    find_transitions(past_stack, current_stack)
  end

  @doc """
  Detect transitions from a list of git log entries (commit maps with :subject).

  This is the path used by the Git learner's `summarize/2` callback — it
  inspects commit subjects for technology change patterns in addition to
  config file diffs.
  """
  def detect_transitions_from_commits(commits) do
    commit_transitions = Enum.flat_map(commits, &scan_commit_for_transition/1)

    config_transitions = detect_transitions_from_git_log(commits)

    deduplicate_transitions(commit_transitions ++ config_transitions)
  end

  defp detect_at(since) do
    evidence = collect_evidence_at(since)

    evidence
    |> Enum.flat_map(fn {tech_id, items} ->
      case Map.get(@technology_map, tech_id) do
        nil -> []
        info -> [{tech_id, %{category: info.category, evidence: items}}]
      end
    end)
    |> Map.new()
  end

  defp find_transitions(past, current) do
    past_techs = Map.keys(past)
    current_techs = Map.keys(current)

    removed = past_techs -- current_techs
    added = current_techs -- past_techs

    for r <- removed,
        a <- added,
        transition = find_transition_category(r, a),
        transition != nil do
      %{
        type: :deprecation,
        from: r,
        to: a,
        category: transition,
        evidence: "Detected transition from #{r} to #{a}"
      }
    end
  end

  defp find_transition_category(from, to) do
    Enum.find_value(@category_transitions, fn {category, transitions} ->
      if {from, to} in transitions, do: category
    end)
  end

  @doc "Check if a from→to transition is a known migration path."
  def known_transition?(from, to) do
    find_transition_category(from, to) != nil
  end

  @doc "Get the technology category for a given tech name."
  def category_for(tech) do
    case Map.get(@technology_map, tech) do
      %{category: cat} -> cat
      nil -> :unknown
    end
  end

  defp collect_evidence do
    group_by_technology(package_json_evidence() ++ mix_exs_evidence() ++ config_file_evidence() ++ docker_evidence())
  end

  defp collect_evidence_at(since) do
    group_by_technology(package_json_at(since) ++ config_files_at(since) ++ docker_evidence())
  end

  defp collect_evidence_from_git_log(commits) do
    commits
    |> Enum.flat_map(&scan_commit_for_evidence/1)
    |> group_by_technology()
  end

  defp group_by_technology(evidence_list) do
    Enum.group_by(evidence_list, fn {tech_id, _} -> tech_id end, fn {_, item} -> item end)
  end

  defp package_json_evidence do
    case File.read("package.json") do
      {:ok, content} -> parse_package_json(content)
      _ -> []
    end
  end

  defp package_json_at(since) do
    case git_show_at("package.json", since) do
      {:ok, content} -> parse_package_json(content)
      _ -> []
    end
  end

  defp parse_package_json(content) do
    case Jason.decode(content) do
      {:ok, json} ->
        deps = Map.get(json, "dependencies", %{})
        dev_deps = Map.get(json, "devDependencies", %{})
        scripts = Map.get(json, "scripts", %{})
        all_deps = Map.merge(deps, dev_deps)

        from_deps(all_deps) ++
          from_scripts(scripts) ++
          from_dev_dep_presence(dev_deps)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp from_deps(deps) do
    dep_names = Map.keys(deps)

    Enum.flat_map(@technology_map, fn {tech_id, %{names: names}} ->
      found = Enum.filter(names, &(&1 in dep_names))

      if found == [] do
        []
      else
        [{to_string(tech_id), "dependency: #{Enum.join(found, ", ")}"}]
      end
    end)
  end

  defp from_scripts(scripts) do
    script_vals = scripts |> Map.values() |> Enum.join(" ")
    script_keys = scripts |> Map.keys() |> Enum.join(" ")
    combined = String.downcase("#{script_keys} #{script_vals}")

    checks = [
      {"webpack", &String.contains?(&1, "webpack")},
      {"vite", &String.contains?(&1, "vite")},
      {"esbuild", &String.contains?(&1, "esbuild")},
      {"rollup", &String.contains?(&1, "rollup")},
      {"jest", &String.contains?(&1, "jest")},
      {"vitest", &String.contains?(&1, "vitest")},
      {"cypress", &String.contains?(&1, "cypress")},
      {"playwright", &String.contains?(&1, "playwright")},
      {"storybook", &String.contains?(&1, "storybook")},
      {"next", &String.contains?(&1, "next")},
      {"tailwind", &String.contains?(&1, "tailwind")}
    ]

    Enum.flat_map(checks, fn {tech, check_fn} ->
      if check_fn.(combined), do: [{tech, "script_reference"}], else: []
    end)
  end

  defp from_dev_dep_presence(dev_deps) do
    dep_names = dev_deps |> Map.keys() |> Enum.map(&String.downcase/1)

    checks = [
      {"typescript", fn names -> "typescript" in names end},
      {"eslint", fn names -> Enum.any?(names, &String.contains?(&1, "eslint")) end},
      {"prettier", fn names -> "prettier" in names end}
    ]

    Enum.flat_map(checks, fn {tech, check_fn} ->
      if check_fn.(dep_names), do: [{tech, "dev_dependency"}], else: []
    end)
  end

  defp mix_exs_evidence do
    case File.read("mix.exs") do
      {:ok, content} -> parse_mix_exs(content)
      _ -> []
    end
  end

  defp parse_mix_exs(content) do
    low = String.downcase(content)

    checks = [
      {"phoenix", &String.contains?(&1, ":phoenix")},
      {"ecto", &String.contains?(&1, ":ecto")},
      {"postgres", &(String.contains?(&1, ":ecto_sql") or String.contains?(&1, ":postgrex"))},
      {"exunit", &String.contains?(&1, ":ex_unit")},
      {"oban", &String.contains?(&1, ":oban")},
      {"liveview", &String.contains?(&1, ":phoenix_live_view")},
      {"surface", &String.contains?(&1, ":surface")}
    ]

    Enum.flat_map(checks, fn {tech, check_fn} ->
      if check_fn.(low), do: [{tech, "mix_dep"}], else: []
    end)
  end

  defp config_file_evidence do
    checks = [
      {"webpack", fn -> glob_exists?("webpack.config.*") end},
      {"vite", fn -> glob_exists?("vite.config.*") end},
      {"esbuild", fn -> glob_exists?("esbuild.*") end},
      {"rollup", fn -> glob_exists?("rollup.config.*") end},
      {"babel", fn -> glob_exists?(".babelrc") or glob_exists?("babel.config.*") end},
      {"jest", fn -> glob_exists?("jest.config.*") end},
      {"vitest", fn -> glob_exists?("vitest.config.*") end},
      {"tailwind", fn -> glob_exists?("tailwind.config.*") end},
      {"typescript", fn -> glob_exists?("tsconfig.json") end},
      {"eslint", fn -> glob_exists?(".eslintrc*") or glob_exists?("eslint.config.*") end},
      {"prettier", fn -> glob_exists?(".prettierrc*") end}
    ]

    Enum.flat_map(checks, fn {tech, check_fn} ->
      if check_fn.(), do: [{tech, "config_file"}], else: []
    end)
  end

  defp config_files_at(since) do
    config_names =
      @config_files ++
        [
          "webpack.config.js",
          "webpack.config.ts",
          "vite.config.ts",
          "vite.config.js",
          "esbuild.js",
          "rollup.config.js",
          ".babelrc",
          "jest.config.js",
          "vitest.config.ts",
          "tsconfig.json",
          "tailwind.config.js"
        ]

    Enum.flat_map(config_names, fn path ->
      case git_show_at(path, since) do
        {:ok, _content} ->
          tech = tech_from_config_path(path)

          if tech do
            [{tech, "config_file_existed_at_#{since}"}]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  defp docker_evidence do
    if File.exists?("Dockerfile") or File.exists?("docker-compose.yml") do
      [{"docker", "dockerfile_or_compose"}]
    else
      []
    end
  end

  defp tech_from_config_path(path) do
    cond do
      String.contains?(path, "webpack") -> "webpack"
      String.contains?(path, "vite") -> "vite"
      String.contains?(path, "esbuild") -> "esbuild"
      String.contains?(path, "rollup") -> "rollup"
      String.contains?(path, "babel") -> "babel"
      String.contains?(path, "jest") -> "jest"
      String.contains?(path, "vitest") -> "vitest"
      String.contains?(path, "tsconfig") -> "typescript"
      String.contains?(path, "tailwind") -> "tailwind"
      String.contains?(path, "eslint") -> "eslint"
      String.contains?(path, "prettier") -> "prettier"
      true -> nil
    end
  end

  defp detect_transitions_from_git_log(commits) do
    evidence = collect_evidence_from_git_log(commits)

    evidence
    |> Enum.flat_map(fn {tech_id, items} ->
      case Map.get(@technology_map, tech_id) do
        nil -> []
        info -> [{tech_id, %{category: info.category, evidence: items}}]
      end
    end)
    |> Map.new()
    |> then(fn stack ->
      current = detect_current()
      find_transitions(stack, current)
    end)
  end

  defp scan_commit_for_transition(commit) do
    subject = String.downcase(commit.subject)

    Enum.flat_map(@category_transitions, fn {category, transitions} ->
      Enum.flat_map(transitions, fn {from, to} ->
        cond do
          String.contains?(subject, "migrate") and
            String.contains?(subject, from) and
              String.contains?(subject, to) ->
            [
              %{
                type: :deprecation,
                from: from,
                to: to,
                category: category,
                evidence: "Commit: #{commit.subject}"
              }
            ]

          String.contains?(subject, "replace") and
            String.contains?(subject, from) and
              String.contains?(subject, to) ->
            [
              %{
                type: :deprecation,
                from: from,
                to: to,
                category: category,
                evidence: "Commit: #{commit.subject}"
              }
            ]

          String.contains?(subject, "switch") and
            String.contains?(subject, from) and
              String.contains?(subject, to) ->
            [
              %{
                type: :deprecation,
                from: from,
                to: to,
                category: category,
                evidence: "Commit: #{commit.subject}"
              }
            ]

          true ->
            []
        end
      end)
    end)
  end

  defp scan_commit_for_evidence(commit) do
    subject = String.downcase(commit.subject)

    Enum.flat_map(@technology_map, fn {tech_id, _info} ->
      tech_str = to_string(tech_id)

      if String.contains?(subject, tech_str) do
        [{tech_str, "commit_subject: #{commit.subject}"}]
      else
        []
      end
    end)
  end

  defp deduplicate_transitions(transitions) do
    Enum.uniq_by(transitions, fn t -> {t.from, t.to} end)
  end

  defp glob_exists?(pattern) do
    case Path.wildcard(pattern) do
      [] -> false
      _ -> true
    end
  end

  defp git_show_at(path, since) do
    case System.cmd("git", ["log", "--since=#{since}", "-1", "--pretty=format:%H", "--", path], stderr_to_stdout: true) do
      {sha, 0} when sha != "" ->
        case System.cmd("git", ["show", "#{String.trim(sha)}:#{path}"], stderr_to_stdout: true) do
          {content, 0} -> {:ok, content}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end
end
