defmodule Recollect.Learner.Harvest.Sink.Mcp do
  @default_url "https://ops-center.kfos.nz/mcp"

  @moduledoc """
  Push extracted records to a memory server's `stage_memory` MCP tool
  (default: OpsCenter) — the DB-less path for laptops that cannot reach the
  fleet store directly. The server distills staged notes into permanent,
  project-scoped memory on its scheduled sleep.

  A single `tools/call` POST per record — no `initialize` handshake required
  by `AshAi.Mcp.Router`. Generic-action arguments are nested under `"input"`.

  Ported from kfos_teamkit's `McpClient` in B-2163.

  ## Options

    * `:project` (required) — the target scope (e.g. `"mark_mesh"`, `"shared"`)
    * `:url` — endpoint; or `OPS_CENTER_MCP_URL`; default #{@default_url}
    * `:api_key` — or `OPS_CENTER_API_KEY` / `KFOS_API_KEY`
    * `:node_id` — originating machine identity for audit
      (default `Recollect.Learner.Checkpoint.node_id/0`)
    * `:req_options` — extra `Req.new/1` options (e.g. a test `:adapter`)
  """

  @behaviour Recollect.Learner.Harvest.Sink

  alias Recollect.Learner.Checkpoint
  alias Recollect.Learner.Harvest

  @impl true
  def push(records, opts) do
    project = opts[:project] || raise ArgumentError, "Sink.Mcp requires :project (the target scope)"

    with {:ok, key} <- require_key(opts) do
      node = opts[:node_id] || Checkpoint.node_id()

      {pushed, failures} =
        Enum.reduce(records, {0, []}, fn record, {ok, errs} ->
          args = %{
            "project" => project,
            "content" => record.content,
            "agent" => to_string(record.agent),
            "node_id" => node,
            "importance" => Harvest.importance(record.content),
            "tags" => record.tags
          }

          case stage(args, key, opts) do
            :ok -> {ok + 1, errs}
            {:error, reason} -> {ok, [reason | errs]}
          end
        end)

      case failures do
        [] -> {:ok, %{pushed: pushed}}
        errs -> {:error, %{pushed: pushed, failed: length(errs), errors: Enum.reverse(errs)}}
      end
    end
  end

  @doc "The MCP endpoint URL: explicit opt, env, or the default."
  def url(opts \\ []), do: opts[:url] || System.get_env("OPS_CENTER_MCP_URL") || @default_url

  @doc "The API key: explicit opt or env (OPS_CENTER_API_KEY / KFOS_API_KEY)."
  def api_key(opts \\ []) do
    opts[:api_key] || System.get_env("OPS_CENTER_API_KEY") || System.get_env("KFOS_API_KEY")
  end

  @doc "Stage one raw note via the `stage_memory` tool. Returns `:ok` or `{:error, reason}`."
  def stage(args, key, opts) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => "tools/call",
      "params" => %{"name" => "stage_memory", "arguments" => %{"input" => args}}
    }

    req =
      [url: url(opts), headers: headers(key), json: body, retry: :transient]
      |> Keyword.merge(opts[:req_options] || [])
      |> Req.new()

    case Req.post(req) do
      {:ok, %{status: 200, body: payload}} -> interpret(payload)
      {:ok, %{status: status, body: payload}} -> {:error, "HTTP #{status}: #{inspect(payload)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp headers(key) do
    [
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"authorization", "Bearer #{key}"}
    ]
  end

  # MCP returns 200 even for tool errors; check result.isError.
  defp interpret(%{"result" => %{"isError" => true} = result}), do: {:error, tool_text(result)}
  defp interpret(%{"error" => error}), do: {:error, inspect(error)}
  defp interpret(_), do: :ok

  defp tool_text(%{"content" => [%{"text" => t} | _]}), do: t
  defp tool_text(result), do: inspect(result)

  defp require_key(opts) do
    case api_key(opts) do
      nil -> {:error, "no API key — set OPS_CENTER_API_KEY (or pass :api_key)"}
      key -> {:ok, key}
    end
  end
end
