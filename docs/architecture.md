# Recollect Architecture

> Design decisions, algorithms, and OTP architecture for the memory lifecycle.

## Memory Lifecycle

Recollect models memory as a lifecycle rather than static storage. The key insight
(from Hippo/MemPalace research): **forgetting is a feature**. Memories must earn
persistence through relevance and use.

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Context    │────▶│  Learning   │────▶│ Invalidation│
│  Detection  │     │  Pipeline   │     │  Pipeline   │
└─────────────┘     └──────┬──────┘     └──────┬──────┘
                           │                   │
                           ▼                   ▼
                    ┌──────────────────────────────────┐
                    │        Consolidation             │
                    │  (decay + merge + conflicts)      │
                    └──────────────────┬─────────────────┘
                                       │
                    ┌──────────────────┴──────────────────┐
                    │                                    │
                    ▼                                    │
           ┌────────────────┐                  ┌────────────────┐
           │   Retrieval    │                  │   Mipmaps      │
           │ (with context) │                  │ (detail levels)│
           └────────────────┘                  └────────────────┘
```

## Three Tiers

```
┌──────────────────────────────────────────────────────────────┐
│ Tier 0: Working Memory (GenServer per scope)                 │
│ Session-scoped, no embeddings, importance-based eviction      │
├──────────────────────────────────────────────────────────────┤
│ Tier 2: Lightweight Knowledge                                 │
│ Entry + Edge with retrieval strengthening, outcome feedback,   │
│ confidence lifecycle, emotional valence, schema acceleration   │
├──────────────────────────────────────────────────────────────┤
│ Tier 1: Full Pipeline                                         │
│ Collection → Document → Chunk → Entity → Relation             │
├──────────────────────────────────────────────────────────────┤
│ Shared: Search, Context Formatting, Maintenance, Telemetry     │
└──────────────────────────────────────────────────────────────┘
```

## Strength & Decay

**Composite strength** drives memory survival:

```
strength = clamp(0.0, 1.0, decay_factor * retrieval_boost * emotional_multiplier * confidence)
```

**Decay factor** — exponential half-life decay:

```
decay_factor = 0.5 ^ (days_since_last_access / half_life_days)
```

Default half-life: **7.0 days**. Each retrieval extends by **+2 days**
(configurable via `config :recollect, :retrieval_strengthening,
half_life_boost_days: 2`).

**Retrieval boost** — logarithmic, diminishing returns:

```
retrieval_boost = 1 + 0.1 * log2(access_count + 1)
```

At count=1: 1.1, count=7: 1.3, count=1023: 2.0. Prevents unbounded strength.

**Pinned entries** short-circuit everything: `strength = 1.0` always.

## Confidence Lifecycle

States: `active` → `stale` → `observed` → `verified`

**Computed on-read**, not materialized in DB. Pure function `Recollect.Confidence.resolve_state/1`. DB writes only happen on state transitions (stale entry retrieved → `observed`, positive outcome feedback → `verified`).

- **Stale threshold**: 30 days without retrieval
- **Verified entries** never go stale
- **Impact on archival**: verified never archived; stale archived after 14 days; active archived after 90 days AND access_count < 3

## Emotional Valence

Valence is inferred from content via `Recollect.Valence.infer/1` and stored on entries. Multipliers (read from `:persistent_term` for O(1) access):

| Valence   | Multiplier | Rationale                                    |
|-----------|-----------|----------------------------------------------|
| neutral   | 1.0       | No effect                                    |
| positive  | 1.3       | Successes stick slightly better               |
| negative  | 1.5       | Errors/gotchas persist longer (amygdala)      |
| critical  | 2.0       | Production incidents, data loss — highest     |

## Schema Fit

**Blended IDF-weighted overlap** determines how well new content fits existing patterns:

```
schema_fit = 0.6 * tag_fit + 0.4 * content_fit
```

**Tag fit** uses IDF (inverse document frequency) so rare shared tags score higher:

```
tag_fit = min(1.0, (sum of IDF for matching tags) / (num_tags * max_IDF) * 2)
where IDF = log(N / freq) + 1
```

**Content fit** uses Jaccard similarity on token sets (words > 3 chars).

**Impact on half-life** (step function):

```
schema_fit > 0.7  →  half_life * 1.5  (familiar, consolidates faster)
schema_fit < 0.3  →  half_life * 0.5  (novel, decays faster if unused)
otherwise          →  unchanged
```

## Context-Aware Retrieval

Auto-detected context signals (git repo, working directory, OS) are stored as
`context_hints` on entries at creation. At search time, current environment is
matched against stored hints.

**Context boost** (additive to vector similarity):

```
context_boost = min(0.15 * num_matching_hints, 0.5)
```

Context can only help, never hurt.

## Conflict Detection

**Two-phase algorithm**:

1. **Overlap gate** (cheap): Jaccard similarity on polarity-stripped text AND tag
   overlap. Combined score must exceed **0.55**.
2. **Polarity check**: Pattern-match for contradictory pairs (enabled/disabled,
   true/false, always/never, negation words).

Key insight: **polarity stripping** before overlap computation ensures "feature X
is enabled" and "feature X is disabled" have HIGH content overlap but FAIL the
polarity check.

**Resolution**: loser's half-life is halved (not deleted by default).

Parallelized via `Task.async_stream` with `max_concurrency: System.schedulers_online()`.

## Sleep Consolidation

**5-pass pipeline** (no scheduler — host app decides when to run):

1. **Decay** — Remove entries below strength threshold 0.05 (pinned exempt)
2. **Merge** — O(n^2) text overlap (threshold 0.35) → Union-Find clustering →
   semantic summaries for clusters of 3+
3. **Conflict detection** — Delegates to conflict detection algorithm
4. **Schema indexing** — Rebuilds ETS tag frequency index
5. **Persist** — Records consolidation run metrics

Merge uses **Union-Find** for connected components. Semantic summary format:
- 2 entries: longest content, prefixed with consolidation marker
- 3+ entries: bullet list of first 120 chars each

## Mipmaps

Progressive detail levels for retrieval, stored in `recollect_mipmaps` table:

| Level     | Content                           | When used                     |
|-----------|-----------------------------------|-------------------------------|
| `:anchor` | Type + single key term            | Very short queries (< 50 chars) |
| `:abstract` | First line + type + tags        | Short queries (< 200 chars)   |
| `:summary` | First 200 chars + key metadata  | Medium queries                |
| `:full`   | Full content + all metadata      | Long queries (200+ chars)     |

**Escalation**: If results are sparse (< 3), escalate from abstract → summary → full.

## Active Invalidation

Detects breaking changes and weakens related memories.

**Weaken factor**: multiply half-life by **0.1** (default). A 7-day half-life becomes
0.7 days, causing rapid decay without immediate deletion.

**Detection patterns** (from git commit subjects):
- `migrate(d)? from X to/with Y`
- `refactor/rewrite: X to/-> Y`
- `replace[dr]? X with/by Y`
- `drop(ped)? support for X`
- `BREAKING CHANGE:`

## OTP Architecture

### Storage Decisions

| Component           | Storage                     | Why                                           |
|---------------------|-----------------------------|-----------------------------------------------|
| Retrieval counters  | ETS `:counter`, GenServer   | O(1) atomic increments, batch-flush to DB     |
| Outcome tracking     | Public ETS `:set`           | Cross-process, no GenServer needed             |
| Schema index         | Public ETS `:set`           | O(1) lookup, rebuilt during consolidation     |
| Working memory       | DynamicSupervisor + GenServer per scope | Ephemeral, crash = correct empty state |
| Emotional multipliers | `:persistent_term`         | O(1) read, immutable after boot               |

### Supervision Tree

```
Recollect.Supervisor (one_for_one)
├── Task.Supervisor (named: Recollect.TaskSupervisor)
├── Registry (named: Recollect.WorkingMemory.Registry)
├── DynamicSupervisor (named: Recollect.WorkingMemory.Supervisor)
│   ├── WorkingMemory.Server (scope: "abc")  — auto-started on push
│   └── WorkingMemory.Server (scope: "def")  — auto-killed on flush
├── Recollect.RetrievalCounter (GenServer, owns ETS table)
└── (ETS tables: OutcomeTracker, SchemaIndex — no process owner)
```

### Retrieval Counter Design

Search hits are O(1) in-memory increments. On Postgres a single bulk
`UPDATE ... FROM unnest(...)` flushes to DB every 30 seconds; SQLite/libSQL
flush per row (batches are search-page-sized). On graceful shutdown,
`terminate/2` flushes remaining counters. Tradeoff: up to 30s of counter
data can be lost on a crash (acceptable for access counts).

## Backend Feature Matrix (MEM-011)

Everything below runs on PostgreSQL (pgvector) unless marked otherwise.
SQLite (sqlite-vec) and libSQL share one code path ("SQLite leg") via
`ecto_sqlite3` / `ecto_libsql`.

| Feature                              | Postgres | SQLite/libSQL |
|--------------------------------------|----------|---------------|
| remember/forget/connect + tags       | ✅        | ✅             |
| Vector search (entries + chunks)     | ✅        | ✅             |
| Search filters (type/tags/temporal)  | ✅        | ✅             |
| Mipmaps (persist + retrieve)         | ✅        | ✅             |
| Consolidation (decay/merge/persist)  | ✅        | ✅             |
| Conflicts (detect/persist/resolve)   | ✅        | ✅             |
| Handoffs                             | ✅        | ✅             |
| Confidence + outcome updates         | ✅        | ✅ (CASE-based floors) |
| Retrieval counter flush              | ✅ bulk `unnest` | ✅ per-row |
| Graph search (`Search.Graph`)        | ✅ recursive CTEs | ❌ swap `GraphStore` |
| `Graph.PostgresGraph` backend        | ✅        | ❌ implement `Recollect.GraphStore` |
| Import/export                        | ✅        | ✅ (dialect placeholders) |

Two disciplines keep the matrix honest:

- Adapter-agnostic modules are plain Ecto; where SQL fragments are
  unavoidable, they use portable constructs (`CASE` floors instead of
  `GREATEST`, `LOWER(...) LIKE` instead of `ILIKE`).
- `test/recollect/backend_parity_test.exs` fails the build if a bare `$N`
  placeholder appears outside the allowlisted, dialect-branched modules.


## Configuration Reference

All features configurable via `config :recollect`:

| Feature                | Key                           | Default            |
|------------------------|-------------------------------|--------------------|
| Retrieval strengthening | `:retrieval_strengthening`    | `half_life_boost_days: 2, flush_interval_ms: 30_000` |
| Working memory         | `:working_memory`             | `max_entries_per_scope: 20` |
| Outcome feedback       | `:outcome_feedback`           | `positive_half_life_delta: 5, negative_half_life_delta: 3` |
| Confidence lifecycle   | (computed on-read)            | `stale_threshold_days: 30` |
| Emotional valence      | `:emotional_valence`          | `neutral: 1.0, positive: 1.3, negative: 1.5, critical: 2.0` |
| Schema acceleration    | (computed on create)          | `high: 0.7/1.5, low: 0.3/0.5` |
| Conflict detection     | (computed during consolidation) | `threshold: 0.55` |
| Consolidation          | (run on demand)               | `decay: 0.05, merge: 0.35, min_cluster: 3` |
| Context boost          | (automatic)                   | `per_match: 0.15, max: 0.5` |
| Invalidation           | `:invalidation`               | `weaken_factor: 0.1` |
