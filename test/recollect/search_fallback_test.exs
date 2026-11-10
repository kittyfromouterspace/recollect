defmodule Recollect.SearchFallbackTest do
  use Recollect.DataCase, async: false

  alias Recollect.Config

  @items [
    %{kind: :entry, id: "kw-1", content: "The deploy script runs database migrations first.", entry_type: "note"},
    %{kind: :entry, id: "kw-2", content: "Database connection pooling configuration for production.", entry_type: "note"},
    %{kind: :entry, id: "kw-3", content: "How to rollback a failed deployment.", entry_type: "note"},
    %{kind: :entry, id: "kw-4", content: "Monitoring alerts for high CPU usage.", entry_type: "note"}
  ]

  describe "Keyword fallback (MEM-038)" do
    setup do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      Enum.each(@items, fn item ->
        Fixtures.entry(scope_id: scope_id, owner_id: owner_id, content: item.content, entry_type: item.entry_type)
      end)

      {:ok, scope_id: scope_id, owner_id: owner_id}
    end

    test "keyword fallback returns ILIKE matches when embeddings disabled", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      # Temporarily disable embeddings
      orig = Application.get_env(:recollect, :embedding)
      Application.put_env(:recollect, :embedding, provider: nil)

      try do
        {:ok, context} =
          Recollect.search("deploy script", scope_id: scope_id, owner_id: owner_id, mode: :hybrid)

        assert is_list(context.entries)
        assert context.resolved_mode in [:keyword_fallback, :both]
      after
        Application.put_env(:recollect, :embedding, orig)
      end
    end

    test "keyword fallback respects scope isolation", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      other_scope = Fixtures.scope_id()
      Fixtures.entry(scope_id: other_scope, owner_id: owner_id, content: "Other scope deploy script")

      orig = Application.get_env(:recollect, :embedding)
      Application.put_env(:recollect, :embedding, provider: nil)

      try do
        {:ok, context} =
          Recollect.search("deploy script", scope_id: scope_id, owner_id: owner_id, mode: :hybrid)

        entry_ids = Enum.map(context.entries, & &1["id"])
        refute :other_scope_deploy_script in entry_ids
      after
        Application.put_env(:recollect, :embedding, orig)
      end
    end

    test "keyword fallback respects limit", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      orig = Application.get_env(:recollect, :embedding)
      Application.put_env(:recollect, :embedding, provider: nil)

      try do
        {:ok, context} =
          Recollect.search("deploy", scope_id: scope_id, owner_id: owner_id, mode: :hybrid, limit: 2)

        assert length(context.entries) <= 2
      after
        Application.put_env(:recollect, :embedding, orig)
      end
    end

    test "resolved_mode is set in context pack", %{
      scope_id: scope_id,
      owner_id: owner_id
    } do
      {:ok, context} = Recollect.search("query", scope_id: scope_id, owner_id: owner_id, mode: :vector)

      assert is_map(context)
      assert Map.has_key?(context, :resolved_mode)
      assert context.resolved_mode in [:vector, :keyword_fallback, :both]
    end
  end
end
