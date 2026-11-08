defmodule Recollect.Brief.Renderer do
  @moduledoc """
  Renders a built `Recollect.Brief` as `:markdown`, `:text`, or `:json`
  (MEM-019). Every item line carries its citation; section headers and the
  budget line are scaffolding covered by the budget reserve.
  """

  alias Recollect.Brief.Selector

  @formats [:markdown, :text, :json]

  @doc "Supported formats."
  def formats, do: @formats

  @doc """
  Render a built brief (a map with `:scope_label`, `:budget`, `:used`,
  `:truncated`, `:items`). When the budget was too small for any item, the
  text formats return an explicit empty string — never a partial sentence.
  """
  def render(format, brief)

  def render(format, _brief) when format not in @formats do
    raise ArgumentError, "unknown brief format #{inspect(format)} — expected one of #{inspect(@formats)}"
  end

  def render(:markdown, %{items: [], truncated: true}), do: ""

  def render(:markdown, brief) do
    header = "## Memory brief (workspace: #{brief.scope_label}, #{brief.used} / #{brief.budget} tokens)"

    body =
      brief.items
      |> group_by_section()
      |> Enum.map_join("\n\n", fn {section, items} ->
        "### #{title(section)}\n" <>
          Enum.map_join(items, "\n", fn item -> "- #{item_text(item)} #{citation(item)}" end)
      end)

    join_blocks([header, body])
  end

  def render(:text, %{items: [], truncated: true}), do: ""

  def render(:text, brief) do
    header = "Memory brief (workspace: #{brief.scope_label}, #{brief.used}/#{brief.budget} tokens)"

    body =
      brief.items
      |> group_by_section()
      |> Enum.map_join("\n\n", fn {section, items} ->
        "#{title(section)}:\n" <>
          Enum.map_join(items, "\n", fn item -> "- #{item_text(item)} #{citation(item)}" end)
      end)

    join_blocks([header, body])
  end

  def render(:json, brief) do
    Jason.encode!(%{
      scope: brief.scope_label,
      budget: brief.budget,
      used: brief.used,
      truncated: brief.truncated,
      sections:
        brief.items
        |> group_by_section()
        |> Enum.map(fn {section, items} ->
          %{
            key: section,
            title: title(section),
            items:
              Enum.map(items, fn item ->
                %{
                  id: item.id,
                  citation: item.citation,
                  text: item_text(item),
                  tokens: item.estimated_tokens,
                  verified_at: item[:meta][:verified_at]
                }
              end)
          }
        end)
    })
  end

  # Private

  defp group_by_section(items) do
    items
    |> Enum.group_by(& &1.section)
    |> Enum.sort_by(fn {section, _} -> section_order(section) end)
  end

  defp section_order(section), do: Enum.find_index(Selector.sections(), &(&1 == section))

  defp title(section), do: Map.get(Selector.section_titles(), section, to_string(section))

  defp item_text(item), do: item.text

  defp citation(%{citation: c, meta: %{verified_at: %DateTime{} = dt}}) do
    "[#{c}, verified #{dt |> DateTime.to_date() |> Date.to_iso8601()}]"
  end

  defp citation(%{citation: c}), do: "[#{c}]"

  defp join_blocks(blocks) do
    blocks |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
  end
end
