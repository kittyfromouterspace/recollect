defmodule Recollect.Learner.Git do
  @moduledoc """
  Learn from git history — commits, branches, tags.

  Detects:
  - Bug fixes ("fix", "bug", "patch")
  - Features ("feat", "feature", "add")
  - Reverts ("revert", "undo")
  - Breaking changes ("BREAKING", "migrate")
  - Documentation changes ("docs", "readme")

  ## Usage

      {:ok, result} = Recollect.Learner.Git.fetch_since("7 days ago", scope_id)
      {:ok, result} = Recollect.Learner.Git.run(scope_id: scope_id)
  """

  @behaviour Recollect.Learner

  alias Recollect.Telemetry

  @impl true
  def source, do: :git

  @impl true
  def fetch_since(since, scope_id) do
    start_time = System.monotonic_time()

    result = git_log(since)

    duration =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    case result do
      {:ok, commits} ->
        Telemetry.event(
          [:recollect, :learn, :git, :fetch, :stop],
          %{
            duration_ms: duration,
            commits_found: length(commits)
          },
          %{scope_id: scope_id, since: since}
        )

      {:error, reason} ->
        Telemetry.event(
          [:recollect, :learn, :git, :fetch, :stop],
          %{
            duration_ms: duration,
            commits_found: 0,
            error: inspect(reason)
          },
          %{scope_id: scope_id, since: since}
        )
    end

    result
  end

  @impl true
  def extract(commit) do
    message = commit.subject
    body = commit.body || ""
    full_message = if body == "", do: message, else: "#{message}\n\n#{body}"

    type = detect_type(message)
    valence = detect_valence(type, message)
    tags = build_tags(type, commit)

    {:ok,
     %{
       content: "[#{type}] #{full_message}",
       entry_type: type_to_entry_type(type),
       emotional_valence: valence,
       tags: tags,
       metadata: %{
         source: :git,
         commit_sha: commit.sha,
         author: commit.author,
         branch: commit.branch || "unknown"
       }
     }}
  end

  @impl true
  def detect_patterns(commits) do
    # Detect migration patterns
    commits
    |> Enum.filter(fn c -> String.contains?(c.subject, ["migrate", "migrated"]) end)
    |> Enum.chunk_by(fn c -> extract_migration_target(c.subject) end)
    |> Enum.filter(fn chunk -> length(chunk) >= 1 end)
    |> Enum.map(fn chunk ->
      [from, to] = extract_migration_pair(List.first(chunk).subject)

      %{
        type: :migration,
        from: from,
        to: to,
        summary: "Migration from #{from} to #{to}",
        events: chunk
      }
    end)
  end

  @impl true
  def summarize(events, _scope_id) do
    insights = Recollect.Learner.Git.Grouper.summarize(events)

    deprecations =
      events
      |> Recollect.Learner.Git.StackDetector.detect_transitions_from_commits()
      |> Enum.map(fn transition ->
        %{
          content: "DEPRECATED: #{transition.from} has been replaced by #{transition.to}.",
          entry_type: :development_insight,
          emotional_valence: :neutral,
          tags: ["deprecation", "stack-transition", transition.from, transition.to],
          metadata: %{
            source: :git,
            insight_type: :deprecation,
            from: transition.from,
            to: transition.to,
            category: transition.category,
            evidence: transition.evidence
          },
          half_life_days: 60.0,
          confidence: 1.0,
          pinned: true
        }
      end)

    insights ++ deprecations
  end

  @doc "Run the full git learning pipeline for a scope."
  def run(opts \\ []) do
    scope_id = Keyword.get(opts, :scope_id)
    since = Keyword.get(opts, :since, "7 days ago")

    with {:ok, commits} <- fetch_since(since, scope_id) do
      results = Enum.map(commits, &process_commit/1)

      {:ok,
       %{
         fetched: length(commits),
         learned: Enum.count(results, &match?({:ok, _}, &1)),
         skipped: Enum.count(results, &match?({:skip, _}, &1))
       }}
    end
  end

  # Private implementation

  defp git_log(since) do
    # Get commits since the given date with full message
    format = "%H|%s|%b|%an|%D"

    case System.cmd("git", ["log", "--since=#{since}", "--pretty=format:#{format}", "--all"], stderr_to_stdout: true) do
      {output, 0} when output != "" ->
        commits =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_commit/1)
          |> Enum.reject(&is_nil/1)

        {:ok, commits}

      {_output, 0} ->
        {:ok, []}

      {_, _} ->
        {:error, :not_a_git_repo}
    end
  end

  defp parse_commit(line) do
    case String.split(line, "|", parts: 5) do
      [sha, subject, body, author, refs] ->
        %{
          sha: sha,
          subject: String.trim(subject),
          body: String.trim(body),
          author: String.trim(author),
          branch: extract_branch(refs)
        }

      _ ->
        nil
    end
  end

  defp extract_branch(refs) do
    # Extract branch from git refs (e.g., "HEAD -> main, origin/main")
    refs
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.find(fn r ->
      String.match?(r, ~r/^[^\s]+$/) and not String.starts_with?(r, "origin/")
    end)
    |> case do
      nil -> "main"
      "HEAD" -> "main"
      branch -> branch
    end
  end

  @doc "Classify a commit message into a type atom."
  def detect_type(message) do
    low = String.downcase(message)

    cond do
      String.contains?(low, "merge") ->
        :merge

      String.contains?(low, "revert") ->
        :revert

      String.contains?(low, "breaking") ->
        :breaking

      String.contains?(low, "migrate") ->
        :migration

      String.contains?(low, "fix") or String.contains?(low, "bug") or
          String.contains?(low, "patch") ->
        :fix

      String.contains?(low, "feat") or String.contains?(low, "feature") or
          String.contains?(low, "add ") ->
        :feature

      String.contains?(low, "docs") or String.contains?(low, "readme") ->
        :docs

      String.contains?(low, "refactor") ->
        :refactor

      String.contains?(low, "test") ->
        :test

      true ->
        :other
    end
  end

  defp detect_valence(type, message) do
    low = String.downcase(message)

    cond do
      type in [:fix, :breaking, :migration] -> :negative
      String.contains?(low, "fail") or String.contains?(low, "error") -> :negative
      type in [:feature, :docs] -> :positive
      true -> :neutral
    end
  end

  defp type_to_entry_type(:fix), do: :observation
  defp type_to_entry_type(:breaking), do: :decision
  defp type_to_entry_type(:migration), do: :decision
  defp type_to_entry_type(:feature), do: :note
  defp type_to_entry_type(:docs), do: :note
  defp type_to_entry_type(:revert), do: :hypothesis
  defp type_to_entry_type(:refactor), do: :note
  defp type_to_entry_type(:test), do: :note
  defp type_to_entry_type(:merge), do: :note
  defp type_to_entry_type(:other), do: :observation

  defp build_tags(type, commit) do
    base = ["git", "commit", atom_to_tag(type)]

    if commit.branch && commit.branch != "main" do
      ["branch:#{commit.branch}" | base]
    else
      base
    end
  end

  defp atom_to_tag(atom) do
    "type:#{atom}"
  end

  defp extract_migration_target(message) do
    # Extract what we're migrating TO
    case Regex.run(~r/migrate[ds]?\s+(?:from\s+)?(\w+)\s+(?:to|with)\s+(\w+)/i, message) do
      [_, _from, to] -> to
      _ -> nil
    end
  end

  defp extract_migration_pair(message) do
    case Regex.run(~r/migrate[ds]?\s+(?:from\s+)?(\w+)\s+(?:to|with)\s+(\w+)/i, message) do
      [_, from, to] -> [from, to]
      _ -> ["unknown", "unknown"]
    end
  end

  defp process_commit(commit) do
    {:ok, extract} = extract(commit)

    Recollect.remember(extract.content,
      entry_type: extract.entry_type,
      emotional_valence: extract.emotional_valence,
      tags: extract.tags,
      metadata: extract.metadata,
      source: "system"
    )
  end
end
