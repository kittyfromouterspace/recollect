defmodule Recollect.SchemaFit do
  @moduledoc """
  Schema fit computation for new entries.

  Computes how well new content fits existing knowledge patterns.
  Familiar memories consolidate faster; novel ones decay faster if unused.

  Split in two (MEM-006):

    * `compute_tag_fit/2` — cheap ETS lookup over the scope's tag-frequency
      index; runs synchronously on the write path.
    * `compute_content_fit/2` — tokenizes a SAMPLE of recent entries
      (`config :recollect, schema_fit: [content_sample_size: 50]`); too
      expensive for the synchronous write path at scale, so `remember/2`
      refines the stored `schema_fit` asynchronously via
      `refine_content_fit/3`.

  `compute/3` remains as the synchronous combined score for callers that
  can afford it.
  """

  alias Recollect.Schema.Entry
  alias Recollect.SchemaIndex

  require Logger

  @doc """
  Compute schema fit score for new content. Returns 0.0..1.0.
  """
  def compute(content, tags, scope_id) when is_binary(content) do
    if index_size(scope_id) == 0 do
      0.5
    else
      0.6 * compute_tag_fit(tags, scope_id) + 0.4 * compute_content_fit(content, scope_id)
    end
  end

  def compute(_content, _tags, _scope_id), do: 0.5

  @doc """
  Cheap synchronous tag fit: how familiar are these tags within the scope?
  Pure ETS reads — safe on the write path.
  """
  def compute_tag_fit(tags, scope_id) when is_list(tags) do
    tag_freq = SchemaIndex.tag_frequency(scope_id)
    n = SchemaIndex.entry_count(scope_id)

    compute_tag_fit_from_index(tags, tag_freq, n)
  end

  def compute_tag_fit(_tags, _scope_id), do: 0.5

  @doc """
  Content fit against a bounded sample of the scope's recent entries.
  """
  def compute_content_fit(content, scope_id) when is_binary(content) do
    new_tokens = Recollect.Util.tokenize(content)

    if Enum.empty?(new_tokens) do
      0.5
    else
      sample = sample_scope_contents(scope_id)

      case sample do
        [] ->
          0.5

        entries ->
          matches =
            Enum.count(entries, fn entry_content ->
              entry_tokens = Recollect.Util.tokenize(entry_content)
              Recollect.Util.jaccard(new_tokens, entry_tokens) > 0.2
            end)

          m = length(entries)
          min(1.0, matches / max(5, m * 0.1))
      end
    end
  end

  def compute_content_fit(_content, _scope_id), do: 0.5

  @doc """
  Recompute the combined fit for an already-stored entry and update its
  `schema_fit` column. Intended to run off the write path.
  """
  def refine_content_fit(entry_id, content, scope_id) do
    import Ecto.Query

    tag_score = compute_tag_fit(current_tags(entry_id), scope_id)
    content_score = compute_content_fit(content, scope_id)

    combined = 0.6 * tag_score + 0.4 * content_score

    Recollect.Config.repo().update_all(
      from(e in Entry, where: e.id == ^entry_id),
      set: [schema_fit: combined]
    )

    :ok
  rescue
    e ->
      Logger.debug("Recollect.SchemaFit: async refine failed for #{entry_id}: #{Exception.message(e)}")
      :ok
  end

  @doc "Fire-and-forget refinement for the remember path."
  def refine_content_fit_async(entry_id, content, scope_id) do
    Task.Supervisor.start_child(
      Recollect.Config.task_supervisor(),
      fn -> refine_content_fit(entry_id, content, scope_id) end,
      restart: :temporary
    )

    :ok
  rescue
    _ -> :ok
  end

  defp index_size(scope_id), do: SchemaIndex.entry_count(scope_id)

  defp current_tags(entry_id) do
    Recollect.Knowledge.tags(entry_id)
  rescue
    _ -> []
  end

  defp sample_scope_contents(scope_id) do
    import Ecto.Query

    sample_size = content_sample_size()

    Recollect.Config.repo().all(
      from(e in Entry,
        where: e.scope_id == ^scope_id and e.entry_type != "archived",
        order_by: [desc: e.inserted_at],
        limit: ^sample_size,
        select: e.content
      )
    )
  rescue
    _ -> []
  end

  defp content_sample_size do
    :recollect
    |> Application.get_env(:schema_fit, [])
    |> case do
      opts when is_list(opts) -> Keyword.get(opts, :content_sample_size, 50)
      _ -> 50
    end
  end

  defp compute_tag_fit_from_index(tags, tag_freq, n) when is_list(tags) do
    if Enum.empty?(tags) or n == 0 do
      0.5
    else
      weighted_overlap =
        Enum.reduce(tags, 0, fn tag, acc ->
          freq = Map.get(tag_freq, tag, 0)

          if freq > 0 do
            idf = :math.log(n / freq) + 1
            acc + idf
          else
            acc
          end
        end)

      max_idf = :math.log(n + 1) + 1
      total_weight = length(tags) * max_idf

      if total_weight > 0 do
        min(1.0, weighted_overlap / total_weight * 2)
      else
        0.0
      end
    end
  end

  defp compute_tag_fit_from_index(_tags, _tag_freq, _n), do: 0.5
end
