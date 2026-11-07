defmodule Recollect.Context.Detector do
  @moduledoc """
  Detect current environment context from the running system.

  Supports: Git repository, working directory, OS, and custom context.

  NOTE: `detect/0` is NOT pure — it shells out to `git`. Hot paths
  (remember/2, search context boosts) should use `resolve_context/1`, which
  applies the configured mode (`context_detection: [mode: :cached]`,
  default) and its TTL cache.
  """

  alias Recollect.Telemetry

  @detectors [:git, :path, :os]

  @default_ttl_ms 60_000

  @doc """
  Detect context with a TTL cache keyed by the current working directory.

  `detect/0` shells out to `git` twice per call; remember/2 and search call
  it on EVERY write and read (MEM-010). The cached variant answers repeat
  calls within the TTL (default 60s) from `:persistent_term` — one entry per
  cwd, so long-lived processes working across repos don't cross-contaminate.

  ## Options
  - `:ttl_ms` — override the cache TTL (0 disables caching)
  """
  def detect_cached(opts \\ []) do
    ttl = Keyword.get(opts, :ttl_ms, cache_ttl_ms())

    if ttl <= 0 do
      detect()
    else
      cwd = File.cwd!()
      key = {__MODULE__, :detect_cache, cwd}
      now = System.monotonic_time(:millisecond)

      case :persistent_term.get(key, nil) do
        {timestamp, context} when now - timestamp < ttl ->
          context

        _ ->
          context = detect()
          :persistent_term.put(key, {now, context})
          context
      end
    end
  end

  @doc """
  Clear the detect cache (all cwds). Hosts that change the process cwd
  mid-flight and tests that need a cold cache should call this.
  """
  def clear_cache do
    for {{__MODULE__, :detect_cache, _cwd} = key, _value} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end

    :ok
  end

  @doc """
  Resolve the context for a write/read, honoring (in priority order):

  1. an explicit `context` map / `:none` / `:auto` option
  2. the deprecated `:context_hints` option (alias for an explicit map)
  3. `config :recollect, context_detection: [mode: :cached | :auto | :none]`
     (default `:cached`)
  """
  def resolve_context(opts) when is_list(opts) do
    case Keyword.get(opts, :context, :unset) do
      :unset ->
        case Keyword.get(opts, :context_hints) do
          hints when is_map(hints) -> hints
          _ -> resolve_mode(mode())
        end

      :auto ->
        detect()

      :none ->
        %{}

      explicit when is_map(explicit) ->
        explicit
    end
  end

  defp resolve_mode(:none), do: %{}
  defp resolve_mode(:auto), do: detect()
  defp resolve_mode(:cached), do: detect_cached()
  defp resolve_mode(_), do: detect_cached()

  @doc "Configured context-detection mode: :cached | :auto | :none."
  def mode do
    case Application.get_env(:recollect, :context_detection, []) do
      opts when is_list(opts) -> Keyword.get(opts, :mode, :cached)
      _ -> :cached
    end
  end

  defp cache_ttl_ms do
    case Application.get_env(:recollect, :context_detection, []) do
      opts when is_list(opts) -> Keyword.get(opts, :ttl_ms, @default_ttl_ms)
      _ -> @default_ttl_ms
    end
  end

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
