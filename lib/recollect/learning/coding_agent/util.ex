defmodule Recollect.Learner.CodingAgent.Util do
  @moduledoc false

  @doc false
  def parse_frontmatter(content) do
    case String.split(content, "---", parts: 3) do
      ["", yaml_str, body] ->
        frontmatter =
          yaml_str
          |> String.trim()
          |> String.split("\n")
          |> Enum.map(&parse_yaml_line/1)
          |> Enum.reject(&is_nil/1)
          |> Map.new()

        {frontmatter, String.trim(body)}

      _ ->
        {%{}, String.trim(content)}
    end
  end

  defp parse_yaml_line(line) do
    case Regex.run(~r/^(\w[\w\s]*):\s*(.+)$/, String.trim(line)) do
      [_, key, value] ->
        {String.trim(key), unquote_yaml(value)}

      _ ->
        nil
    end
  end

  defp unquote_yaml(value) do
    v = String.trim(value)

    cond do
      String.starts_with?(v, "\"") and String.ends_with?(v, "\"") ->
        String.slice(v, 1..-2//1)

      String.starts_with?(v, "'") and String.ends_with?(v, "'") ->
        String.slice(v, 1..-2//1)

      true ->
        v
    end
  end

  @doc false
  def expand(path), do: Path.expand(path)

  @doc false
  def dir_exists?(path), do: File.dir?(expand(path))

  @doc false
  def read_file(path, max_bytes \\ 8000) do
    case File.read(path) do
      {:ok, content} -> {:ok, String.slice(content, 0, max_bytes)}
      error -> error
    end
  end

  @doc false
  def short_id(id) when is_binary(id) and byte_size(id) > 8, do: String.slice(id, 0, 8)
  def short_id(id), do: id

  @doc false
  def project_tag(project) when is_binary(project) do
    display =
      project
      |> String.trim_leading("-")
      |> String.replace("-", "/")
      |> String.replace_prefix("/", "")

    "project:#{display}"
  end

  @doc false
  def project_tag(_), do: "project:unknown"

  @doc false
  def extract_jsonl_lines(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode/1)
    |> Enum.flat_map(fn
      {:ok, obj} -> [obj]
      _ -> []
    end)
  end

  @doc false
  def extract_user_text_from_json(obj) do
    type = Map.get(obj, "type")

    if type == "user" and not Map.get(obj, "isMeta", false) do
      msg = Map.get(obj, "message", %{})
      content = Map.get(msg, "content", "")
      pull_user_text(content)
    else
      []
    end
  end

  defp pull_user_text(content) when is_binary(content) do
    case Regex.run(~r/<user_prompt>\s*(.*?)\s*<\/user_prompt>/s, content) do
      [_, prompt] ->
        cleaned =
          prompt
          |> String.replace(~r/\[.*?\]\(.*?\)/, "")
          |> String.trim()

        if cleaned != "" and String.length(cleaned) > 10, do: [cleaned], else: []

      _ ->
        []
    end
  end

  defp pull_user_text(content) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "text", "text" => text} -> pull_user_text(text)
      _ -> []
    end)
  end

  defp pull_user_text(_), do: []

  @doc false
  def resolve_paths(%{data_paths: [_ | _] = paths}), do: paths
  def resolve_paths(_), do: []

  @doc false
  def file_newer_than?(_path, nil), do: true

  def file_newer_than?(path, since_str) when is_binary(since_str) do
    case DateTime.from_iso8601(since_str) do
      {:ok, since_dt, _} -> file_newer_than?(path, since_dt)
      _ -> true
    end
  end

  def file_newer_than?(path, %DateTime{} = since_dt) do
    case File.stat(path) do
      {:ok, stat} ->
        file_dt = mtime_to_datetime(stat.mtime)
        DateTime.after?(file_dt, since_dt)

      _ ->
        true
    end
  end

  @doc """
  Normalize a `since` value to a UTC DateTime.

  Accepts a DateTime (passed through), an ISO8601 string, or a relative
  string like "7 days ago" / "30 minutes ago" (MEM-012). Returns nil for
  nil or anything unparseable — callers treat nil as "no time filter".
  """
  def parse_since(nil), do: nil
  def parse_since(%DateTime{} = dt), do: dt

  def parse_since(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} ->
        dt

      _ ->
        parse_relative_since(str)
    end
  end

  defp parse_relative_since(str) do
    case Regex.run(~r/^\s*(\d+)\s+(second|minute|hour|day|week|month)s?\s+ago\s*$/i, str) do
      [_, amount, unit] ->
        seconds =
          case String.downcase(unit) do
            "second" -> 1
            "minute" -> 60
            "hour" -> 3600
            "day" -> 86_400
            "week" -> 604_800
            "month" -> 2_592_000
          end

        DateTime.add(DateTime.utc_now(), -String.to_integer(amount) * seconds, :second)

      _ ->
        nil
    end
  end

  @doc false
  def mtime_to_datetime({{y, m, d}, {h, min, s}}) do
    {:ok, ndt} = NaiveDateTime.new(y, m, d, h, min, s)
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  def mtime_to_datetime(unix) when is_integer(unix), do: DateTime.from_unix!(unix)
  def mtime_to_datetime(_), do: DateTime.utc_now()
end
