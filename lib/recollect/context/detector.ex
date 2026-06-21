defmodule Recollect.Context.Detector do
  @moduledoc """
  Detect current environment context from the running system.

  Supports: Git repository, working directory, OS, and custom context.

  All detector functions are pure — no side effects, easy to test.
  """

  alias Recollect.Telemetry

  @detectors [:git, :path, :os]

  @doc """
  Detect all available context signals.

  Returns a map with detected context values:
  %{
    repo: "owner/repo",
    branch: "main",
    path_prefix: "/home/user/project",
    os: "linux"
  }
  """
  def detect do
    start_time = System.monotonic_time()

    context =
      @detectors
      |> Enum.flat_map(&run_detector/1)
      |> Map.new(fn %{key: k, value: v} -> {k, v} end)

    duration =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    Telemetry.event(
      [:recollect, :context, :detect, :stop],
      %{duration_ms: duration, keys_detected: map_size(context)},
      %{keys: Map.keys(context)}
    )

    context
  end

  @doc "Detect only git context (safe to call even outside a repo)."
  def detect_git do
    :git
    |> run_detector()
    |> Map.new(fn %{key: k, value: v} -> {k, v} end)
  end

  @doc "Detect the current working directory."
  def detect_path do
    :path
    |> run_detector()
    |> Map.new(fn %{key: k, value: v} -> {k, v} end)
  end

  @doc "Detect the operating system."
  def detect_os do
    :os
    |> run_detector()
    |> Map.new(fn %{key: k, value: v} -> {k, v} end)
  end

  @doc "List available detectors."
  def available_detectors, do: @detectors

  defp run_detector(:git), do: detect_git_impl()
  defp run_detector(:path), do: detect_path_impl()
  defp run_detector(:os), do: detect_os_impl()

  defp detect_git_impl do
    # `git` may be absent (e.g. a minimal prod VM) — System.cmd would raise
    # :enoent and crash callers (remember/search). Degrade to "no git context".
    if System.find_executable("git") do
      detect_git_cmd()
    else
      []
    end
  end

  defp detect_git_cmd do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {path, 0} ->
        path = String.trim(path)

        context = [%{key: :path_prefix, value: path}]

        case System.cmd("git", ["remote", "get-url", "origin"], cd: path, stderr_to_stdout: true) do
          {remote, 0} ->
            repo = parse_git_remote(remote)
            [%{key: :repo, value: repo} | context]

          _ ->
            # Fallback: use directory name as identifier
            [%{key: :repo, value: Path.basename(path)} | context]
        end

      _ ->
        []
    end
  end

  defp detect_path_impl do
    case System.get_env("PWD") || System.get_env("OLDPWD") do
      nil ->
        []

      path ->
        [%{key: :path_prefix, value: path}]
    end
  end

  defp detect_os_impl do
    Enum.map([{:os, :os.type() |> elem(0) |> Atom.to_string()}], fn {k, v} -> %{key: k, value: v} end)
  end

  defp parse_git_remote(remote) do
    remote
    |> String.trim()
    |> String.replace_suffix(".git", "")
    |> String.replace_prefix("git@github.com:", "")
    |> String.replace_prefix("https://github.com/", "")
  end

  @doc """
  Check if a given entry's context hints match the current context.

  Returns the number of matching keys.
  """
  def context_matches(entry_hints, current_context) do
    Enum.count(entry_hints, fn {key, value} ->
      Map.get(current_context, key) == value
    end)
  end
end
