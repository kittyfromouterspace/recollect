defmodule Recollect.SleepTest do
  use Recollect.DataCase, async: false

  import Ecto.Query

  alias Recollect.Sleep
  alias Recollect.WorkingMemory

  setup do
    scope_id = Fixtures.scope_id()
    owner_id = Fixtures.owner_id()
    on_exit(fn -> WorkingMemory.clear(scope_id) end)
    %{scope_id: scope_id, owner_id: owner_id}
  end

  defp permanent_entries(scope_id) do
    Recollect.Config.repo().all(
      from(e in Recollect.Schema.Entry, where: e.scope_id == ^scope_id and e.entry_type != "archived")
    )
  end

  describe "promote/1 with the heuristic distiller" do
    test "promotes high-importance working memory into permanent memory and flushes", ctx do
      WorkingMemory.push(ctx.scope_id, "Always URL-encode the DB password slash as %2F.", importance: 0.9)
      WorkingMemory.push(ctx.scope_id, "hmm let me check that", importance: 0.0)

      assert {:ok, result} =
               Sleep.promote(
                 scope_id: ctx.scope_id,
                 owner_id: ctx.owner_id,
                 use_llm: false,
                 importance_threshold: 0.5
               )

      assert result.candidates == 2
      assert result.distilled == 1
      assert result.promoted == 1
      # both buffered notes are cleared, not just the promoted one
      assert result.flushed == 2

      entries = permanent_entries(ctx.scope_id)
      assert length(entries) == 1
      [entry] = entries
      assert entry.content =~ "URL-encode"
      assert entry.source == "system"
      assert entry.metadata["consolidated"] == true
      assert entry.metadata["origin"] == "sleep"

      # Working memory was flushed.
      assert {:ok, []} = WorkingMemory.read(ctx.scope_id)
    end

    test "dedups near-identical notes by text overlap", ctx do
      WorkingMemory.push(ctx.scope_id, "The fc-bridge IP is a pure function of the server ordinal", importance: 0.8)
      WorkingMemory.push(ctx.scope_id, "fc-bridge IP is a pure function of the server ordinal number", importance: 0.7)

      assert {:ok, result} =
               Sleep.promote(scope_id: ctx.scope_id, owner_id: ctx.owner_id, use_llm: false, merge_threshold: 0.5)

      assert result.candidates == 2
      assert result.distilled == 1
      assert result.promoted == 1
    end

    test "dry_run distills without writing or flushing", ctx do
      WorkingMemory.push(ctx.scope_id, "A durable lesson worth keeping.", importance: 1.0)

      assert {:ok, result} =
               Sleep.promote(scope_id: ctx.scope_id, owner_id: ctx.owner_id, use_llm: false, dry_run: true)

      assert result.distilled == 1
      assert result.promoted == 0
      assert result.flushed == 0
      assert permanent_entries(ctx.scope_id) == []
      assert {:ok, [_]} = WorkingMemory.read(ctx.scope_id)
    end

    test "empty working memory is a no-op", ctx do
      assert {:ok, %{candidates: 0, distilled: 0, promoted: 0, flushed: 0}} =
               Sleep.promote(scope_id: ctx.scope_id, owner_id: ctx.owner_id, use_llm: false)
    end
  end

  describe "promote/1 with a custom distiller" do
    test "uses the supplied distiller and persists its output", ctx do
      WorkingMemory.push(ctx.scope_id, "raw note one", importance: 0.1)
      WorkingMemory.push(ctx.scope_id, "raw note two", importance: 0.1)

      distiller = fn candidates, _opts ->
        [%{content: "distilled summary of #{length(candidates)} notes", tags: ["summary"]}]
      end

      assert {:ok, result} =
               Sleep.promote(scope_id: ctx.scope_id, owner_id: ctx.owner_id, distiller: distiller)

      assert result.distilled == 1
      assert result.promoted == 1

      [entry] = permanent_entries(ctx.scope_id)
      assert entry.content == "distilled summary of 2 notes"
    end
  end

  describe "distill/2 LLM path" do
    test "parses a fenced JSON array from the llm_fn", ctx do
      WorkingMemory.push(ctx.scope_id, "noise", importance: 0.0)

      llm_fn = fn _messages, _opts ->
        {:ok, ~s(```json\n[{"content": "keep this durable fact", "tags": ["x"]}]\n```)}
      end

      put_extraction_llm(llm_fn)

      items = Sleep.distill(elem(WorkingMemory.read(ctx.scope_id), 1), [])
      assert [%{content: "keep this durable fact", tags: ["x"]}] = items
    end

    test "falls back to heuristic when the llm_fn errors", ctx do
      WorkingMemory.push(ctx.scope_id, "durable fact", importance: 0.9)

      put_extraction_llm(fn _m, _o -> {:error, :boom} end)

      items = Sleep.distill(elem(WorkingMemory.read(ctx.scope_id), 1), importance_threshold: 0.5)
      assert [%{content: "durable fact"}] = items
    end
  end

  defp put_extraction_llm(llm_fn) do
    prev = Application.get_env(:recollect, :extraction)
    Application.put_env(:recollect, :extraction, provider: Recollect.Extraction.LlmJson, llm_fn: llm_fn)
    on_exit(fn -> Application.put_env(:recollect, :extraction, prev) end)
  end

  # Ensure permanent writes don't try to embed (no provider in test env).
  setup do
    prev = Application.get_env(:recollect, :embedding)
    Application.put_env(:recollect, :embedding, provider: nil)
    on_exit(fn -> Application.put_env(:recollect, :embedding, prev) end)
    :ok
  end
end
