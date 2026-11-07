defmodule Recollect.Guards do
  @moduledoc """
  Engine-level secret guard.

  Three deployments (home, ops_center, AgentForge) each grew a private
  `possible_secret?/1` regex because Recollect would happily store an API
  credential as a memory. The guard belongs here: one implementation, one
  audit point, applied on every engine write (`Knowledge.remember/2`,
  staging, distillation paths).

  Defaults are deliberately conservative — a miss leaks, but a false positive
  trains hosts to disable the guard. Patterns cover credential shapes, not
  words: PEM blocks, provider key prefixes, bearer headers, credential-style
  `key = value` assignments, and AWS-style access key ids.

  Configuration:

      config :recollect,
        guards: [
          enabled: true,             # default true
          extra_patterns: [~r/.../ ] # host-specific additions
        ]

  Per-call opt-out for hosts that pre-scrub: `remember(..., allow_secrets: true)`.
  """

  @default_patterns [
    # PEM private key blocks
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    # OpenAI/Anthropic/Stripe-shaped secret keys and generic prefixed tokens
    ~r/\b(sk|rk|pk)-[A-Za-z0-9_-]{16,}\b/,
    # AWS access key ids
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    # GitHub / npm / Slack style tokens
    ~r/\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
    ~r/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/,
    # Bearer headers carrying something long enough to be a credential
    ~r/\bBearer\s+[A-Za-z0-9._\-]{20,}\b/i,
    # credential-style assignments: api_key = "...", TOKEN: "..." etc.
    ~r/\b(api[_-]?key|secret|token|passwd|password|credential[s]?)\b\s*[:=]\s*\S{8,}/i
  ]

  @doc """
  True when the text looks like it contains a credential.

  Checks the configured patterns (defaults plus `guards.extra_patterns`).
  """
  def possible_secret?(text) when is_binary(text) do
    patterns = enabled_patterns()
    text = to_string(text)
    Enum.any?(patterns, fn pattern -> Regex.match?(pattern, text) end)
  end

  def possible_secret?(_), do: false

  @doc """
  Check a value (and, for maps, its string values) against the guard.

  Returns `:ok` or `{:error, :possible_secret}`.
  """
  def check(value, opts \\ [])

  def check(value, opts) when is_map(value) and not is_struct(value) do
    value
    |> Enum.filter(fn {_k, v} -> is_binary(v) end)
    |> Enum.all?(fn {_k, v} -> not possible_secret?(v) end)
    |> case do
      true -> maybe_reject(value, opts)
      false -> {:error, :possible_secret}
    end
  end

  def check(value, opts), do: maybe_reject(value, opts)

  @doc "Whether the engine-level guard is enabled (config `guards.enabled`, default true)."
  def enabled? do
    :recollect
    |> Application.get_env(:guards, [])
    |> guard_opt(:enabled, true)
  end

  defp maybe_reject(value, opts) do
    cond do
      not enabled?() ->
        :ok

      Keyword.get(opts, :allow_secrets, false) ->
        :ok

      possible_secret?(value) ->
        :telemetry.execute([:recollect, :guard, :rejected], %{count: 1}, %{})

        {:error, :possible_secret}

      true ->
        :ok
    end
  end

  defp enabled_patterns do
    extra = :recollect |> Application.get_env(:guards, []) |> guard_opt(:extra_patterns, [])
    List.wrap(extra) ++ @default_patterns
  end

  defp guard_opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp guard_opt(_opts, _key, default), do: default
end
