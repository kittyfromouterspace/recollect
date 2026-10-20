# Recollect

Pluggable memory engine for Elixir applications. Provides document ingestion with markdown-aware chunking, configurable vector embeddings, LLM-powered entity/relation extraction, knowledge graph storage, hybrid search, working memory, session handoff, and memory lifecycle management (decay, consolidation, invalidation).

## Inspiration

Recollect builds on research from [MemPalace](https://github.com/milla-jovovich/mempalace), [HIPPO Memory](https://github.com/kitfunso/hippo-memory) and [Cognee](https://docs.cognee.ai) among others.

## Architecture

Recollect provides three tiers that can be used independently or together:

```
+------------------------------------------------------------------+
| Tier 0: Working Memory                                            |
|                                                                  |
| Session-scoped bounded buffer. No embeddings.                     |
| Importance-based eviction. Integrates with Handoff for session    |
| continuity.                                                       |
+------------------------------------------------------------------+
| Tier 1: Full Pipeline                                            |
|                                                                  |
| Collection -> Document -> Chunk -> Entity -> Relation             |
|                                                                  |
| Markdown-aware chunking, content-hash dedup, LLM entity          |
| extraction, pipeline tracking, graph traversal                   |
+------------------------------------------------------------------+
| Tier 2: Lightweight Knowledge                                     |
|                                                                  |
| Entry + Edge                                                      |
|                                                                  |
| Simple store-embed-search with access tracking, confidence       |
| scoring, supersession, and decay                                 |
+------------------------------------------------------------------+
| Shared: Search (Vector + Graph + Hybrid), Context Formatting     |
| Shared: Configurable Embedding (Local, OpenRouter)               |
| Shared: Maintenance (Decay, Reembed, Consolidation, Invalidation)|
| Shared: Telemetry, Export/Import, Learning                        |
+------------------------------------------------------------------+
```

## Integration Guide

### Step 1: Add Dependency

```elixir
# mix.exs
defp deps do
  [
    {:recollect, github: "kittyfromouterspace/recollect"}
    # or for local development:
    # {:recollect, path: "../recollect"}
  ]
end
```

Run `mix deps.get`.

### Step 2: Generate Migration

```bash
mix recollect.gen.migration --dimensions 384
```

Options:

- `--dimensions` — Embedding vector dimensions (default: 384). Must match your embedding model:
  - `384` for Local (all-MiniLM-L6-v2, default)
  - `1536` for OpenRouter with OpenAI text-embedding-3-small

This creates a migration in `priv/repo/migrations/` with all Recollect tables. Then:

```bash
mix ecto.migrate
```

### Step 3: Configure

Add to your `config/config.exs` (or `runtime.exs` for production):

```elixir
config :recollect,
  repo: MyApp.Repo,
  embedding: [
    provider: Recollect.Embedding.OpenRouter,
    credentials_fn: fn ->
      # Fetch API key from YOUR secret system at runtime
      # Return a map with :api_key + optional :model, :dimensions, :base_url
      # Return :disabled if no credentials available
      %{
        api_key: System.get_env("OPENROUTER_API_KEY"),
        model: "openai/text-embedding-3-small",
        dimensions: 1536
      }
    end
  ],
  extraction: [
    provider: Recollect.Extraction.LlmJson,
    llm_fn: fn messages, _opts ->
      # YOUR LLM call function — takes messages list, returns {:ok, text}
      # This is how Recollect calls your LLM for entity extraction
      MyApp.LLM.chat(messages)
    end
  ]
```

If no embedding provider is configured, Recollect uses `Recollect.Embedding.Local` (Bumblebee) by default, which requires no API keys and runs entirely on-device.

#### Database Adapters

Recollect supports multiple database backends via the `:database_adapter` config:

```elixir
# PostgreSQL with pgvector (default)
config :recollect, :database_adapter, Recollect.DatabaseAdapter.Postgres

# SQLite3 with sqlite-vec
config :recollect, :database_adapter, Recollect.DatabaseAdapter.SQLiteVec

# libSQL (SQLite with native vector support)
config :recollect, :database_adapter, Recollect.DatabaseAdapter.LibSQL
```

#### Credential Resolution

Recollect never stores API keys. Instead, you provide a `:credentials_fn` that fetches credentials from your app's secret system at runtime. Examples:

```elixir
# Simple: environment variable
credentials_fn: fn ->
  case System.get_env("OPENROUTER_API_KEY") do
    nil -> :disabled
    key -> %{api_key: key, model: "openai/text-embedding-3-small", dimensions: 1536}
  end
end

# Phoenix app with encrypted DB secrets
credentials_fn: fn ->
  case MyApp.Secrets.get_api_key("openrouter") do
    {:ok, key} -> %{api_key: key, model: "openai/text-embedding-3-small", dimensions: 1536}
    _ -> :disabled
  end
end

# Ash-based credential store
credentials_fn: fn ->
  case MyApp.Admin.LlmCredential.active_for_provider(:openrouter, authorize?: false) do
    {:ok, cred} -> %{api_key: cred.api_key, model: "openai/text-embedding-3-small", dimensions: 1536}
    _ -> :disabled
  end
end
```

### Step 4: Use

#### Tier 0 — Working Memory (session-scoped)

A bounded buffer for current-session notes. No embeddings, no persistence. Integrates with Handoff for session continuity.

```elixir
# Push notes into working memory
Recollect.WorkingMemory.push(scope_id, "User prefers dark mode",
  importance: 0.9
)

# Read all notes for a scope (sorted by importance DESC)
{:ok, notes} = Recollect.WorkingMemory.read(scope_id)

# Load previous session's handoff into working memory
Recollect.WorkingMemory.load_handoff(scope_id)

# Clear at end of session
Recollect.WorkingMemory.flush(scope_id)
```

#### Tier 2 — Lightweight Knowledge (simplest persistent)

Store and search knowledge entries:

```elixir
# Store a fact (auto-embeds in background)
{:ok, entry} = Recollect.Knowledge.remember("Deploy script is at scripts/deploy.sh",
  scope_id: workspace_id,
  owner_id: user_id,
  entry_type: "note"
)

# Search by semantic similarity
{:ok, results} = Recollect.Search.search("how to deploy",
  scope_id: workspace_id,
  tier: :lightweight
)

# Format results for LLM system prompt
context_text = Recollect.Search.ContextFormatter.format(results)

# Connect related entries
Recollect.Knowledge.connect(entry1.id, entry2.id, "supports", weight: 0.8)

# Delete
Recollect.Knowledge.forget(entry.id)
```

Entry types: `outcome`, `event`, `decision`, `observation`, `hypothesis`, `note`, `session_summary`, `conversation_turn`, `preference`, `milestone`, `problem`, `emotional`, `archived`.

```elixir
# Auto-classify content using LLM-free pattern matching (inspired by MemPalace)
{:ok, entry} = Recollect.Knowledge.remember("We decided to use PostgreSQL for its JSON support",
  scope_id: workspace_id,
  owner_id: user_id,
  auto_classify: true  # Detects :decision type automatically
)

# Check for contradictions against existing knowledge
case Recollect.Knowledge.check_contradiction(content, scope_id, owner_id) do
  :ok -> IO.puts("No conflicts")
  {:conflict, conflicts} -> IO.puts("Conflicts detected!")
end
```

#### Tier 1 — Full Pipeline (for documents)

Ingest documents with chunking, embedding, and entity extraction:

```elixir
# Ingest a document (deduplicates by content hash)
{:ok, doc} = Recollect.Pipeline.Ingester.ingest("Meeting Notes", markdown_content,
  owner_id: user_id,
  scope_id: workspace_id,
  source_type: "artifact",
  source_id: "meeting-2024-01-15"
)

# Run the full pipeline: chunk -> embed -> extract entities -> embed entities
{:ok, run} = Recollect.Pipeline.process(doc)
# run.status => "complete"
# run.step_details => %{chunks_created: 12, entities_extracted: 8, ...}

# Or run async (fire and forget)
Recollect.Pipeline.process_async(doc)

# Re-ingesting unchanged content returns :unchanged (no wasted API calls)
{:ok, :unchanged} = Recollect.Pipeline.Ingester.ingest("Meeting Notes", markdown_content,
  owner_id: user_id, scope_id: workspace_id,
  source_type: "artifact", source_id: "meeting-2024-01-15"
)
```

#### Hybrid Search (both tiers)

```elixir
# Search across chunks AND entries
{:ok, context_pack} = Recollect.Search.search("project timeline",
  owner_id: user_id,
  scope_id: workspace_id,
  limit: 10,
  hops: 1  # graph expansion depth (default: 1)
)

# context_pack contains:
# %{
#   chunks: [...],         # Tier 1 chunk results with similarity scores
#   entries: [...],        # Tier 2 entry results with similarity scores
#   related_entries: [...], # Entries found via edge traversal
#   entities: [...],       # Extracted entities from knowledge graph
#   relations: [...],      # Graph relations between entities
#   query: "project timeline"
# }

# Format for LLM consumption
context_text = Recollect.Search.ContextFormatter.format(context_pack)

# Search with filters (inspired by MemPalace's wing/room filtering)
{:ok, results} = Recollect.Search.search("deployment",
  scope_id: workspace_id,
  tier: :lightweight,
  filters: %{
    entry_type: :decision,      # Only decision-type entries
    temporal: :recent,          # Last 30 days only
    confidence_min: 0.5         # Minimum confidence
  }
)
```

#### LLM-Augmented Completion

Combine search with LLM reasoning for question-answering over memory:

```elixir
{:ok, result} = Recollect.Search.Completion.complete(
  "What was decided about auth?",
  owner_id: user_id,
  scope_id: workspace_id,
  llm_fn: fn messages -> MyApp.LLM.chat(messages) end
)
# => {:ok, %{answer: "You decided to use JWT...", context: context_pack}}
```

#### Session Handoff

Store and retrieve session context for continuity across sessions:

```elixir
# At end of session
Recollect.Handoff.create(scope_id,
  what: "Implementing user auth",
  next: ["Add login controller", "Create session middleware"],
  artifacts: ["lib/auth/user.ex", "lib/auth/token.ex"],
  blockers: ["Waiting on API spec"]
)

# At start of next session
{:ok, handoff} = Recollect.Handoff.get(scope_id)

# Or auto-load into working memory
Recollect.WorkingMemory.load_handoff(scope_id)

# Clean up old handoffs
Recollect.Handoff.cleanup(scope_id, keep: 5)
```

#### Outcome Feedback

Close the learning loop by signaling whether recalled memories were helpful:

```elixir
# After search + using results
Recollect.Outcome.good(scope_id)   # Strengthens last-retrieved entries
Recollect.Outcome.bad(scope_id)    # Weakens last-retrieved entries

# Apply to specific entries
Recollect.Outcome.apply([entry_id_1, entry_id_2], :good)
```

#### Maintenance

```elixir
# Archive stale entries (entries not accessed in 90 days with < 3 accesses)
{:ok, archived_count} = Recollect.Maintenance.Decay.run()
{:ok, archived_count} = Recollect.Maintenance.Decay.run(max_age_days: 60, min_access_count: 5)

# Re-embed entries/chunks with nil embeddings (after model change)
{:ok, count} = Recollect.Maintenance.Reembed.run()
{:ok, count} = Recollect.Maintenance.Reembed.run(batch_size: 50, concurrency: 4)

# Sleep consolidation: decay + merge overlapping + detect conflicts
{:ok, result} = Recollect.Consolidation.run(scope_id: workspace_id)
{:ok, preview} = Recollect.Consolidation.dry_run(scope_id: workspace_id)

# Invalidation: weaken memories about deprecated patterns
{:ok, result} = Recollect.Invalidation.run_from_git(scope_id: workspace_id)
Recollect.Invalidation.invalidate(scope_id, "webpack", reason: "migrated to vite")
```

#### Export / Import

```elixir
# Export all data to JSONL
{:ok, result} = Recollect.Export.export_all("/path/to/backup.jsonl")

# Export specific table
{:ok, result} = Recollect.Export.export_table(:recollect_entries, "/path/to/entries.jsonl")

# Import from JSONL
{:ok, result} = Recollect.Import.import_all("/path/to/backup.jsonl")

# Validate without importing
{:ok, meta} = Recollect.Import.validate("/path/to/backup.jsonl")
```

#### Learning

Recollect can automatically learn from external sources like git history and coding agent conversations:

```elixir
# Run all learning sources
{:ok, result} = Recollect.Learning.Pipeline.run(scope_id: workspace_id)

# Run specific sources only
{:ok, result} = Recollect.Learning.Pipeline.run(scope_id: workspace_id, sources: [Recollect.Learner.Git])

# Dry run - preview what would be learned
{:ok, preview} = Recollect.Learning.Pipeline.run(scope_id: workspace_id, dry_run: true)

# Run individual learners
{:ok, git_result} = Recollect.Learner.Git.run(scope_id: workspace_id)
{:ok, claude_result} = Recollect.Learner.ClaudeCode.run(scope_id: workspace_id)
{:ok, opencode_result} = Recollect.Learner.OpenCode.run(scope_id: workspace_id)
```

##### Available Learners

| Learner | Source | Detects |
|---------|--------|---------|
| `Recollect.Learner.Git` | Git history | Bug fixes, features, migrations, breaking changes |
| `Recollect.Learner.ClaudeCode` | Claude Code projects | Decisions, code implementations, errors |
| `Recollect.Learner.OpenCode` | OpenCode sessions | Decisions, implementations, project context |

##### Harvest (bulk transcript import with consent + checkpoints)

`Recollect.Learner.Harvest` is the shared bulk-import pipeline on top of the
coding-agent learners: project-slug mapping (`ProjectMapping`), per-agent
consent (`Consent`), per-machine incremental cursors (`Checkpoint`), and
pluggable sinks — `:dry_run`, `:collect`, `Sink.Jsonl` (transport file),
`Sink.Mcp` (push to a memory server's `stage_memory` tool), or a host-app
store sink:

```sh
mix recollect.harvest --consent-status            # who may be read
mix recollect.harvest --grant claude_code         # per-machine consent
mix recollect.harvest --project mark_mesh         # dry-run preview
mix recollect.harvest --project mark_mesh --sink jsonl --out notes.jsonl
OPS_CENTER_API_KEY=sk-… mix recollect.harvest --project mark_mesh --sink mcp
```

##### Custom Learners

Implement the `Recollect.Learner` behaviour to add your own sources:

```elixir
defmodule MyApp.Learner.CI do
  @behaviour Recollect.Learner

  @impl true
  def source, do: :ci

  @impl true
  def fetch_since(since, scope_id) do
    # Fetch CI failures since the given date
  end

  @impl true
  def extract(event) do
    {:ok, %{
      content: "CI Failure: #{event.failure_message}",
      entry_type: :observation,
      emotional_valence: :negative,
      tags: ["ci", "failure"],
      metadata: %{source: :ci, job_id: event.id}
    }}
  end

  @impl true
  def detect_patterns(events), do: []
end
```

Then add to your config:

```elixir
config :recollect,
  learning: [
    enabled: true,
    sources: [Recollect.Learner.Git, Recollect.Learner.ClaudeCode, MyApp.Learner.CI]
  ]
```

## Configuration Reference

```elixir
config :recollect,
  # Required: your Ecto repo
  repo: MyApp.Repo,

  # Database adapter (default: Postgres)
  database_adapter: Recollect.DatabaseAdapter.Postgres,

  # Embedding configuration (default: Local with Bumblebee)
  embedding: [
    # Provider module
    provider: Recollect.Embedding.OpenRouter,  # or Local

    # Runtime credential resolver (for API-based providers)
    credentials_fn: fn -> %{api_key: "...", model: "...", dimensions: 1536} end,

    # OR static config (simpler but less secure)
    api_key: "sk-...",
    model: "openai/text-embedding-3-small",
    dimensions: 1536
  ],

  # LLM extraction configuration (required for Tier 1 pipeline)
  extraction: [
    provider: Recollect.Extraction.LlmJson,  # default
    llm_fn: fn messages, opts -> {:ok, "response text"} end
  ],

  # Optional
  task_supervisor: MyApp.TaskSupervisor,  # default: Recollect.TaskSupervisor
  graph_store: Recollect.Graph.PostgresGraph,  # default, swap for custom impl
  table_prefix: "recollect_"                   # default

  # Learning configuration (optional)
  learning: [
    enabled: true,
    sources: [Recollect.Learner.Git, Recollect.Learner.ClaudeCode, Recollect.Learner.OpenCode]
  ]
```

## Embedding Providers

| Provider | Module | Default Model | Dimensions | Notes |
|----------|--------|---------------|------------|-------|
| Local | `Recollect.Embedding.Local` | `all-MiniLM-L6-v2` | 384 | Default. No API key needed. Requires `:bumblebee` dep. |
| OpenRouter | `Recollect.Embedding.OpenRouter` | `openai/text-embedding-3-small` | 1536 | Best for hosted apps. Supports Google/OpenAI models via OpenRouter. |

### Using Local Embeddings (default)

No API key needed. Just add the Bumblebee dependency to your `mix.exs`:

```elixir
defp deps do
  [
    {:recollect, github: "kittyfromouterspace/recollect"},
    {:bumblebee, "~> 0.6.0"}
  ]
end
```

Model weights are downloaded from HuggingFace Hub on first use and cached on disk.

## Schema Overview

### Tier 1: Full Pipeline

| Table | Purpose | Key Fields |
|-------|---------|------------|
| `recollect_collections` | Groups documents | name, collection_type, owner_id, scope_id |
| `recollect_documents` | Source content + dedup hash | title, content, content_hash, status, source_type |
| `recollect_chunks` | Embedded text fragments | content, embedding, sequence, heading context |
| `recollect_entities` | Extracted knowledge nodes | name, entity_type (10 types), mention_count, embedding |
| `recollect_relations` | Graph edges between entities | relation_type (8 types), weight, from/to entity |
| `recollect_pipeline_runs` | Pipeline execution tracking | status lifecycle, step_details, cost, timing |

Entity types: `concept`, `person`, `goal`, `obstacle`, `domain`, `strategy`, `emotion`, `place`, `event`, `tool`.

Relation types: `supports`, `blocks`, `causes`, `relates_to`, `part_of`, `depends_on`, `precedes`, `contradicts`.

### Tier 2: Lightweight Knowledge

| Table | Purpose | Key Fields |
|-------|---------|------------|
| `recollect_entries` | Knowledge entries | content, entry_type, embedding, confidence, half_life_days, access_count |
| `recollect_edges` | Lightweight edges | relation (6 types), weight, source/target entry |

Edge relation types: `leads_to`, `supports`, `contradicts`, `derived_from`, `supersedes`, `related_to`.

### Session & Lifecycle

| Table | Purpose | Key Fields |
|-------|---------|------------|
| `recollect_handoffs` | Session handoff data | what, next, artifacts, blockers |
| `recollect_consolidation_runs` | Consolidation pass records | decayed, merged, conflicts_detected |
| `recollect_mipmaps` | Progressive detail levels | level (anchor/abstract/summary/full), embedding |
| `recollect_conflicts` | Detected memory conflicts | conflicting entries, conflict type |

### Dual Identifiers

All schemas carry both `owner_id` and `scope_id`:

- **`owner_id`** — The user who owns the data. Used for cross-scope queries ("everything this user knows").
- **`scope_id`** — The workspace/project/collection scope. Used for scoped queries ("everything in this workspace").

Both are UUID columns. Your app decides what they map to.

## Behaviours (Extension Points)

### `Recollect.EmbeddingProvider`

Implement to add a new embedding backend:

```elixir
defmodule MyApp.CustomEmbedding do
  @behaviour Recollect.EmbeddingProvider

  @impl true
  def dimensions(_opts), do: 768

  @impl true
  def generate(texts, opts) do
    # Return {:ok, [[float()]]} or {:error, reason}
  end

  @impl true
  def embed(text, opts) do
    # Optional — defaults to calling generate/2 with a single text
  end

  @impl true
  def model_id(opts) do
    # Optional — returns model identifier for provenance tracking
    "my-model/v1"
  end
end
```

### `Recollect.ExtractionProvider`

Implement to customize entity/relation extraction:

```elixir
defmodule MyApp.CustomExtraction do
  @behaviour Recollect.ExtractionProvider

  @impl true
  def extract(text, opts) do
    # Return {:ok, %{entities: [...], relations: [...]}} or {:error, reason}
  end
end
```

### `Recollect.GraphStore`

Implement to swap the graph backend (default: PostgreSQL recursive CTEs):

```elixir
defmodule MyApp.Neo4jGraph do
  @behaviour Recollect.GraphStore

  @impl true
  def get_neighbors(owner_id, entity_id, hops) do
    # Return {:ok, [entity]} or {:error, reason}
  end

  @impl true
  def get_relations(owner_id, entity_id) do
    # Return {:ok, [relation]} or {:error, reason}
  end
end
```

### `Recollect.DatabaseAdapter`

Implement to add a new database backend:

```elixir
defmodule MyApp.CustomAdapter do
  @behaviour Recollect.DatabaseAdapter

  @impl true
  def vector_type(dimensions), do: "vector(#{dimensions})"

  @impl true
  def vector_ecto_type, do: :string

  @impl true
  def format_embedding(list), do: "[#{Enum.join(list, ",")}]"

  # ... see Recollect.DatabaseAdapter for all callbacks
end
```

## Telemetry

Recollect emits `:telemetry` events for all major operations. Attach handlers to monitor performance:

| Event | Description |
|-------|-------------|
| `[:recollect, :remember, :start/:stop/:exception]` | Entry creation |
| `[:recollect, :search, :start/:stop/:exception]` | Search queries |
| `[:recollect, :pipeline, :start/:stop/:exception]` | Document pipeline |
| `[:recollect, :embed, :stop]` | Embedding completion |
| `[:recollect, :extract, :stop]` | Entity extraction |
| `[:recollect, :decay, :stop]` | Decay maintenance |
| `[:recollect, :learning, :start/:stop]` | Learning pipeline |
| `[:recollect, :handoff, :create/:get/:load, :stop]` | Handoff operations |
| `[:recollect, :consolidation, :stop]` | Consolidation runs |
| `[:recollect, :invalidation, :start/:stop]` | Invalidation passes |
| `[:recollect, :completion, :start/:stop/:exception]` | LLM-augmented completion |

All `:stop` events include `%{duration: native_time}` in measurements.

## Requirements

- Elixir >= 1.17
- One supported database:
  - PostgreSQL with pgvector extension
  - SQLite3 with sqlite-vec extension
  - libSQL with native vector support
- An embedding provider (Local/Bumblebee included by default, or API-based via OpenRouter)
- An LLM API for entity extraction (only needed for Tier 1 pipeline)
