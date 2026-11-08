# Agent Memory: Implementation Plan

> **Part 2 of 2.** The research report is
> [`agent-memory-research.md`](agent-memory-research.md).
>
> **Baseline:** Recollect `v0.6.0`, commit `948cb2a`, 2026-11-07.
>
> **Status:** proposed. Nothing in this plan is implemented.
>
> **Audience:** Recollect maintainers and host-application integrators.

---

## 0. Executive summary

This plan turns the research findings into a phased, testable delivery. It is
ordered by dependency, not by novelty:

1. **Phase 0 — Stabilize.** Fix the broken maintenance loops and data loss.
   This is a release blocker. No new memory layer should ship on top of a
   consolidation pass that raises on any non-empty scope.
2. **Phase 1 — Provenance.** Add an append-only event ledger and evidence links,
   plus the entry fields needed to represent scope, stability, epistemic status,
   and validity.
3. **Phase 2 — Brief and recall.** Add a hard token budget to the injected layer
   and a path/symbol anchor index for just-in-time recall.
4. **Phase 3 — Dreaming v1.** Add an idempotent, budgeted, locked orchestration
   of verify → reconcile → promote → prune.
5. **Phase 4 — Pages.** Add cited wiki pages with a compression guard.
6. **Phase 5 — Hybrid retrieval and evaluation.** Add lexical retrieval, rank
   fusion, an optional reranker, and an eval harness that measures task success.

The plan contains **40 tickets** (MEM-001 … MEM-040), grouped into six phases.
Estimates assume one senior Elixir engineer familiar with the codebase:

| Phase | Tickets | Ideal engineering days |
|---|---:|---:|
| 0 — Stabilize | 15 | 23 |
| 1 — Provenance | 7 | 17 |
| 2 — Brief and recall | 6 | 17 |
| 3 — Dreaming v1 | 4 | 19 |
| 4 — Pages | 4 | 13 |
| 5 — Hybrid and eval | 4 | 16 |
| **Total** | **40** | **105** |

At five focused days per week, 105 ideal days is about 21 weeks of pure
implementation. With 20–30% overhead for review, docs, migration testing, and
contingency, plan for roughly 25–27 weeks for one engineer. With two engineers,
Phases 1–2 and 4–5 can partially overlap, but Phase 0 is a single critical path
and should not be parallelized across too many files.

MEM-035 … MEM-040 were added in v2 of this plan after a fleet-wide review of
how home, ops_center, AgentForge, and worth actually consume Recollect — see
[`agent-memory-system.md`](agent-memory-system.md). They encode capabilities
hosts have already had to build themselves: a remember-contract that never
throws, an engine-level secret guard, migration-drift tooling, keyword
fallback search, transcript-based project mapping, and durable staging.

**Execution:** the whole family is filed in the ops_center backlog as
**ops-agent-memory** (`repo: recollect`, B-2570 … B-2609 — the per-ticket
mapping is the *B-ticket* column in Appendix A). Work happens in the recollect
checkout with `Ticket: B-NNN` commit trailers; this document's Appendix A
*Status* column and §15 (execution log) are kept in sync as tickets land.

**Release gates:**

- **0.6.x / 0.7.0** — Phase 0. Bug fixes plus additive tag storage.
- **0.8.0** — Phase 1. New tables and entry fields.
- **0.9.0** — Phase 2. Brief and recall.
- **0.10.0** — Phase 3. Dreaming v1.
- **0.11.0** — Phase 4. Pages.
- **1.0.0** — Phase 5, only after the eval harness shows no regression and the
  backend parity matrix is green.

The exact version numbers are negotiable; the ordering is not.

---

## 1. Goals, non-goals, and success criteria

### 1.1 Goals

| ID | Goal | Why |
|---|---|---|
| G1 | Make consolidation, decay, conflict detection, and retrieval counting correct and persistent | These are the maintenance loops the whole memory model depends on |
| G2 | Give every claim provenance back to an event, file, test, or user statement | Without it, synthesis cannot be corrected |
| G3 | Separate raw events, claims, pages, and the injected brief | They have different lifecycles and costs |
| G4 | Enforce a hard token budget on injected context | Tokens are the real cost of memory |
| G5 | Add just-in-time recall keyed by path/symbol | Keeps the session brief small and precise |
| G6 | Make dreaming idempotent, locked, budgeted, and observable | Prevents runaway cost and partial writes |
| G7 | Add cited pages with a compression guard | Captures cross-document structure without wiki bloat |
| G8 | Add lexical retrieval, rank fusion, and an optional reranker | Vector-only retrieval misses exact names and symbols |
| G9 | Measure task success, not recall count | The only meaningful test of memory quality |
| G10 | Deliver the same behavior on Postgres and SQLite/libSQL, or fail explicitly | The library advertises multi-backend support |

### 1.2 Non-goals

- Training or fine-tuning model weights.
- Building a hosted service, UI, or multi-tenant auth layer.
- Replacing the host application's job queue. Recollect will expose a library API
  and an optional worker behaviour; it will not depend on Oban.
- Replacing PostgreSQL or pgvector with a new vector database.
- Implementing every item in the research report at once. The phases are
  deliberately gated.
- A full document-management system. Tier 1 ingestion remains as-is unless a
  ticket explicitly touches it.

### 1.3 Success criteria

**Phase 0 exit criteria**

- `MIX_ENV=test mix check` passes.
- A scope with at least one non-archived entry runs `Consolidation.run/1`
  without raising and writes a run record.
- Entries below the decay threshold are archived in the database, and `removed`
  equals the number of affected rows.
- A pair of contradictory entries produces a persisted conflict; rerunning does
  not duplicate it.
- Tags round-trip through `remember/2` and filter search results.
- `access_count` after a flush equals the number of retrievals, not the number
  of flushes.
- `Strength.calculate/2` does not raise on a superseded entry.
- A single `remember/2` with mipmaps off makes one embedding call and one entry
  insert.
- `remember/2` with embeddings and extraction disabled returns `{:ok, entry}`
  and never throws (MEM-035).
- A token-shaped string is rejected with `{:error, :possible_secret}` by
  default, and the rejection is visible in telemetry (MEM-036).
- `mix recollect.migration_status` reports applied/missing migrations against
  the shipped manifest and exits non-zero when something is missing (MEM-037).

**Phase 1 exit criteria**

- Every new claim written by `Learning`/`Harvest` has at least one evidence row,
  or an explicit `verification: "user"`/`source: "user"` marker.
- Re-running the learning pipeline over the same events produces no duplicates.
- `Knowledge.explain/1` returns sources, usage, and verification for an entry.
- With embeddings disabled, `Search.search/2` still returns keyword matches and
  reports `resolved_mode: :keyword_fallback` (MEM-038).
- A session harvested from a scratchpad worktree is attributed to the repo in
  its `cwd`, not the worktree's directory slug (MEM-039).

**Phase 2 exit criteria**

- `Brief.build/2` never exceeds the configured token budget.
- Every brief item carries a citation ID.
- Touching a file can retrieve a recall block under 200 tokens.
- `ContextFormatter.format/2` deduplicates entries and related entries.
- `Recollect.Staging.stage/drain` round-trips; two concurrent drains claim
  disjoint rows; `Sleep.distill(from_staging: true)` promotes survivors and
  returns failures to `staged` (MEM-040).

**Phase 3 exit criteria**

- A dream run is idempotent for the same input hash.
- Two concurrent dream runs on the same scope do not both mutate state.
- A budget-exceeded run stops at a stage boundary, records partial progress, and
  does not start an action it cannot finish.
- A failed stage rolls back that stage; completed stages remain recorded and the
  run is resumable.
- Conflicts are reconciled with a dialectic record, not overwritten.

**Phase 4 exit criteria**

- Every page cites at least one source.
- No page exceeds the compression guard.
- Page + search beats search-only on the project eval set, or the page feature
  is disabled by default.

**Phase 5 exit criteria**

- Hybrid retrieval beats vector-only on recall and token efficiency.
- Memory-on task success is not worse than memory-off on the eval harness.
- p95 latency stays within the budgets in §10.

---

## 2. Baseline and assumptions

### 2.1 Baseline

The research report (§6) documents 20 verified issues. The most important
baseline facts for implementation:

- The test suite has no `consolidation_test.exs` and no
  `conflict_detection_test.exs`.
- `test/test_helper.exs` starts `Recollect.TestRepo` and runs all migrations.
- `mix test` runs `ecto.create`, `ecto.migrate`, then `test`.
- `mix check` runs `clean`, `compile --warnings-as-errors`,
  `format --check-formatted`, and `test`.
- The package is a single Elixir library; `priv/repo/migrations` is used by the
  test/demo repo, while host applications generate migrations through
  `Recollect.MigrationGenerator`.
- `Recollect.Application` supervises `TaskSupervisor`, the working-memory
  registry/dynamic supervisor, and `RetrievalCounter`.
- `Recollect.Config` reads runtime config from `config :recollect`.
- `Recollect.DatabaseAdapter` exposes `dialect/0`, `uuid_type/0`,
  `placeholder/1`, `vector_type/1`, and related callbacks.

### 2.2 Assumptions

| Assumption | Impact if false |
|---|---|
| PostgreSQL is the primary production backend | Phase 0 bulk SQL can use Postgres features; SQLite parity is best-effort but must fail explicitly |
| Hosts can schedule `Dream.run/2` (Oban, cron, or manual) | Recollect must not depend on a scheduler; provide a worker behaviour |
| An embedding provider is configured for semantic retrieval | Lexical retrieval and briefs still work; vector paths degrade gracefully |
| Hosts can supply an LLM function for synthesis | Dreaming falls back to heuristic/template synthesis; pages are lower quality |
| Existing entries can be backfilled in batches | Large tables need online migrations; see §11 |
| `owner_id` and `scope_id` semantics stay as documented | Memory levels and inheritance depend on them |

### 2.3 Constraints

- **No new required dependencies.** Optional integrations (e.g., a tokenizer)
  must be optional.
- **Backwards-compatible public API** for additive changes. Deprecations get at
  least one minor release.
- **No destructive migration by default.** `forget/1` becomes a tombstone unless
  `hard: true` is passed.
- **No silent feature degradation.** If a backend cannot support a feature, the
  API returns `{:error, :unsupported_backend}` and the docs say so.
- **No unbounded background work.** Every batch job has a budget and a dry-run
  mode.

---

## 3. Architecture decisions

### ADR-001 — Extend `recollect_entries` for L1 instead of a new claims table

**Decision:** Add lifecycle fields to `recollect_entries`; do not introduce a
separate `recollect_claims` table in the first pass.

**Rationale:** The existing Tier 2 API, search, graph edges, and host
integrations already depend on `recollect_entries`. A separate table would
require a dual-write period, a migration of every edge, and a second retrieval
path. Additive columns are cheaper and keep the public API stable.

**Consequences:** The table becomes wider and carries fields that are irrelevant
to some entry types. A future extraction into a claims table remains possible;
the evidence and page tables are designed so that a split is not blocked.

**Alternatives considered:** New `recollect_claims` table (cleaner, much larger
migration); a JSON `properties` column (less queryable, weaker constraints).

### ADR-002 — Add an append-only event ledger and an evidence join table

**Decision:** Add `recollect_events` (append-only, no embeddings by default) and
`recollect_evidence` (claim ↔ event/file/test/user statement).

**Rationale:** The article's dreaming correction works because the transcript is
available as ground truth. Recollect currently discards raw events after
extraction, so there is nothing to verify against. The ledger also enables
transcript search and audit.

**Consequences:** Storage grows; consent and retention become first-class. Events
are not retrieval targets by default, which keeps the vector index small.

**Alternatives considered:** Store transcripts as documents in Tier 1 (couples
two pipelines, adds chunking/embedding cost); store only extracted records
(no verification possible).

### ADR-003 — Pages are a first-class table with explicit sources

**Decision:** Add `recollect_pages` and `recollect_page_sources`.

**Rationale:** A page is not a note. It has a slug, a body, a token count, a
source hash, a version, and citations. Storing it as an entry with
`entry_type: "summary"` loses all of that and makes the compression guard
impossible.

**Consequences:** A second retrieval target and a synthesis pipeline. Search must
merge entries and pages. The page cap and compression guard are enforceable.

**Alternatives considered:** Reuse consolidation summary entries (current
approach; no citations, no guard); store pages as files (host-dependent, no
queryable metadata).

### ADR-004 — The brief is a rendered view, not a stored artifact

**Decision:** `Recollect.Brief.build/2` selects and renders from entries, pages,
handoffs, and rules at request time. An optional cache keyed by
`(scope_id, generation, budget)` is allowed, but the rendered text is not the
source of truth.

**Rationale:** A stored brief goes stale silently. A rendered view can be
invalidated by writes and dream runs and can be audited item by item.

**Consequences:** Build cost on session start. The budget selection must be fast;
§10 sets a p95 target of 50 ms.

### ADR-005 — Dreaming is an orchestrator library, not a scheduler

**Decision:** `Recollect.Dream.run/2` exposes a synchronous, budgeted pipeline;
hosts schedule it. Provide `Recollect.Dream.Worker` as an optional behaviour, not
an Oban dependency.

**Rationale:** Recollect is a library. Forcing a job queue would break hosts that
use something else. The pipeline still needs a lock and idempotency key, which
Recollect can provide.

**Consequences:** Hosts must wire scheduling. The docs must show Oban, cron, and
manual examples. `Dream.status/1` reports run state.

### ADR-006 — Hybrid retrieval uses reciprocal rank fusion

**Decision:** Retrieve candidates from vector, lexical, graph, and recall-anchor
sources; fuse with reciprocal rank fusion (RRF, `k = 60`); dedupe; apply
diversity; then apply a global limit and token budget.

**Rationale:** The current code concatenates categories, so the first category
wins and `limit` applies per source. RRF is simple, robust to incomparable score
scales, and does not require training.

**Consequences:** More queries per search, but each is cheap. A reranker is
optional and must be budgeted. The result shape gains `sources`, `score`, and
`estimated_tokens`.

### ADR-007 — Backend parity is enforced by adapters and explicit errors

**Decision:** Prefer Ecto queries. Where raw SQL is required, use
`DatabaseAdapter.placeholder/1` and `dialect/0`. If a feature cannot be
implemented on a backend, return `{:error, :unsupported_backend}` and document
it in a feature matrix.

**Rationale:** The current code uses `$1`, `ANY()`, and `ILIKE` in modules that
claim to be adapter-agnostic. On SQLite these fail, often silently.

**Consequences:** More adapter code and a CI matrix. Some features (e.g., GIN
indexes, advisory locks) are Postgres-only.

### ADR-008 — Idempotency is enforced by unique indexes, not application checks

**Decision:** Add unique indexes for `(owner_id, content_hash)` on events and
`(source, source_id)` on entries (partial, where `source_id IS NOT NULL`).
Application-level dedup is a fast path, not the guarantee.

**Rationale:** Concurrent harvest runs and retries can race. A database
constraint is the only reliable dedup.

**Consequences:** `remember/2` must handle unique-violation errors and return the
existing row when configured to `:skip`/`:update`.

### ADR-009 — Memory levels and precedence are explicit

**Decision:** Add `memory_level` with values `global`, `workspace`, `session`,
`agent`. Retrieval includes inherited levels unless the caller opts out.
Precedence: `agent > session > workspace > global`.

**Rationale:** HN users repeatedly discovered that a memory they thought was
global was scoped to a project. Recollect has `scope_id` but no level or
inheritance semantics.

**Consequences:** More rows are considered at retrieval; the brief must label the
level. Conflict resolution across levels needs evidence, not "last write wins."

### ADR-010 — Supersession becomes dialectic reconciliation

**Decision:** Keep the old claim with `valid_to` and a link to the new claim.
Record the evidence for both sides, the synthesis, and any unresolved questions.
Do not zero the old claim's half-life or confidence as a side effect.

**Rationale:** The current `supersede/3` loses the reasoning and stores
`half_life_days: 0.0`, which can raise in `Strength`. The Particulars model is a
better fit for changing knowledge.

**Consequences:** More rows and a `recollect_reconciliations` table. The old
entry remains queryable with `include_superseded: true`.

### ADR-011 — Token budgets are first-class configuration

**Decision:** Add `:brief`, `:retrieval`, `:dream`, and `:events` config
namespaces with explicit budgets. Defaults: brief 1,500 tokens, recall block 200
tokens, dream 50,000 LLM tokens per run, event retention 30 days.

**Rationale:** The article's most practical finding is that the injected layer
must stay small. Recollect currently has no budget anywhere.

**Consequences:** Selection can drop items; the result reports `:truncated` and
`:candidates_considered`. Hosts can tune budgets per model.

### ADR-012 — Mipmaps become lazy and optional

**Decision:** Default `mipmaps.mode` to `:lazy` (generate on first escalation) or
`:off`; keep `:eager` for compatibility. Batch the four level embeddings into one
provider call. Reuse the query embedding in retrieval.

**Rationale:** A single `remember/2` can currently cost 5 embedding calls and 8
mipmap statements. Most entries are never retrieved at four levels.

**Consequences:** First escalation pays the generation cost. The retrieval path
must handle a missing mipmap gracefully. Pages eventually replace most mipmap
use cases.

---

## 4. Target module map

### 4.1 New modules

| Module | Responsibility | Phase |
|---|---|---|
| `Recollect.Event` | Record/list raw events; content hashing; retention | 1 |
| `Recollect.Evidence` | Link claims to events/files/tests; query provenance | 1 |
| `Recollect.Schema.EntryTag` | Tag persistence and lookup | 0 |
| `Recollect.Guards` | Secret detection on writes and distillation (MEM-036) | 0 |
| `Recollect.Staging` | Durable working-memory tier: stage/drain (MEM-040) | 2 |
| `Recollect.Tokenizer` | Token estimation and budget fitting | 2 |
| `Recollect.Brief` | Select, rank, render the injected context | 2 |
| `Recollect.Recall` | Path/symbol anchor indexing and lookup | 2 |
| `Recollect.Dream` | Orchestrate verify → reconcile → synthesize → promote → prune | 3 |
| `Recollect.Dream.Run` | Run record, lock, idempotency, metrics | 3 |
| `Recollect.Page` | Page CRUD, citations, compression guard | 4 |
| `Recollect.PageSource` | Page ↔ source links | 4 |
| `Recollect.Search.Lexical` | Postgres `tsvector` / SQLite FTS5 search | 5 |
| `Recollect.Search.Fusion` | RRF, dedupe, diversity, global budget | 5 |
| `Recollect.Reranker` | Behaviour for optional reranking | 5 |
| `Recollect.Review` | Review candidates and explanations | 1 |
| `Recollect.Dream.Worker` | Optional host worker behaviour | 3 |

### 4.2 Changed modules

| Module | Change | Phase |
|---|---|---|
| `Recollect.Knowledge` | Persist tags; accept lifecycle fields and evidence; dedup; soft delete; review/explain; secret guard; never throw on disabled enrichment | 0–2 |
| `Recollect.Schema.Entry` | Add fields and `has_many :entry_tags` | 0–1 |
| `Recollect.Schema.Edge` | Add target-side index; keep relation types | 0 |
| `Recollect.Consolidation` | Ecto-based fetch; persist removals; fix union-find and pair generation; provenance for summaries | 0 |
| `Recollect.ConflictDetection` | Fix query and binding; canonical pair order; scope and tag handling | 0 |
| `Recollect.Conflicts` | Adapter-aware SQL; reopen semantics | 0 |
| `Recollect.SchemaIndex` | Scope-aware rebuild from the tags table | 0 |
| `Recollect.SchemaFit` | Cheap tag fit on write; async/sampled content fit | 0 |
| `Recollect.RetrievalCounter` | Flush actual counts; adapter-aware bulk update | 0 |
| `Recollect.Strength` | Guard nil/zero half-life and nil timestamps | 0 |
| `Recollect.Sleep` | Atomic drain; retain failed items; evidence links; `from_staging` mode | 0/1/2 |
| `Recollect.Mipmap` | Lazy generation; batch embeddings; reuse query embedding; exclude archived | 0 |
| `Recollect.Context.Detector` | Cached/opt-in detection | 0 |
| `Recollect.Learning.*` | Respect `since`; write events; checkpoint integration; cwd/remote-based project mapping | 0/1 |
| `Recollect.ProjectMapping` | Resolve from git remote → cwd → slug (MEM-039) | 1 |
| `Recollect.Search` | Keyword fallback; hybrid modes; global limit; unified result shape | 1/5 |
| `Recollect.Search.Vector` | Tag filters; keyword fallback path; page candidates; pass query embedding | 0/1/4/5 |
| `Recollect.Search.ContextFormatter` | Budget, dedupe, citations | 2 |
| `Recollect.Handoff` | Budgeted brief integration | 2 |
| `Recollect.WorkingMemory` | Atomic drain; bounded load; deprecate in favor of `Recollect.Staging` | 0/2 |
| `Recollect.MigrationGenerator` | New tables/columns; upgrade generator; migration manifest | 0–5 |
| `Recollect.Config` | New config namespaces and validation | 0–5 |

### 4.3 Deprecated / retired

| Item | Replacement | Timeline |
|---|---|---|
| Eager mipmap generation on every write | Lazy mipmaps / page sections | 0.7, removed in 1.0 |
| `Knowledge.supersede/3` destructive behavior | Dialectic reconciliation + `valid_to` | 0.7, deprecated in 0.8 |
| `context_hints` option name | `context` option (keep an alias) | 0.8 |
| Consolidation summary entries without provenance | Pages with citations | 0.11 |
| Per-category `limit` semantics | Global limit + RRF | 1.0 |

---

## 5. Data model

### 5.1 Entity relationships

```
recollect_entries 1 ─── * recollect_entry_tags
        │
        ├── 1 ─── * recollect_evidence ─── * recollect_events
        │
        ├── * ─── * recollect_pages  (via recollect_page_sources)
        │
        └── * ─── * recollect_recall_anchors
recollect_pages 1 ─── * recollect_page_sources
recollect_pages 1 ─── * recollect_recall_anchors
recollect_dream_runs (per scope, idempotency)
recollect_reconciliations (thesis/antithesis/synthesis)
```

### 5.2 PostgreSQL DDL

All table names use the configured prefix (default `recollect_`). The DDL below
uses the default. `uuid` assumes the Postgres adapter; SQLite uses `TEXT`.

```sql
-- ── L0: event ledger ────────────────────────────────────────────────
CREATE TABLE recollect_events (
  id              uuid PRIMARY KEY,
  owner_id        uuid NOT NULL,
  scope_id        uuid,
  session_id      uuid,
  agent           text,                    -- claude_code | codex | opencode | ...
  event_type      text NOT NULL,           -- message | tool_call | tool_result | file_change | test_run | commit
  role            text,                    -- user | assistant | tool | system
  content         text,
  occurred_at     timestamptz NOT NULL,
  source_uri      text,                    -- file path, URL, session file
  source_ref      text,                    -- line range, commit sha, message id
  parent_event_id uuid REFERENCES recollect_events(id) ON DELETE SET NULL,
  metadata        jsonb NOT NULL DEFAULT '{}',
  content_hash    text NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX recollect_events_owner_time_idx
  ON recollect_events (owner_id, occurred_at DESC);
CREATE INDEX recollect_events_scope_time_idx
  ON recollect_events (scope_id, occurred_at DESC);
CREATE INDEX recollect_events_session_time_idx
  ON recollect_events (session_id, occurred_at DESC);
CREATE UNIQUE INDEX recollect_events_content_hash_idx
  ON recollect_events (owner_id, content_hash);

-- ── L0 → L1: evidence ───────────────────────────────────────────────
CREATE TABLE recollect_evidence (
  id          uuid PRIMARY KEY,
  entry_id    uuid NOT NULL REFERENCES recollect_entries(id) ON DELETE CASCADE,
  event_id    uuid REFERENCES recollect_events(id) ON DELETE SET NULL,
  relation    text NOT NULL,               -- supports | contradicts | derived_from | supersedes
  excerpt     text,
  source_type text,                        -- event | file | test | user | url
  source_ref  text,
  weight      float NOT NULL DEFAULT 1.0,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX recollect_evidence_entry_idx ON recollect_evidence (entry_id);
CREATE INDEX recollect_evidence_event_idx ON recollect_evidence (event_id);
CREATE UNIQUE INDEX recollect_evidence_unique_idx
  ON recollect_evidence (entry_id, relation, source_type, source_ref)
  WHERE source_ref IS NOT NULL;

-- ── L1: tags (normalized for backend parity) ─────────────────────────
CREATE TABLE recollect_entry_tags (
  entry_id uuid NOT NULL REFERENCES recollect_entries(id) ON DELETE CASCADE,
  tag      text NOT NULL,
  scope_id uuid,
  PRIMARY KEY (entry_id, tag)
);

CREATE INDEX recollect_entry_tags_scope_tag_idx
  ON recollect_entry_tags (scope_id, tag);

-- ── L1: lifecycle fields on entries ─────────────────────────────────
ALTER TABLE recollect_entries
  ADD COLUMN memory_level text NOT NULL DEFAULT 'workspace',
  ADD COLUMN stability    text NOT NULL DEFAULT 'evolving',
  ADD COLUMN epistemic    text NOT NULL DEFAULT 'inferred',
  ADD COLUMN valid_from   timestamptz,
  ADD COLUMN valid_to     timestamptz,
  ADD COLUMN verified_at  timestamptz,
  ADD COLUMN verification text NOT NULL DEFAULT 'none',
  ADD COLUMN version      integer NOT NULL DEFAULT 1,
  ADD COLUMN deleted_at   timestamptz;

CREATE INDEX recollect_entries_scope_level_idx
  ON recollect_entries (scope_id, memory_level, stability);
CREATE INDEX recollect_entries_live_idx
  ON recollect_entries (scope_id, inserted_at DESC)
  WHERE deleted_at IS NULL AND entry_type != 'archived';
CREATE UNIQUE INDEX recollect_entries_source_idx
  ON recollect_entries (source, source_id)
  WHERE source_id IS NOT NULL;

-- ── L2: pages ───────────────────────────────────────────────────────
CREATE TABLE recollect_pages (
  id          uuid PRIMARY KEY,
  owner_id    uuid NOT NULL,
  scope_id    uuid,
  slug        text NOT NULL,
  title       text NOT NULL,
  kind        text NOT NULL DEFAULT 'topic',  -- topic | project | person | runbook | index
  body_md     text NOT NULL,
  summary     text,
  token_count integer NOT NULL,
  version     integer NOT NULL DEFAULT 1,
  source_hash text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX recollect_pages_scope_slug_idx ON recollect_pages (scope_id, slug);
CREATE INDEX recollect_pages_kind_idx ON recollect_pages (scope_id, kind);

CREATE TABLE recollect_page_sources (
  id          uuid PRIMARY KEY,
  page_id     uuid NOT NULL REFERENCES recollect_pages(id) ON DELETE CASCADE,
  entry_id    uuid REFERENCES recollect_entries(id) ON DELETE SET NULL,
  event_id    uuid REFERENCES recollect_events(id) ON DELETE SET NULL,
  source_type text NOT NULL,               -- entry | event | url | file
  source_ref  text,
  role        text NOT NULL DEFAULT 'supporting', -- primary | supporting | contradicting
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX recollect_page_sources_page_idx ON recollect_page_sources (page_id);
CREATE UNIQUE INDEX recollect_page_sources_unique_idx
  ON recollect_page_sources (page_id, source_type, source_ref)
  WHERE source_ref IS NOT NULL;

-- ── Recall anchors ──────────────────────────────────────────────────
CREATE TABLE recollect_recall_anchors (
  id           uuid PRIMARY KEY,
  entry_id     uuid REFERENCES recollect_entries(id) ON DELETE CASCADE,
  page_id      uuid REFERENCES recollect_pages(id) ON DELETE CASCADE,
  anchor_type  text NOT NULL,              -- path | symbol | module | function | route | table | config_key | error
  anchor_value text NOT NULL,
  confidence   float NOT NULL DEFAULT 0.5,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX recollect_recall_anchors_lookup_idx
  ON recollect_recall_anchors (anchor_type, anchor_value);
CREATE INDEX recollect_recall_anchors_entry_idx ON recollect_recall_anchors (entry_id);

-- ── Dreaming ────────────────────────────────────────────────────────
CREATE TABLE recollect_dream_runs (
  id          uuid PRIMARY KEY,
  owner_id    uuid,
  scope_id    uuid NOT NULL,
  input_hash  text NOT NULL,
  status      text NOT NULL DEFAULT 'pending', -- pending | running | done | failed | aborted
  stages      jsonb NOT NULL DEFAULT '{}',
  metrics     jsonb NOT NULL DEFAULT '{}',
  started_at  timestamptz,
  finished_at timestamptz,
  error       text
);

CREATE UNIQUE INDEX recollect_dream_runs_idempotency_idx
  ON recollect_dream_runs (scope_id, input_hash)
  WHERE status = 'done';
CREATE INDEX recollect_dream_runs_scope_time_idx
  ON recollect_dream_runs (scope_id, started_at DESC);

CREATE TABLE recollect_reconciliations (
  id                 uuid PRIMARY KEY,
  scope_id           uuid NOT NULL,
  thesis_entry_id    uuid REFERENCES recollect_entries(id) ON DELETE SET NULL,
  antithesis_entry_id uuid REFERENCES recollect_entries(id) ON DELETE SET NULL,
  synthesis_entry_id uuid REFERENCES recollect_entries(id) ON DELETE SET NULL,
  reasoning          text,
  unresolved         jsonb NOT NULL DEFAULT '[]',
  status             text NOT NULL DEFAULT 'open', -- open | resolved | abandoned
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX recollect_reconciliations_scope_idx
  ON recollect_reconciliations (scope_id, status);

-- ── Working-memory tier: durable staging (MEM-040) ──────────────────
CREATE TABLE recollect_staging (
  id          uuid PRIMARY KEY,
  owner_id    uuid NOT NULL,
  scope_id    uuid NOT NULL,
  content     text NOT NULL,
  metadata    jsonb NOT NULL DEFAULT '{}',
  source      text,
  priority    float NOT NULL DEFAULT 0.5,
  status      text NOT NULL DEFAULT 'staged',  -- staged | drained
  inserted_at timestamptz NOT NULL DEFAULT now(),
  drained_at  timestamptz
);

CREATE INDEX recollect_staging_scope_idx
  ON recollect_staging (scope_id, status, inserted_at);
CREATE INDEX recollect_staging_retention_idx
  ON recollect_staging (status, drained_at);
```

### 5.3 SQLite / libSQL differences

| Feature | PostgreSQL | SQLite / libSQL |
|---|---|---|
| UUIDs | `uuid` | `TEXT` (Ecto `:binary_id` or string) |
| JSON | `jsonb` | `TEXT` with JSON1 functions |
| Tags | Normalized table (same) | Normalized table (same) |
| Full-text | `tsvector` + GIN | FTS5 virtual table |
| Partial indexes | Supported | Supported |
| Advisory locks | Session-level `pg_advisory_lock` on a checked-out connection | `:global.trans/3` + a DB transaction; single-node only |
| `ANY(array)` | Supported | Expand to placeholders or per-row updates |
| Generated columns | Supported | Supported in recent SQLite; prefer app-maintained |

**Decision:** use normalized tags on both backends. It avoids array-type
portability issues and gives the same query shape. A denormalized tag cache can
be added later if profiling shows the join is hot.

### 5.4 Migration strategy

1. **Additive migrations only** in Phases 0–2. No column drops, no type changes.
2. **Backfill in batches** of 1,000 rows with a configurable sleep, recorded in
   `recollect_migration_state` (new table) so a restart can resume.
3. **Defaults are safe for old rows:** `memory_level = "workspace"`,
   `stability = "evolving"`, `epistemic = "inferred"`, `verification = "none"`,
   `version = 1`.
4. **Tags backfill:** if `metadata["tags"]` exists, copy each string into
   `recollect_entry_tags`; otherwise leave empty.
5. **No event backfill.** Events start at installation/upgrade; old entries get
   `verification = "none"`.
6. **Unique index creation** happens after deduplicating existing
   `(source, source_id)` rows. The migration reports duplicates and keeps the
   newest row; it does not delete data silently.
7. **Down migrations** drop the new tables/columns. They are safe because the
   data is additive, but they lose provenance; document that.

### 5.5 Migration generator changes

`Recollect.MigrationGenerator` currently generates the initial schema for new
installs. It must also support upgrades:

```elixir
# New install
Recollect.MigrationGenerator.generate_up(adapter, dimensions: 1536, features: :all)

# Upgrade from 0.6.0
Recollect.MigrationGenerator.generate_upgrade(adapter,
  from: "0.6.0",
  to: "0.8.0",
  dimensions: 1536
)
```

Add a Mix task:

```bash
mix recollect.gen.migration --dimensions 1536 --features all
mix recollect.gen.upgrade --from 0.6.0 --to 0.8.0
```

The generated upgrade migration must be **idempotent** where possible
(`CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`) and must print a
warning for operations that require a table rewrite.

### 5.6 Indexes and query patterns

| Query | Index |
|---|---|
| Recent live entries in a scope | `(scope_id, inserted_at DESC) WHERE deleted_at IS NULL AND entry_type != 'archived'` |
| Tag filter | `recollect_entry_tags (scope_id, tag)` |
| Source dedup | `(source, source_id) WHERE source_id IS NOT NULL` |
| Evidence lookup | `recollect_evidence (entry_id)` |
| Event timeline | `(scope_id, occurred_at DESC)` |
| Page by slug | `(scope_id, slug)` |
| Page sources | `recollect_page_sources (page_id)` |
| Recall by anchor | `(anchor_type, anchor_value)` |
| Dream idempotency | `(scope_id, input_hash)` |
| Superseded exclusion | Add `recollect_edges (target_entry_id, relation)` |

---

## 6. Public API changes

### 6.1 `Recollect.Knowledge`

#### `remember/2`

Existing options remain. New options:

| Option | Type | Default | Meaning |
|---|---|---|---|
| `:tags` | `[String.t()]` | `[]` | Persisted in `recollect_entry_tags` |
| `:memory_level` | `:global \| :workspace \| :session \| :agent` | `:workspace` | Scope of applicability |
| `:stability` | `:stable \| :evolving \| :volatile` | `:evolving` | Decay profile |
| `:epistemic` | `:observed \| :inferred \| :held` | `:inferred` | Trust basis |
| `:valid_from` | `DateTime.t()` | `nil` | When the claim became true |
| `:valid_to` | `DateTime.t()` | `nil` | When it stopped being true |
| `:verification` | `String.t()` | `"none"` | `user \| test \| code_ref \| llm \| cross_session` |
| `:verified_at` | `DateTime.t()` | `nil` | When it was verified |
| `:evidence` | `[map()]` | `[]` | `%{event_id, relation, excerpt, source_type, source_ref}` |
| `:dedupe` | `:skip \| :update \| :error` | `:skip` | Behavior on `(source, source_id)` conflict |
| `:context` | `map() \| :auto \| :none` | `:auto` | Replaces `:context_hints` (alias kept) |
| `:defer_enrichment` | `boolean()` | `true` | Skip mipmaps/schema-fit content scan |

Returns `{:ok, %Entry{}} | {:error, Ecto.Changeset.t()}`.

```elixir
Recollect.Knowledge.remember(
  "Billing retries use exponential backoff capped at 60s.",
  scope_id: scope_id,
  owner_id: owner_id,
  tags: ["billing", "retries", "gotcha"],
  entry_type: "note",
  memory_level: :workspace,
  stability: :stable,
  epistemic: :observed,
  verification: "code_ref",
  evidence: [%{source_type: "file", source_ref: "lib/billing/retry.ex:42", relation: "supports"}],
  source: "agent",
  source_id: "session-123:turn-7"
)
```

#### Other functions

| Function | Change |
|---|---|
| `forget/1` | Soft delete (`deleted_at`) by default; `forget/2` with `hard: true` physically deletes |
| `recent/2`, `recent_by_owner/2` | Exclude `deleted_at` and `archived` |
| `supersede/3` | Keep the old row; set `valid_to`; create a reconciliation; never store `0.0` half-life |
| `review/2` | New: return review candidates with reasons |
| `explain/1` | New: return sources, usage, verification, and a human-readable why |
| `tags/1` | New: list tags for an entry |
| `add_evidence/2` | New: link evidence to an entry |
| `history/1` | New: version/supersession history |

#### `review/2` shape

```elixir
Recollect.Knowledge.review(scope_id, limit: 20)
# => {:ok, [
#   %{entry: %Entry{}, reasons: [:never_retrieved, :unverified], suggested: :archive},
#   %{entry: %Entry{}, reasons: [:duplicate], suggested: :merge}
# ]}
```

#### `explain/1` shape

```elixir
Recollect.Knowledge.explain(entry_id)
# => {:ok, %{
#   entry: %Entry{},
#   evidence: [%{relation: "supports", source_type: "file", source_ref: "..."}],
#   used_by: [%{scope_id: ..., at: ...}],
#   verification: "code_ref",
#   verified_at: ~U[...],
#   supersedes: [...],
#   superseded_by: nil,
#   why: "Observed in lib/billing/retry.ex:42; retrieved 12 times."
# }}
```

### 6.2 `Recollect.Search`

```elixir
Recollect.Search.search("why does billing retry fail?",
  scope_id: scope_id,
  mode: :hybrid,              # :vector | :lexical | :hybrid
  budget_tokens: 1_500,
  include_pages: true,
  include_brief: false,
  anchors: [path: "lib/billing/retry.ex"],
  rerank: false,
  diversity: true,
  limit: 20
)
```

Result shape (additive; legacy keys remain):

```elixir
{:ok, %{
  items: [
    %{
      id: "...",
      kind: :entry | :page | :chunk,
      text: "...",
      score: 0.87,
      sources: [:vector, :lexical],
      citations: ["entry:..."],
      estimated_tokens: 42,
      memory_level: :workspace
    }
  ],
  chunks: [...],             # legacy
  entries: [...],            # legacy
  related_entries: [...],    # legacy
  entities: [...],
  relations: [...],
  query: "...",
  resolved_tier: :both,
  resolved_mode: :hybrid,
  budget: %{max_tokens: 1500, used_tokens: 1420, truncated: false},
  candidates_considered: 84
}}
```

### 6.3 `Recollect.Brief`

```elixir
{:ok, brief} =
  Recollect.Brief.build(scope_id,
    token_budget: 1_500,
    include: [:rules, :focus, :traps, :open_questions, :index],
    format: :markdown,
    session_id: session_id
  )

brief.text          # rendered Markdown
brief.items         # selected items with citations and token counts
brief.used_tokens
brief.truncated?
```

`Brief.render/2` re-renders a built brief in another format (`:markdown`,
`:text`, `:json`). `Brief.invalidate/1` clears the cache for a scope.

### 6.4 `Recollect.Recall`

```elixir
{:ok, items} = Recollect.Recall.for_path("lib/recollect/consolidation.ex", scope_id)
{:ok, items} = Recollect.Recall.for_symbol("Recollect.Consolidation.run/1", scope_id)
:ok = Recollect.Recall.index(entry_id, anchors: [
  %{type: :path, value: "lib/recollect/consolidation.ex", confidence: 0.9},
  %{type: :symbol, value: "Recollect.Consolidation.run/1", confidence: 0.8}
])
```

Each item is a small map with `:text`, `:entry_id`, `:page_id`, `:anchor_type`,
`:confidence`, `:estimated_tokens`, and `:citations`.

### 6.5 `Recollect.Dream`

```elixir
{:ok, plan} = Recollect.Dream.plan(scope_id, stages: [:verify, :reconcile, :promote, :prune])
{:ok, run}  = Recollect.Dream.run(scope_id,
  dry_run: false,
  budget: [max_llm_tokens: 50_000, max_items: 500, max_wall_ms: 120_000],
  stages: [:verify, :reconcile, :promote, :prune]
)
run.id
run.status          # :done | :aborted | :failed
run.metrics         # %{verified: 12, reconciled: 3, promoted: 8, pruned: 4, ...}
```

### 6.6 `Recollect.Event` and `Recollect.Evidence`

```elixir
{:ok, event} = Recollect.Event.record(%{
  owner_id: owner_id,
  scope_id: scope_id,
  session_id: session_id,
  agent: "opencode",
  event_type: "tool_result",
  role: "tool",
  content: "...",
  occurred_at: DateTime.utc_now(),
  source_uri: "lib/foo.ex",
  source_ref: "42-60",
  metadata: %{}
})

{:ok, events} = Recollect.Event.list(scope_id, since: ~U[2026-11-01T00:00:00Z], limit: 100)

{:ok, evidence} = Recollect.Evidence.link(entry_id, event.id,
  relation: "supports",
  excerpt: "..."
)
```

### 6.7 `Recollect.Page`

```elixir
{:ok, page} = Recollect.Page.create(scope_id,
  slug: "billing/retries",
  title: "Billing retries",
  kind: :topic,
  body_md: "...",
  sources: [
    %{source_type: "entry", source_ref: entry_id, role: "primary"},
    %{source_type: "file", source_ref: "lib/billing/retry.ex:42", role: "supporting"}
  ]
)

{:ok, page} = Recollect.Page.get(page_id)
{:ok, pages} = Recollect.Page.list(scope_id, kind: :topic)
```

`Page.create/2` enforces the compression guard and the page cap.

### 6.8 Configuration reference

```elixir
config :recollect,
  # Phase 0
  mipmaps: [
    mode: :lazy,                    # :off | :lazy | :eager
    batch_embeddings: true
  ],
  context_detection: [
    mode: :cached,                  # :auto | :cached | :none
    ttl_ms: 60_000
  ],
  schema_fit: [
    content_sample_size: 50,
    async: true
  ],
  retrieval_strengthening: [
    half_life_boost_days: 2,
    flush_interval_ms: 30_000,
    max_half_life_days: 365
  ],
  guards: [
    enabled: true,                  # MEM-036 secret guard
    extra_patterns: []
  ],

  # Phase 1
  events: [
    enabled: true,
    retention_days: 30,
    max_content_bytes: 262_144
  ],
  memory: [
    default_level: :workspace,
    default_stability: :evolving,
    default_epistemic: :inferred
  ],
  staging: [
    retention_days: 7,              # MEM-040 durable staging
    max_items: 1_000
  ],

  # Phase 2
  brief: [
    token_budget: 1_500,
    max_items_per_section: 10,
    cache: true
  ],
  recall: [
    max_tokens: 200,
    max_items: 5
  ],

  # Phase 3
  dream: [
    enabled: false,
    max_llm_tokens: 50_000,
    max_items: 500,
    max_wall_ms: 120_000,
    lock_wait_ms: 0,                # 0 = fail fast with {:error, :locked}
    stages: [:verify, :reconcile, :promote, :prune]
  ],

  # Phase 4
  pages: [
    enabled: false,
    max_pages_per_scope: 100,
    compression_ratio: 0.5,
    min_source_tokens: 200
  ],

  # Phase 5
  retrieval: [
    mode: :hybrid,                  # :vector | :lexical | :hybrid
    keyword_fallback: true,         # MEM-038: like-search when embeddings are off
    rrf_k: 60,
    candidate_multiplier: 3,
    diversity: true,
    rerank: false,
    rerank_max_items: 20
  ]
```

All new config keys have defaults so existing hosts do not need to change
anything to upgrade.

---

## 7. Phased implementation

Each ticket below is intended to be independently reviewable. Estimates are ideal
engineering days for one senior Elixir engineer. "Files" lists the primary
touch points, not every file that may need a formatting or docs change.

---

### Phase 0 — Stabilize

**Objective:** make the existing memory lifecycle correct, persistent, and
observable. No new memory layer ships until this phase is green.

**Exit criteria:** see §1.3. **Estimated effort:** 23 ideal days.

#### MEM-001 — Fix consolidation struct construction and harden strength

- **Priority:** P0
- **Estimate:** 1 day
- **Depends on:** —
- **Files:** `lib/recollect/consolidation.ex`,
  `lib/recollect/strength.ex`, `test/recollect/consolidation_test.exs`,
  `test/recollect/strength_test.exs`

**Problem.** `Consolidation.fetch_entries/2` returns string-keyed maps.
`decay_pass/2` calls `struct(Recollect.Schema.Entry, entry)`, which ignores
string keys and produces a struct with every field `nil`. `Strength.calculate/2`
then calls `DateTime.diff(now, nil, :second)` and raises `FunctionClauseError`.
The result is a crash on any non-empty scope.

**Implementation.**

1. Replace the raw `SELECT` in `fetch_entries/2` with an Ecto query:
   ```elixir
   repo.all(
     from(e in Entry,
       where: e.scope_id == ^scope_id and e.entry_type != "archived" and is_nil(e.deleted_at)
     )
   )
   ```
   If raw SQL is retained for performance, load rows explicitly with
   `Ecto.Type.load/2` per field or `repo.load(Entry, row)` after converting keys
   to atoms; do not rely on `struct/2`.
2. In `Strength.decay_factor/2`:
   - `last = entry.last_accessed_at || entry.inserted_at || now`
   - `half_life = if is_number(entry.half_life_days) and entry.half_life_days > 0, do: entry.half_life_days, else: 7.0`
   - clamp `days` to `>= 0.0`
   - default `entry.confidence` to `1.0` when `nil`.
3. Add a regression test that inserts one entry, runs `Consolidation.run/1`,
   and asserts a non-error return and a `recollect_consolidation_runs` row.

**Tests.**

- One entry, default options: no raise, run record written.
- Pinned entry with `last_accessed_at: nil`: survives.
- Entry with `half_life_days: 0.0`: no `ArithmeticError`.
- `Strength.calculate/2` with all-nil timestamps: returns a float in `[0, 1]`.

**Acceptance.** The consolidation test passes on Postgres. `mix check` passes.

**Rollback.** Revert the commit; no schema change.

---

#### MEM-002 — Persist decay removals and report actual counts

- **Priority:** P0
- **Estimate:** 1 day
- **Depends on:** MEM-001
- **Files:** `lib/recollect/consolidation.ex`,
  `test/recollect/consolidation_test.exs`

**Problem.** `decay_pass/2` classifies entries as survivors/removed in memory,
but `run/1` only writes the count to `recollect_consolidation_runs`. Nothing is
archived or deleted. Entries below the threshold remain searchable forever.

**Implementation.**

1. Wrap the decay application and the run-record insert in a single
   `repo.transaction/1`.
2. Archive removed entries with `entry_type = "archived"` and `updated_at`;
   do not hard-delete in Phase 0.
3. Use the `{count, _}` returned by `update_all/3` as the `removed` metric.
4. Make `dry_run: true` skip both the archive and the run-record write (or write
   a `dry_run` record with zero effects; pick one and document it).
5. Do not call `SchemaIndex.rebuild/0` in dry-run mode.
6. Add a cleanup pass for edges/mipmaps of archived entries, or explicitly
   document that they are filtered out at read time (MEM-009 fixes the mipmap
   join).

**Tests.**

- Three entries with timestamps older than the threshold: all archived, count 3.
- Dry run: no rows change.
- A pinned entry above the threshold: not archived.
- A mixed set: only the expected entries are archived.

**Acceptance.** The run record's `removed` equals the number of archived rows.
A follow-up search does not return archived entries.

**Rollback.** Revert the commit; archived rows can be restored by setting
`entry_type = "note"` if needed.

---

#### MEM-003 — Fix consolidation pair generation and union-find grouping

- **Priority:** P0
- **Estimate:** 1.5 days
- **Depends on:** MEM-001
- **Files:** `lib/recollect/consolidation.ex`,
  `lib/recollect/conflict_detection.ex`,
  `test/recollect/consolidation_test.exs`

**Problem.** `merge_pass/4` calls `Enum.at(entries, i)` and `Enum.at(entries, j)`
inside an O(n²) pair loop. `Enum.at/2` on a list is O(i), so pair generation is
O(n³) in list traversal. `ConflictDetection.generate_pairs/1` has the same
pattern. `build_clusters/2` groups by the raw parent value instead of the
union-find root, so a chain `0 -> 1 -> 2` splits into multiple clusters.

**Implementation.**

1. Convert entries to a tuple once (`List.to_tuple/1`) and use `elem/2` in the
   pair loops, or use `:array`.
2. Fix `build_clusters/2`:
   ```elixir
   Enum.group_by(pairs, fn {key, _parent} -> find(parents, key) end)
   ```
   Ensure `find/2` performs path compression and handles a root whose parent is
   itself.
3. Make pair order deterministic (sort by entry id) so tests and conflict
   canonicalization are stable.
4. Fix `merged` to count clusters, not the flattened member count.
5. Add a `@tag :perf` test with 1,000 synthetic entries that asserts pair
   generation completes under a generous bound (e.g., 2 seconds) and does not
   time out.

**Tests.**

- Chain `0 -> 1 -> 2` produces one cluster.
- Two disjoint chains produce two clusters.
- 1,000 entries: no timeout; cluster count is stable.
- Pair order is deterministic across runs.

**Acceptance.** Clusters are correct for chain and star graphs; the perf test
passes on CI hardware or is explicitly excluded from the default suite.

**Rollback.** Revert the commit.

---

#### MEM-004 — Repair conflict detection and conflict persistence

- **Priority:** P0
- **Estimate:** 1.5 days
- **Depends on:** MEM-003 (for pair order), MEM-005 (for tags; can land with a
  content-only query first)
- **Files:** `lib/recollect/conflict_detection.ex`,
  `lib/recollect/conflicts.ex`,
  `test/recollect/conflict_detection_test.exs`

**Problem.** `get_active_entries/1` selects `tags_json`, a column that does not
exist, and passes `scope_id` as a string instead of `uuid_to_bin/1`. The query
errors, `entries` becomes `[]`, and `detect/1` returns `[]`. `Conflicts.persist/3`
uses `ON CONFLICT ... DO NOTHING`, so a resolved conflict never reopens, and
pair order is not canonicalized.

**Implementation.**

1. Replace the query with one that selects only existing columns:
   ```sql
   SELECT id, content FROM recollect_entries
   WHERE scope_id = $1 AND entry_type != 'archived' AND deleted_at IS NULL
   ORDER BY id
   ```
   Pass `Recollect.Util.uuid_to_bin(scope_id)`.
2. If tags are needed for the overlap gate, join `recollect_entry_tags` and
   aggregate tags per entry (after MEM-005), or pass a tag map separately.
3. Canonicalize each pair by id before insert:
   ```elixir
   {a, b} = if a.id <= b.id, do: {a, b}, else: {b, a}
   ```
4. Change `Conflicts.persist/3` to an upsert that updates `reason`, `score`,
   `updated_at`, and reopens a resolved conflict when it is detected again.
5. Add tests with two contradictory entries (`"feature X is enabled"` vs
   `"feature X is disabled"`), and one non-contradictory pair.
6. Add a test that running detection twice does not create duplicate rows.

**Tests.**

- Contradictory pair: one persisted conflict.
- Second run: still one conflict.
- Resolved conflict re-detected: status returns to `"open"`.
- Non-contradictory pair: no conflict.
- SQLite: the same tests pass or return `{:error, :unsupported_backend}` with a
  clear message.

**Acceptance.** `recollect_conflicts` is populated by consolidation; reruns are
idempotent.

**Rollback.** Revert the commit; persisted conflicts can be deleted by scope.

---

#### MEM-005 — Persist tags and implement tag filters

- **Priority:** P0
- **Estimate:** 3 days
- **Depends on:** —
- **Files:** `priv/repo/migrations/20261107000001_add_entry_tags.exs`,
  `lib/recollect/schema/entry_tag.ex`,
  `lib/recollect/schema/entry.ex`,
  `lib/recollect/knowledge.ex`,
  `lib/recollect/search/vector.ex`,
  `lib/recollect/migration_generator.ex`,
  `test/recollect/tags_test.exs`

**Problem.** `Knowledge.remember/2` reads `:tags` and never stores them.
`recollect_entries` has no tags column. `Search.Vector` documents `:tags`
filtering but never implements it. `ConflictDetection` and `SchemaIndex` expect
a nonexistent `tags_json`.

**Decision.** Use a normalized `recollect_entry_tags` table (see ADR-001/ADR-007)
rather than a Postgres array. It works on both backends and makes tag frequency
queries straightforward.

**Implementation.**

1. Migration:
   ```sql
   CREATE TABLE recollect_entry_tags (
     entry_id uuid NOT NULL REFERENCES recollect_entries(id) ON DELETE CASCADE,
     tag      text NOT NULL,
     scope_id uuid,
     PRIMARY KEY (entry_id, tag)
   );
   CREATE INDEX recollect_entry_tags_scope_tag_idx
     ON recollect_entry_tags (scope_id, tag);
   ```
2. Add `Recollect.Schema.EntryTag` with `entry_id`, `tag`, `scope_id`.
   Add `has_many :entry_tags, EntryTag` to `Recollect.Schema.Entry`.
3. In `Knowledge.remember/2`, insert the entry and tags in one
   `repo.transaction/1`. Normalize tags (trim, downcase, drop empty, dedupe).
4. Add `Knowledge.tags/1` and `Knowledge.set_tags/2`.
5. Implement `:tags` and `:tags_any` filters in
   `Search.Vector.build_entry_filters_pg/1` and
   `build_entry_filters_sqlite/1` using `EXISTS` subqueries.
6. Add `tags` to `Mipmap.generate_for/2` via an explicit argument; do not call
   `entry.tags` on an unloaded association.
7. Update `MigrationGenerator.generate_tier2_tables/3` and `generate_indexes/3`.
8. Backfill `metadata["tags"]` into the new table in a separate, batched
   migration task (see §11).

**Tests.**

- `remember(tags: ["Billing", "billing", ""])` stores one `"billing"` tag.
- Search with `tags: ["billing"]` returns only tagged entries.
- `tags_any: ["billing", "retries"]` returns the union.
- Deleting an entry cascades to tags.
- Migration generator output contains the new table and index.

**Acceptance.** Tags round-trip through write → search filter on Postgres and
SQLite.

**Rollback.** Drop the table and remove the association; no existing data is
modified.

---

#### MEM-006 — Make SchemaIndex scope-aware and move SchemaFit off the write path

- **Priority:** P1
- **Estimate:** 2 days
- **Depends on:** MEM-005
- **Files:** `lib/recollect/schema_index.ex`,
  `lib/recollect/schema_fit.ex`,
  `lib/recollect/knowledge.ex`,
  `lib/recollect/consolidation.ex`,
  `test/recollect/schema_fit_test.exs`

**Problem.** `SchemaIndex.rebuild/0` selects `tags_json`, scans all entries
across all scopes, and is only called by `Consolidation.run/1`, which crashes
before reaching it. `SchemaFit.compute/3` therefore always returns `0.5`. Once
the index is fixed, `SchemaFit` will tokenize up to 500 entries per write.

**Implementation.**

1. Rewrite `SchemaIndex.rebuild/1` to accept `scope_id: nil | id` and aggregate
   from `recollect_entry_tags` joined to live entries.
2. Store ETS keys as `{:tag_frequency, scope_id}` and `{:entry_count, scope_id}`,
   with a `nil` key for global fallback.
3. `SchemaFit.compute/3` looks up the scope index first, then the global index.
4. Split the computation:
   - `compute_tag_fit/3` — cheap, synchronous.
   - `compute_content_fit/3` — sampled (`schema_fit.content_sample_size`,
     default 50), async by default.
5. `Knowledge.remember/2` computes the tag fit synchronously and schedules the
   content fit on `Recollect.TaskSupervisor`; the entry is updated when it
   completes.
6. `Consolidation.run/1` calls `SchemaIndex.rebuild(scope_id: scope_id)` and not
   the global rebuild.
7. Add a test that a known tag produces a non-`0.5` fit and a 500-entry write
   does not tokenize all 500.

**Tests.**

- Rebuild for one scope does not include another scope's tags.
- `compute/3` returns `0.5` when the index is empty.
- Async content fit updates the row without blocking `remember/2`.
- 500 entries with `sample_size: 50`: at most 50 tokenizations.

**Acceptance.** `SchemaFit` returns non-neutral values for familiar tags, and
write latency stays within the §10 budget.

**Rollback.** Revert the commit; ETS state is rebuilt on boot.

---

#### MEM-007 — Flush actual retrieval counts

- **Priority:** P1
- **Estimate:** 1 day
- **Depends on:** —
- **Files:** `lib/recollect/retrieval_counter.ex`,
  `test/recollect/retrieval_counter_test.exs`

**Problem.** `do_flush/0` reads `{entry_id, count}` pairs from ETS but the SQL
ignores `count`, incrementing `access_count` by 1 per flush. A memory retrieved
200 times in a 30-second window gets `+1`.

**Implementation.**

1. Postgres: pass two arrays and use `unnest`:
   ```sql
   UPDATE recollect_entries AS e
   SET access_count = e.access_count + v.count,
       half_life_days = LEAST($4, e.half_life_days + $3 * v.count),
       last_accessed_at = $1,
       updated_at = $1
   FROM unnest($2::uuid[], $5::int[]) AS v(id, count)
   WHERE e.id = v.id
   ```
   Convert ids with `uuid_to_bin/1` if the column is `uuid`.
2. SQLite/libSQL: until MEM-011 lands, return `{:error, :unsupported_backend}`
   from the flush path instead of running Postgres SQL. MEM-011 adds the
   per-row transaction implementation and removes this guard.
3. Scale the half-life boost by count and cap at `max_half_life_days`
   (default 365).
4. Clear the ETS entries only after a successful flush; on failure, retain them
   for the next attempt.
5. Add a test that bumps one id 200 times, flushes, and asserts
   `access_count == 200`.

**Tests.**

- 200 bumps → one flush → 200.
- Two ids with different counts → each correct.
- Flush failure retains counters.
- Half-life is capped.

**Acceptance.** `access_count` equals the number of retrievals, modulo the
configured flush window.

**Rollback.** Revert the commit.

---

#### MEM-008 — Fix supersession half-life and harden strength

- **Priority:** P1
- **Estimate:** 1 day
- **Depends on:** MEM-001
- **Files:** `lib/recollect/knowledge.ex`,
  `lib/recollect/strength.ex`,
  `test/recollect/supersede_test.exs`,
  `test/recollect/strength_test.exs`

**Problem.** `Knowledge.supersede/3` writes `half_life_days: 0.0`. `0.0` is
truthy in Elixir, so `Strength.decay_factor/2` computes `days / 0.0` and raises
`ArithmeticError`.

**Implementation.**

1. Store `half_life_days: 0.01` (or a configurable `superseded_half_life`) and
   `confidence: 0.0`; keep `keep_strength: true` behavior.
2. Add `valid_to: DateTime.utc_now()` when the field exists (Phase 1); until
   then, keep the metadata stamp.
3. In `Strength.decay_factor/2`, guard `half_life <= 0` as described in
   MEM-001. This is defense in depth.
4. Add a test that calculates strength on a superseded entry and asserts a
   float near zero, not a raise.

**Tests.**

- Supersede → `Strength.calculate/2` returns a float.
- `keep_strength: true` preserves the original half-life.
- Superseded entries are excluded from default search.

**Acceptance.** No arithmetic exceptions on superseded entries.

**Rollback.** Revert the commit; existing `0.0` rows are fixed by a data
migration that sets them to `0.01`.

---

#### MEM-009 — Make mipmaps lazy, batched, and query-embedding-aware

- **Priority:** P1
- **Estimate:** 2 days
- **Depends on:** MEM-001, MEM-005
- **Files:** `lib/recollect/mipmap/generator.ex`,
  `lib/recollect/pipeline/embedder.ex`,
  `lib/recollect/search/vector.ex`,
  `test/recollect/mipmap_test.exs`,
  `test/recollect/mipmap_persist_test.exs`

**Problem.** One `remember/2` can trigger 1 entry embedding + 4 mipmap
embeddings + 4 inserts + 4 updates. `Mipmap.retrieve/3` re-embeds the query that
`Vector.search/2` already embedded. `Mipmap.generate_for/1` references
`entry.tags`, which raises for a `%Entry{}` without the field. The mipmap join
does not exclude archived entries.

**Implementation.**

1. Add `mipmaps.mode` (`:off | :lazy | :eager`, default `:lazy`). In `:eager`
   mode, preserve current behavior for compatibility.
2. In `Mipmap.persist/1`, batch the four level texts into one
   `EmbeddingProvider.generate/1` call.
3. `Mipmap.retrieve/3` accepts `:query_embedding`; `Vector.search/2` passes the
   vector it already computed.
4. `Mipmap.generate_for/2` accepts `tags:` explicitly; never call `entry.tags`
   on an unloaded association.
5. Add `me.entry_type != 'archived' AND me.deleted_at IS NULL` to the mipmap
   join.
6. In `:lazy` mode, generate on first escalation and store; subsequent reads use
   the stored rows.
7. Update `Pipeline.Embedder.embed_entry_async/1` to respect the mode.

**Tests.**

- `remember/2` with `mode: :off` makes one entry embedding and no mipmap writes.
- `mode: :lazy` generates on first retrieval.
- `persist/1` makes one batched embedding call (use `EmbeddingMock` to count).
- `retrieve/3` with `query_embedding` makes zero embedding calls.
- Archived entries' mipmaps are excluded.

**Acceptance.** A single write no longer costs five embedding calls by default.

**Rollback.** Set `mipmaps.mode: :eager`; no schema change.

---

#### MEM-010 — Cache or make context detection opt-in

- **Priority:** P1
- **Estimate:** 1 day
- **Depends on:** —
- **Files:** `lib/recollect/context/detector.ex`,
  `lib/recollect/knowledge.ex`,
  `lib/recollect/search/vector.ex`,
  `test/recollect/context_test.exs`

**Problem.** `Knowledge.remember/2` and `Search.Vector.add_context_boost/1` call
`Detector.detect/0`, which shells out to `git rev-parse` and
`git remote get-url origin` on every write and search.

**Implementation.**

1. Add `Detector.detect_cached/0` with a TTL cache keyed by the current working
   directory. Use ETS or `:persistent_term`; default TTL 60 seconds.
2. Add `context_detection.mode` (`:auto | :cached | :none`, default `:cached`).
3. `Knowledge.remember/2` accepts `context: :auto | :none | map`. Keep
   `:context_hints` as a deprecated alias.
4. `Search.Vector` uses the cached detector.
5. Document that the detectors are not pure — they shell out.

**Tests.**

- Two calls within the TTL do not spawn a subprocess (inject a detector function
  or assert the cache hit).
- `context: :none` skips detection.
- `context: %{repo: "..."}` uses the provided map.

**Acceptance.** The common write/search path performs no git subprocess after
the first call in a TTL window.

**Rollback.** Set `context_detection.mode: :auto`; behavior returns to the old
path.

---

#### MEM-011 — Enforce backend parity or fail explicitly

- **Priority:** P1
- **Estimate:** 2.5 days
- **Depends on:** MEM-004, MEM-007
- **Files:** `lib/recollect/consolidation.ex`,
  `lib/recollect/conflicts.ex`,
  `lib/recollect/conflict_detection.ex`,
  `lib/recollect/handoff.ex`,
  `lib/recollect/confidence.ex`,
  `lib/recollect/outcome.ex`,
  `lib/recollect/invalidation.ex`,
  `lib/recollect/retrieval_counter.ex`,
  `lib/recollect/schema_index.ex`,
  `test/recollect/backend_parity_test.exs`,
  `.github/workflows/ci.yml` (or the host CI config)

**Problem.** Maintenance and feedback modules use Postgres-only `$1`
placeholders, `ANY()`, and `ILIKE` despite advertised SQLite/libSQL support. On
SQLite these fail, often silently.

**Implementation.**

1. Add a small helper module `Recollect.SQL`:
   - `placeholder(adapter, n)` delegates to `adapter.placeholder/1`.
   - `uuid_param(adapter, id)` uses `uuid_type/0`.
   - `in_list(adapter, values, start_index)` builds the right placeholder list.
   - `ci_like(adapter, column, value)` emits `ILIKE` on Postgres and
     `LOWER(column) LIKE LOWER(?)` on SQLite.
2. Convert straightforward queries to Ecto (`Conflicts`, `Handoff`,
   `Confidence`, `Outcome`, `Invalidation`, `RetrievalCounter`).
3. For raw SQL that must remain, build placeholders with the adapter.
4. If a feature is unsupported (e.g., advisory locks on SQLite), return
   `{:error, :unsupported_backend}` and document it.
5. Add a feature matrix to `docs/architecture.md` and the README.
6. Add a CI matrix: Postgres service + SQLite file/in-memory. Run the
   maintenance tests on both.

**Tests.**

- `Conflicts.list/1`, `Handoff.get/1`, `Confidence.verify/1`,
  `Outcome.good/1`, `Invalidation.run_from_git/1`, and
  `RetrievalCounter.flush/0` on SQLite either succeed or return a clear error.
- No `$1` remains in adapter-agnostic modules (grep test).
- CI matrix is green.

**Acceptance.** The supported-backend matrix is truthful, and failures are
explicit rather than silent.

**Rollback.** Revert the commits; the feature matrix docs are independent.

---

#### MEM-012 — Respect `since` in learning and deduplicate imports

- **Priority:** P1
- **Estimate:** 1.5 days
- **Depends on:** MEM-005 (for the source index; can land separately)
- **Files:** `lib/recollect/learning/coding_agent.ex`,
  `lib/recollect/learning/pipeline.ex`,
  `lib/recollect/learning/harvest.ex`,
  `lib/recollect/knowledge.ex`,
  `priv/repo/migrations/20261107000002_add_source_unique_index.exs`,
  `test/recollect/coding_agent_test.exs`,
  `test/recollect/learning_test.exs`

**Problem.** `fetch_since/2` ignores `since` (`def fetch_since(_since, scope_id)`),
so every pipeline run re-reads all sessions and re-inserts every record. There
is no dedup on `(source, source_id)`.

**Implementation.**

1. Thread `since` through `fetch_since/2` and filter session files/events by
   timestamp (or file mtime) before parsing.
2. Add a partial unique index:
   ```sql
   CREATE UNIQUE INDEX recollect_entries_source_idx
     ON recollect_entries (source, source_id)
     WHERE source_id IS NOT NULL;
   ```
3. In `Knowledge.remember/2`, implement `:dedupe`:
   - `:skip` — return the existing entry.
   - `:update` — update content/metadata and bump `version`.
   - `:error` — return `{:error, :duplicate}`.
4. Handle `Ecto.ConstraintError` as a race fallback.
5. Wire `Learning.Pipeline` to `Learner.Harvest`'s checkpointed path where
   possible.
6. Add a test that runs the pipeline twice over the same fixture and asserts one
   entry.

**Tests.**

- `since` filters out older events.
- Two runs produce one entry with `dedupe: :skip`.
- `dedupe: :update` bumps `version`.
- The unique index rejects a duplicate insert at the database level.

**Acceptance.** Repeated harvests are idempotent.

**Rollback.** Drop the index; revert the learner changes.

---

#### MEM-035 — Make `remember/2` never throw on disabled enrichment

- **Priority:** P0
- **Estimate:** 1 day
- **Depends on:** —
- **Files:** `lib/recollect/knowledge.ex`,
  `lib/recollect/pipeline/embedder.ex`,
  `lib/recollect/extraction/llm_json.ex`,
  `test/recollect/knowledge_test.exs`

**Problem.** When embeddings are unconfigured, the async enrichment path
throws `:disabled` *after* the entry row has been inserted. Hosts must wrap
every call in `catch :disabled` and treat the entry as stored-unembedded
(home degrades to ILIKE, AgentForge documents the catch in
`memory/recollect.ex`, ops_center gates on `embedding_enabled?/0`). This
violates the library's own "return tuples, never raise on expected paths"
convention.

**Implementation.**

1. Contain the disabled case inside `Pipeline.Embedder.embed_entry_async/1`:
   log at `:debug`, emit telemetry, return without throwing.
2. `Knowledge.remember/2` always returns `{:ok, entry}` once the row is
   committed. Callers who care query `Recollect.Config.embedding_enabled?/0`
   (unchanged) or read `entry.embedding_model_id`.
3. Apply the same containment to the extraction path: a missing `llm_fn` or
   an extraction failure must skip entity/relation extraction without raising
   or leaving a failed pipeline run in a retry loop.
4. Document the contract: "enrichment is best-effort; the write path is
   commit-first."

**Tests.**

- `remember/2` with embeddings disabled returns `{:ok, entry}`; no throw.
- `remember/2` with extraction unconfigured returns `{:ok, entry}`; no raise.
- Telemetry emitted for the skipped enrichment.
- An entry written while disabled is embedded by a later maintenance pass (or
  explicitly documented as not re-embedded).

**Acceptance.** All hosts can delete their `catch :disabled` workarounds.

**Rollback.** Revert the commit; hosts' workarounds still work.

---

#### MEM-036 — Engine-level secret guard

- **Priority:** P0
- **Estimate:** 1 day
- **Depends on:** —
- **Files:** `lib/recollect/guards.ex`,
  `lib/recollect/knowledge.ex`,
  `lib/recollect/config.ex`,
  `test/recollect/guards_test.exs`

**Problem.** Three deployments each carry a private
`possible_secret?/1` regex guard (home `memory.ex:218-226`, ops_center
`OpsCenter.Agent.Memory`, AgentForge's facade) because Recollect will happily
store an API key as a memory. The guard belongs in the engine: one
implementation, one place to audit.

**Implementation.**

1. Add `Recollect.Guards.possible_secret?/1` with default patterns: PEM
   private keys, `AKIA…`/`sk-…`-style tokens, `Bearer …`, generic
   `password=`/`token=`/`secret=` assignments, and high-entropy hex runs.
2. `Knowledge.remember/2` checks content and string metadata values before
   insert. On a hit, return `{:error, :possible_secret}`.
3. Opt-outs: `remember(..., allow_secrets: true)` for hosts that pre-scrub,
   and `config :recollect, guards: [enabled: false]` (default enabled) plus
   `guards: [extra_patterns: [...]]` for host-specific patterns.
4. `Sleep.distill/2` and `Learning` record paths run the same guard on
   distilled output, since extraction can reproduce secrets from transcripts.
5. Emit telemetry on rejections (host dashboards already want this signal).

**Tests.**

- A token-shaped string is rejected; the same string with
  `allow_secrets: true` is stored.
- Distilled output containing a key is rejected.
- `guards: [enabled: false]` disables the check.
- Custom patterns are honored.

**Acceptance.** Hosts delete their private regexes; one audit point remains.

**Rollback.** Set `guards: [enabled: false]`; no schema change.

---

#### MEM-037 — Migration status and upgrade generator

- **Priority:** P1
- **Estimate:** 2 days
- **Depends on:** —
- **Files:** `lib/mix/tasks/recollect.migration_status.ex`,
  `lib/mix/tasks/recollect.gen.upgrade.ex`,
  `lib/recollect/migration_generator.ex`,
  `priv/recollect_migrations.manifest.json` (new),
  `test/recollect/migration_status_test.exs`

**Problem.** Recollect's own `priv/repo/migrations` never run in a host;
hosts mirror them by hand. ops_center production ran three months missing
`recollect_mipmaps`, `recollect_conflicts`, `recollect_consolidation_runs`,
and `recollect_handoffs` (hourly patroni errors, quiet app logs). Nothing
tells a host its mirror is stale.

**Implementation.**

1. Ship a machine-readable manifest in the package:
   `priv/recollect_migrations.manifest.json`, one entry per migration with
   its version, name, and the tables/columns it creates or alters.
2. `mix recollect.migration_status`:
   - reads the host's `priv/repo/migrations` and the applied
     `schema_migrations` rows;
   - compares against the manifest;
   - prints a table: `applied / mirrored-not-applied / missing / unknown`;
   - exits non-zero when anything is `missing` so a gate step can fail the
     build.
3. `mix recollect.gen.upgrade --from VERSION [--to VERSION]` generates an
   additive migration skeleton from the manifest diff, using
   `IF NOT EXISTS` forms where the adapter supports them (see §5.5).
4. Document the host procedure: "bump the ref, run
   `mix recollect.migration_status`, mirror what it reports."
5. Optional: `--gate` flag emits `gate-report.json`-compatible output for
   kfos_upgrader's quality gate.

**Tests.**

- A fixture host with all migrations applied reports clean, exit 0.
- A fixture host missing one migration reports it, exit 1.
- The upgrade generator emits idempotent DDL for a known diff.
- The manifest parses and covers every migration shipped in the package.

**Acceptance.** `mix recollect.migration_status` is a one-command drift check
suitable for a FleetConformance gate step.

**Rollback.** Remove the tasks; the manifest is inert data.

---

### Phase 1 — Provenance

**Objective:** make every claim traceable to an event, file, test, or user
statement, and add the lifecycle fields needed for scoping and verification.

**Exit criteria:** see §1.3. **Estimated effort:** 17 ideal days.

#### MEM-013 — Add the event ledger and evidence tables

- **Priority:** P1
- **Estimate:** 4 days
- **Depends on:** MEM-005
- **Files:** `priv/repo/migrations/20261107000003_add_events_and_evidence.exs`,
  `lib/recollect/schema/event.ex`,
  `lib/recollect/schema/evidence.ex`,
  `lib/recollect/event.ex`,
  `lib/recollect/evidence.ex`,
  `lib/recollect/migration_generator.ex`,
  `test/recollect/event_test.exs`,
  `test/recollect/evidence_test.exs`

**Problem.** Raw transcripts are discarded after extraction, so there is
nothing to verify a claim against. Recollect cannot answer "why is this here?"
or "is this still true?"

**Implementation.**

1. Add `recollect_events` and `recollect_evidence` with the DDL in §5.2.
2. `Recollect.Event.record/1`:
   - validate `event_type`, `occurred_at`, `content` or `source_uri`;
   - compute `content_hash = :crypto.hash(:sha256, content || source_uri || source_ref)`;
   - insert with `on_conflict: :nothing` and return the existing row on
     conflict.
3. `Recollect.Event.list/2` with `:since`, `:until`, `:session_id`,
   `:event_type`, `:limit`, and `:order`.
4. `Recollect.Evidence.link/3` validates the relation
   (`supports | contradicts | derived_from | supersedes`) and dedupes on
   `(entry_id, relation, source_type, source_ref)`.
5. `Recollect.Evidence.for_entry/1` returns evidence joined to events.
6. Do **not** embed events by default. Add an opt-in `Event.embed/2` later if
   transcript search needs it.
7. Add retention: `Event.prune/1` deletes events older than
   `events.retention_days`, but only if they are not referenced by evidence
   (`ON DELETE SET NULL` handles the rest).

**Tests.**

- Recording the same event twice returns one row.
- `content_hash` is stable across runs.
- Evidence links round-trip.
- Deleting an event nullifies the evidence link but keeps the claim.
- Retention prunes old events and leaves referenced claims intact.

**Acceptance.** A claim can be traced to at least one event or file reference.

**Rollback.** Drop both tables; no existing data is modified.

---

#### MEM-014 — Add lifecycle fields to entries

- **Priority:** P1
- **Estimate:** 2.5 days
- **Depends on:** MEM-013
- **Files:** `priv/repo/migrations/20261107000004_add_entry_lifecycle_fields.exs`,
  `lib/recollect/schema/entry.ex`,
  `lib/recollect/knowledge.ex`,
  `lib/recollect/search/vector.ex`,
  `lib/recollect/search.ex`,
  `lib/recollect/migration_generator.ex`,
  `test/recollect/knowledge_test.exs`,
  `test/recollect/search_test.exs`

**Problem.** Entries have no memory level, stability, epistemic status,
validity window, verification, version, or tombstone.

**Implementation.**

1. Add the columns from §5.2 with safe defaults.
2. Extend `Entry.changeset/2` casts and validations:
   - `memory_level in ~w(global workspace session agent)`
   - `stability in ~w(stable evolving volatile)`
   - `epistemic in ~w(observed inferred held)`
   - `verification` is a free string validated against a known set.
3. `Knowledge.remember/2` accepts the new options and sets defaults.
4. `Knowledge.forget/1` sets `deleted_at` and returns `{:ok, entry}`;
   `forget/2` with `hard: true` deletes.
5. Search and `recent/2` exclude `deleted_at IS NOT NULL` and `archived`.
6. Add a `live/1` Ecto query helper to avoid repeating the predicate.
7. Backfill defaults in the migration (Postgres fast defaults; SQLite rebuild
   if necessary).

**Tests.**

- `remember(memory_level: :global, stability: :stable, epistemic: :observed)`
  round-trips.
- `forget/1` hides the entry from search but keeps the row.
- `forget(hard: true)` removes it.
- Invalid enum values return a changeset error.

**Acceptance.** The new fields are queryable and enforced.

**Rollback.** Drop the columns; soft-deleted rows become visible again, so
document the risk before rolling back.

---

#### MEM-015 — Make ingestion idempotent end to end

- **Priority:** P1
- **Estimate:** 2 days
- **Depends on:** MEM-012, MEM-014
- **Files:** `lib/recollect/knowledge.ex`,
  `lib/recollect/learning/harvest.ex`,
  `lib/recollect/learning/pipeline.ex`,
  `test/recollect/learning_test.exs`

**Problem.** Even with the unique index, concurrent harvest runs can race, and
the pipeline has no consistent upsert semantics. A retry can duplicate or
partially update.

**Implementation.**

1. Wrap `remember/2`'s entry + tags + evidence writes in a single
   `Ecto.Multi`.
2. Implement `:dedupe` modes as described in MEM-012, including the
   constraint-error fallback.
3. Add an `ingest_batch/2` API that accepts records and returns
   `%{inserted: n, updated: n, skipped: n, failed: n}`.
4. Make `Learning.Harvest` pass stable `source`/`source_id` values
   (`agent`, session id + turn id).
5. Add a checkpoint assertion: a second run with the same checkpoint is a no-op.

**Tests.**

- Batch with duplicate records: one inserted, one skipped.
- Concurrent inserts of the same `(source, source_id)` do not raise; one wins.
- `:update` mode updates content and version.

**Acceptance.** Harvesting the same session twice is a no-op.

**Rollback.** Revert the commit; the unique index remains useful.

---

#### MEM-016 — Write events from the learning pipeline

- **Priority:** P1
- **Estimate:** 3 days
- **Depends on:** MEM-013, MEM-015
- **Files:** `lib/recollect/learning/harvest.ex`,
  `lib/recollect/learning/coding_agent.ex`,
  `lib/recollect/learning/coding_agent/*.ex`,
  `lib/recollect/learning/consent.ex`,
  `test/recollect/harvest_test.exs`

**Problem.** The learning pipeline extracts records and discards the raw
events. Dreaming cannot verify claims against a transcript that no longer
exists.

**Implementation.**

1. Extend the harvest record shape with an `:events` list (or write events
   before extraction and pass their IDs).
2. For each extracted record, write the supporting events and link them with
   `Evidence.link/3`.
3. Respect `Learner.Consent` exactly as the existing pipeline does; do not
   store events for a provider the user has not authorized.
4. Add `events.retention_days` and `events.max_content_bytes` enforcement at
   write time (truncate with a marker, do not silently drop).
5. Provide a `:collect` sink that returns events and records for host-side
   processing.

**Tests.**

- A harvested record has at least one evidence row.
- A denied provider writes no events.
- Oversized content is truncated and marked.
- Retention prune does not remove an event still referenced by evidence.

**Acceptance.** New claims from the learning pipeline are traceable.

**Rollback.** Disable `events.enabled`; the pipeline falls back to records-only.

---

#### MEM-017 — Add review and explain APIs

- **Priority:** P2
- **Estimate:** 2.5 days
- **Depends on:** MEM-013, MEM-014
- **Files:** `lib/recollect/review.ex`,
  `lib/recollect/knowledge.ex`,
  `test/recollect/review_test.exs`

**Problem.** There is no API for the hygiene loop that HN users describe:
review, prune, promote, and answer "why is this here?"

**Implementation.**

1. `Knowledge.review(scope_id, opts)` returns candidates with reasons:
   - `:never_retrieved` — `access_count == 0` and older than N days.
   - `:stale` — `Confidence.resolve_state/1 == "stale"`.
   - `:unverified` — `verification == "none"` and `epistemic != "observed"`.
   - `:duplicate` — same `source_id` or high text overlap.
   - `:orphan_summary` — `entry_type == "summary"` with no `derived_from`
     edges.
   - `:expired` — `valid_to < now`.
2. Each candidate has a `:suggested` action: `:keep | :archive | :merge |
   :verify | :delete`.
3. `Knowledge.explain(entry_id)` returns evidence, usage, verification,
   supersession links, and a human-readable `:why`.
4. Add telemetry for review queries and actions.

**Tests.**

- An entry with no evidence and no accesses is flagged `:never_retrieved` and
  `:unverified`.
- An entry with evidence and a recent access is not flagged.
- `explain/1` includes the evidence list and a non-empty `:why`.

**Acceptance.** A host can build a review UI from these two functions.

**Rollback.** Remove the module; no schema change.

---

#### MEM-038 — Keyword fallback in search

- **Priority:** P1
- **Estimate:** 2 days
- **Depends on:** —
- **Files:** `lib/recollect/search/vector.ex`,
  `lib/recollect/search.ex`,
  `lib/recollect/config.ex`,
  `test/recollect/search_fallback_test.exs`

**Problem.** `Search.search/2` requires embeddings: with embeddings disabled
it errors or returns empty, so every host has written its own scoped ILIKE
fallback (home `memory.ex:75-86`, AgentForge `memory/recollect.ex:237-265`,
ops_center documents a degraded mode). The engine should degrade, not the
hosts.

**Implementation.**

1. Add `retrieval.keyword_fallback: true` (default `true`): when embeddings
   are disabled **or** the vector query returns fewer than `limit / 3`
   results, run a lexical-lite query — `ILIKE` on `content` and `summary`
   (adapter-aware casing per MEM-011), scope- and owner-filtered, ordered by
   `updated_at DESC, access_count DESC`, limited to the requested `limit`.
2. Merge results: vector hits first, keyword hits appended (deduped by id);
   never silently replace good vector results.
3. Set `resolved_mode: :keyword_fallback | :vector | :both` in the result
   metadata so callers can see which path served the request.
4. Keep `embedding_enabled?/0` semantics unchanged; the fallback triggers
   automatically, no host branching.
5. Telemetry: `[:recollect, :search, :fallback]` with result count.

**Tests.**

- Embeddings disabled: search returns LIKE matches, `resolved_mode` set.
- Embeddings enabled, poor vector recall: keyword hits fill the gap.
- Scope isolation and `limit` respected on the fallback path.
- SQLite dialect: same tests pass (or explicit
  `{:error, :unsupported_backend}` before MEM-011 lands).

**Acceptance.** Hosts delete their ILIKE fallbacks; degraded mode is
engine-owned and observable.

**Rollback.** Set `retrieval.keyword_fallback: false`; hosts restore their
own fallbacks if needed.

---

#### MEM-039 — Project mapping from transcript cwd and git remote

- **Priority:** P1
- **Estimate:** 1 day
- **Depends on:** —
- **Files:** `lib/recollect/learning/project_mapping.ex`,
  `lib/recollect/learning/coding_agent/*.ex`,
  `test/recollect/project_mapping_test.exs`

**Problem.** `ProjectMapping` maps agent project keys to repos by word-level
matching on the *directory slug*. Sessions run from scratchpad worktrees are
stored under the wrong slug — e.g. kfos_upgrader work done under a
`-home-lenz-code-kfos-agent` scratchpad is harvested into the `kfos_agent`
scope — so lessons land in the wrong project memory and wrong-scope briefs
follow.

**Implementation.**

1. When parsing a session, prefer explicit provenance from the transcript
   itself: the session's `cwd` field (present in Claude Code, Codex, and
   OpenCode session JSON) and the git remote URL if the provider captured it.
2. Resolution order: git remote → repo name under `:code_root`; `cwd` →
   longest prefix matching a real checkout; directory-slug word matching
   (current behavior) as the last resort; `nil`/unknown → `shared`.
3. Add a `project_key_override` opt to `Harvest.run/2` for scripted imports
   that already know the target project.
4. Log (not fail) when slug and cwd disagree — that log line is exactly the
   misattribution signal.
5. Keep the pure `matches_slug?/2` function for compatibility.

**Tests.**

- A session whose slug says `kfos-agent` but whose cwd is
  `/home/lenz/code/kfos_upgrader` maps to `kfos_upgrader`.
- A git remote wins over a mismatching cwd.
- Legacy slug-only sessions still map as before (regression).
- Unknown cwd and no remote → `shared`.

**Acceptance.** Harvested lessons land in the scope of the repo they were
produced in, not the scope of the worktree's parent slug.

**Rollback.** Revert the resolution-order change; slug matching resumes.

---

### Phase 2 — Brief and recall

**Objective:** make the injected layer small, cited, and precise, and add
just-in-time recall keyed by path/symbol.

**Exit criteria:** see §1.3. **Estimated effort:** 17 ideal days.

#### MEM-018 — Add token estimation and budget primitives

- **Priority:** P1
- **Estimate:** 2 days
- **Depends on:** —
- **Files:** `lib/recollect/tokenizer.ex`,
  `lib/recollect/budget.ex`,
  `test/recollect/tokenizer_test.exs`

**Problem.** There is no token budget anywhere in the retrieval or injection
path.

**Implementation.**

1. `Recollect.Tokenizer.estimate/1`:
   - default `ceil(String.length(text) / 4)`;
   - optional `:tokenizer_fn` in config for an exact tokenizer;
   - `estimate_many/1` returns a list.
2. `Recollect.Budget.fit/3`:
   - input: items with `:estimated_tokens`, `:priority`, `:score`;
   - sort by priority, then score, then recency;
   - greedily include until the budget is exhausted;
   - return `%{items: ..., used: ..., truncated: boolean, dropped: ...}`.
3. Never truncate an item mid-sentence; drop it whole and leave a citation.
4. Add a configurable reserve (default 10%) for the renderer's scaffolding.

**Tests.**

- Estimation is deterministic.
- Budget never exceeds the cap.
- Higher-priority items win.
- A single oversized item is dropped, not sliced.

**Acceptance.** Other modules can share one token model.

**Rollback.** Remove the modules; no schema change.

---

#### MEM-019 — Implement `Recollect.Brief`

- **Priority:** P1
- **Estimate:** 4 days
- **Depends on:** MEM-014, MEM-018
- **Files:** `lib/recollect/brief.ex`,
  `lib/recollect/brief/renderer.ex`,
  `lib/recollect/brief/selector.ex`,
  `test/recollect/brief_test.exs`

**Problem.** The injected layer is a search dump with no budget, no citations,
and no stable structure.

**Implementation.**

1. `Brief.build(scope_id, opts)` selects items from:
   - **Rules** — `entry_type` rule or tags `["rule", "convention"]`, stability
     `stable`, highest verification.
   - **Focus** — latest handoff, session notes, open questions.
   - **Traps** — tags `["gotcha", "trap", "incident"]`, negative valence,
     high retrieval.
   - **Open questions** — `epistemic: "held"` or unresolved reconciliations.
   - **Index** — pages and summaries with slugs/paths, not full bodies.
2. Rank within each section by verification, stability, recency, and retrieval
   count; dedupe across sections by entry/page ID.
3. Render Markdown with a header showing the budget:
   ```markdown
   ## Memory brief (workspace: acme, 1,420 / 1,500 tokens)
   ### Rules (stable)
   - Always run `mix format` before committing. [e1, verified 2026-10-12]
   ```
4. Every item includes a citation like `[e12]`, `[p3]`, or `[h1]`.
5. Cache keyed by `(scope_id, generation, budget)`; bump a generation counter on
   writes and dream runs. `Brief.invalidate/1` clears it.
6. `Brief.render/2` supports `:markdown`, `:text`, and `:json`.
7. If the budget is too small for any item, return an explicit
   `{:ok, %{text: "", truncated: true, dropped: ...}}`, not a partial sentence.

**Tests.**

- The rendered text is under the budget for 1, 10, and 100 candidate items.
- Every item has a citation.
- Stable items appear before volatile ones.
- Cache invalidation after a write changes the output.
- JSON render includes item IDs and token counts.

**Acceptance.** A session can start with a cited brief under 1,500 tokens.

**Rollback.** Disable `brief.enabled`; callers fall back to `ContextFormatter`.

---

#### MEM-020 — Add budget, dedupe, and citations to `ContextFormatter`

- **Priority:** P1
- **Estimate:** 2 days
- **Depends on:** MEM-018, MEM-019
- **Files:** `lib/recollect/search/context_formatter.ex`,
  `test/recollect/context_formatter_test.exs`

**Problem.** `format/1` concatenates every section, truncates entries to 200
characters, includes up to 20 entities and 20 relations, and does not dedupe
entries against related entries.

**Implementation.**

1. Add `format/2` with `:max_tokens`, `:dedupe`, `:citations`, and `:format`.
2. Convert the pack to a unified item list, dedupe by id, rank by score, and
   fit to the budget with `Recollect.Budget`.
3. Use `summary` when available; use full content only if the budget allows.
4. Attach citation IDs (`[e12]`, `[c3]`, `[p1]`).
5. Keep `format/1` as a backwards-compatible wrapper with no budget.
6. Return `{:ok, text, metadata}` from a new `format_with_meta/2` so callers can
   see `:used_tokens`, `:truncated`, and `:dropped`.

**Tests.**

- A pack with 100 entries returns text under the budget.
- Duplicate entry/related-entry IDs appear once.
- Citations are present.
- `format/1` output is unchanged for a small pack (golden test).

**Acceptance.** Search results and the brief share one token model.

**Rollback.** Revert the commit; `format/1` remains.

---

#### MEM-021 — Add recall anchors and `Recall.for_path/2`

- **Priority:** P2
- **Estimate:** 4 days
- **Depends on:** MEM-014, MEM-018
- **Files:** `priv/repo/migrations/20261107000005_add_recall_anchors.exs`,
  `lib/recollect/schema/recall_anchor.ex`,
  `lib/recollect/recall.ex`,
  `lib/recollect/search.ex`,
  `test/recollect/recall_test.exs`

**Problem.** Recollect has no path/symbol anchor index, so it cannot inject a
small memory block when an agent touches a file.

**Implementation.**

1. Add `recollect_recall_anchors` with `anchor_type` (`path | symbol | module |
   function | route | table | config_key | error`), `anchor_value`,
   `confidence`.
2. `Recall.index(entry_id, anchors: [...])` inserts anchors idempotently.
3. `Recall.for_path(path, scope_id)` matches exact path, then prefix, then
   basename; returns entries/pages with confidence and a small text excerpt.
4. `Recall.for_symbol(symbol, scope_id)` matches module/function strings.
5. Integrate anchors as an optional candidate source in `Search.search/2`
   (`anchors: [path: ...]`); give a modest score boost, not an override.
6. Add an index section to the brief with anchor IDs.
7. Backfill anchors from `metadata["path"]`, `metadata["file"]`, and evidence
   `source_type: "file"` rows.

**Tests.**

- Exact path hit returns the linked entry.
- Prefix/basename fallback works.
- A symbol hit returns the function-level note.
- Anchors do not leak across scopes.
- Search with `anchors:` boosts the anchored entry.

**Acceptance.** Touching a file can retrieve a cited block under 200 tokens.

**Rollback.** Drop the table; search behaves as before.

---

#### MEM-022 — Cap handoff and make working-memory promotion atomic

- **Priority:** P2
- **Estimate:** 2 days
- **Depends on:** MEM-019
- **Files:** `lib/recollect/handoff.ex`,
  `lib/recollect/working_memory.ex`,
  `lib/recollect/working_memory/server.ex`,
  `lib/recollect/sleep.ex`,
  `test/recollect/handoff_test.exs`,
  `test/recollect/sleep_test.exs`

**Problem.** `Handoff.create/2` stores unbounded JSON text. `WorkingMemory.load_handoff/1`
pushes every item into a 20-slot buffer at high importance, evicting real notes.
`Sleep.promote/1` reads then clears non-atomically and clears even when some
promotions fail.

**Implementation.**

1. Add `Handoff.create/2` budget checks (`brief.token_budget`); reject or
   truncate `next`/`artifacts`/`blockers` with an explicit marker.
2. `WorkingMemory.load_handoff/1` loads at most `brief.max_items_per_section`
   items and lower importance than session notes.
3. Add `WorkingMemory.Server.drain/1`:
   - a single `handle_call` swaps the list with `[]` and returns the old list;
   - no read/clear race.
4. `Sleep.promote/1` uses `drain/1`, persists each item, and re-inserts only the
   failed items (or returns them to the caller). It must not clear items it did
   not persist.
5. Attach `metadata.origin = "sleep"` and evidence/source IDs to promoted
   entries.
6. Document that working memory is ephemeral and not replicated.

**Tests.**

- A concurrent push during `promote/1` is not lost.
- A failed persist leaves the item in working memory.
- A large handoff does not evict the session's notes.
- A handoff over budget returns an error or a truncated result, explicitly.

**Acceptance.** No memory loss on partial failure or concurrent push.

**Rollback.** Revert the commit; the old behavior returns.

---

#### MEM-040 — Durable staging table for the working-memory tier

- **Priority:** P1
- **Estimate:** 3 days
- **Depends on:** MEM-014 (owner/scope columns and lifecycle conventions)
- **Files:** `priv/repo/migrations/20261107000010_add_staging.exs`,
  `lib/recollect/schema/staging.ex`,
  `lib/recollect/staging.ex`,
  `lib/recollect/sleep.ex`,
  `lib/recollect/working_memory.ex`,
  `lib/recollect/migration_generator.ex`,
  `test/recollect/staging_test.exs`

**Problem.** `Recollect.WorkingMemory` is an ephemeral, per-node GenServer.
Two deployments rejected it independently and built the same replacement:
ops_center's `agent_memory_staging` ("fine for a single session, wrong for a
fleet") and AgentForge's `forge_memory_staging` (modeled on ops_center's).
The durable staging tier belongs in the engine.

**Implementation.**

1. Add the table (see §5.2):
   ```sql
   CREATE TABLE recollect_staging (
     id          uuid PRIMARY KEY,
     owner_id    uuid NOT NULL,
     scope_id    uuid NOT NULL,
     content     text NOT NULL,
     metadata    jsonb NOT NULL DEFAULT '{}',
     source      text,
     priority    float NOT NULL DEFAULT 0.5,
     status      text NOT NULL DEFAULT 'staged',  -- staged | drained
     inserted_at timestamptz NOT NULL DEFAULT now(),
     drained_at  timestamptz
   );
   CREATE INDEX recollect_staging_scope_idx
     ON recollect_staging (scope_id, status, inserted_at);
   ```
2. `Recollect.Staging.stage/3` inserts a candidate note (runs
   `Guards.possible_secret?/1` unless disabled).
3. `Recollect.Staging.drain/2` atomically claims and returns staged rows for a
   scope (`status = 'drained'`, `drained_at` set) using a single
   `UPDATE ... WHERE id IN (SELECT ... FOR UPDATE SKIP LOCKED)` on Postgres
   and a transaction on SQLite, so two concurrent distillers cannot both
   claim the same rows.
4. `Recollect.Sleep.distill/2` gains a `from_staging: true` mode that drains,
   distills, promotes survivors via the normal write path, and marks failures
   back to `staged` for retry.
5. Retention: `staging.retention_days` (default 7) prunes drained rows;
   `staging.max_items` (default 1,000) caps backlog growth.
6. Deprecate `Recollect.WorkingMemory`: keep the module as a thin wrapper that
   stages then drains in-process, emit a deprecation warning, schedule removal
   for 1.0.
7. Add the table to `MigrationGenerator.generate_up/2`.

**Tests.**

- Stage/drain round-trip preserves content and metadata.
- Two concurrent drains claim disjoint rows (Postgres).
- A distill failure returns rows to `staged`.
- Retention prunes only drained rows past the window.
- Secret-guarded content never lands in the table.

**Acceptance.** ops_center and AgentForge can migrate their bespoke staging
tables onto `Recollect.Staging` and delete the duplicates.

**Rollback.** Stop using the table (hosts keep their own); drop it in a
follow-up migration.

---

### Phase 3 — Dreaming v1

**Objective:** add an idempotent, locked, budgeted offline consolidation
pipeline that verifies, reconciles, promotes, and prunes.

**Exit criteria:** see §1.3. **Estimated effort:** 19 ideal days.

#### MEM-023 — Add the `Recollect.Dream` orchestrator

- **Priority:** P1
- **Estimate:** 5 days
- **Depends on:** MEM-013, MEM-014, MEM-017
- **Files:** `priv/repo/migrations/20261107000006_add_dream_runs.exs`,
  `lib/recollect/schema/dream_run.ex`,
  `lib/recollect/dream.ex`,
  `lib/recollect/dream/run.ex`,
  `lib/recollect/dream/worker.ex`,
  `test/recollect/dream_test.exs`

**Problem.** Consolidation is a single broken batch job with no lock,
idempotency, budget, or stage-level metrics. There is no orchestration for
verification or reconciliation.

**Implementation.**

1. Add `recollect_dream_runs` with `scope_id`, `input_hash`, `status`, `stages`,
   `metrics`, `started_at`, `finished_at`, `error`.
2. `Dream.plan/2` returns the work it would do without writing.
3. `Dream.run/2`:
   - compute `input_hash` from the event-ledger high-water mark (latest event id
     plus event count), the config version, and the requested stages. Do **not**
     include entry `updated_at`: dream runs mutate entries, so that would make
     every rerun look like new input. If events are disabled, require an
     explicit `idempotency_key` option instead;
   - if a `:done` run exists for the same hash and `force: false`, return it.
     The idempotency index is partial (`WHERE status = 'done'`), so failed and
     aborted runs never block a retry;
   - acquire a per-scope lock for the **whole run**: check out a dedicated
     connection with `repo.checkout/2` and call `pg_try_advisory_lock(key)` on
     it (`pg_try_advisory_xact_lock` would be released at the end of the first
     stage transaction). With `dream.lock_wait_ms > 0`, use
     `pg_advisory_lock` plus `SET LOCAL lock_timeout` instead. On SQLite, wrap
     the run in `:global.trans/3` plus a DB transaction (single-node only);
   - execute stages in order, each stage in its own transaction, checking the
     budget between items;
   - record metrics and completion per stage;
   - on failure, mark `:failed`, roll back only the failing stage, and record
     which stages completed so a rerun can resume.
4. `Dream.Worker` is a behaviour with `perform/1`; provide an Oban example in
   the docs but no dependency.
5. Add `Dream.status/1` and `Dream.cancel/1` (best effort; a running stage
   checks a cancellation flag).
6. Dry run returns the plan and metrics, writes no entries/pages, and does not
   bump the generation counter.

**Tests.**

- Same input hash twice: second run returns the first without work.
- A failed or aborted run can be retried with the same hash.
- Two concurrent runs: one gets `{:error, :locked}`.
- Budget exceeded: status `:aborted`, stops at a stage boundary, no half-finished
  stage writes.
- Stage failure: the failing stage's writes are absent; earlier stages are
  recorded as completed and the run is resumable.
- Dry run writes nothing.

**Acceptance.** Dreaming is safe to retry and safe to run concurrently.

**Rollback.** Disable `dream.enabled`; the tables can remain unused.

---

#### MEM-024 — Implement the verify stage

- **Priority:** P1
- **Estimate:** 5 days
- **Depends on:** MEM-023
- **Files:** `lib/recollect/dream/verify.ex`,
  `lib/recollect/evidence.ex`,
  `test/recollect/dream_verify_test.exs`

**Problem.** Claims can be wrong from the start or drift, and there is no
mechanism to check them against evidence.

**Implementation.**

1. For each claim with evidence:
   - `source_type: "event"` — event exists and is not pruned.
   - `source_type: "file"` — file exists; optional line-range/hash check.
   - `source_type: "test"` — record the test result and timestamp.
   - `source_type: "user"` — treat as authoritative, but record who/when.
   - `source_type: "url"` — optional HTTP check behind a config flag.
2. Set `verification` and `verified_at`; upgrade `epistemic` from `inferred` to
   `observed` only when direct evidence exists.
3. Downgrade to `held` or `stale` when evidence is missing; do not delete.
4. Batch checks and respect `dream.max_items` and `max_wall_ms`.
5. Emit telemetry per check and a summary.

**Tests.**

- File evidence that exists → verified.
- File evidence missing → `held`/`stale`, no delete.
- User evidence → verified with `verification: "user"`.
- Budget stops the stage cleanly.

**Acceptance.** A dream run can answer "which claims are no longer supported?"

**Rollback.** Disable the verify stage; claims keep their previous status.

---

#### MEM-025 — Implement the reconcile stage

- **Priority:** P1
- **Estimate:** 5 days
- **Depends on:** MEM-023, MEM-024, MEM-004
- **Files:** `priv/repo/migrations/20261107000007_add_reconciliations.exs`,
  `lib/recollect/schema/reconciliation.ex`,
  `lib/recollect/dream/reconcile.ex`,
  `lib/recollect/knowledge.ex`,
  `test/recollect/dream_reconcile_test.exs`

**Problem.** `Knowledge.supersede/3` overwrites the old claim and loses the
reasoning. Conflict detection is now fixed, but there is no reconciliation
record.

**Implementation.**

1. Add `recollect_reconciliations` with thesis/antithesis/synthesis IDs,
   `reasoning`, `unresolved`, and `status`.
2. For each detected conflict:
   - build a thesis/antithesis pair from the two claims;
   - attempt an LLM synthesis using the evidence; fall back to a conservative
     "both remain, unresolved" record;
   - create a synthesis claim only when the evidence supports it;
   - set `valid_to` on the losing claim (do not zero its half-life);
   - create a `supersedes` edge from synthesis → old claims.
3. Single-flight per pair; canonical order.
4. Persist the reconciliation even when unresolved, so the question is visible.
5. Emit telemetry: `conflicts_seen`, `reconciled`, `unresolved`.

**Tests.**

- Contradictory claims produce a reconciliation with both IDs.
- The old claim keeps its content and gets `valid_to`.
- An unresolved synthesis preserves the unanswered question.
- Rerunning does not duplicate the reconciliation.

**Acceptance.** Conflicts are reconciled with provenance, not overwritten.

**Rollback.** Disable the reconcile stage; existing claims remain.

---

#### MEM-026 — Implement promote and prune

- **Priority:** P1
- **Estimate:** 4 days
- **Depends on:** MEM-023, MEM-024, MEM-025
- **Files:** `lib/recollect/dream/promote.ex`,
  `lib/recollect/dream/prune.ex`,
  `lib/recollect/brief.ex`,
  `test/recollect/dream_promote_test.exs`

**Problem.** There is no mechanism to promote durable, useful claims into the
brief or to demote/prune low-value ones. Decay is time-only and does not use
outcomes.

**Implementation.**

1. Promotion score:
   ```
   score = 0.35 * verification
         + 0.25 * retrieval_recency
         + 0.20 * outcome
         + 0.10 * stability
         + 0.10 * conflict_resolution
   ```
   Weights are configurable.
2. Promote claims above a threshold into the brief's rule/trap/index sections
   (not into a separate store).
3. Demote claims that are stale, contradicted, or never retrieved; archive only
   after a grace period.
4. Prune:
   - duplicate events (by hash),
   - events past retention that are not referenced,
   - orphan summaries/pages with no sources,
   - expired volatile claims.
5. Never hard-delete an evidence-backed claim; tombstone with `deleted_at`.
6. Bump the brief generation counter after any promotion/prune.

**Tests.**

- A verified, frequently retrieved rule is promoted.
- A never-retrieved, unverified claim is demoted, not deleted.
- Prune removes only unreferenced events.
- Brief output changes after promotion.

**Acceptance.** The brief improves over time without manual curation.

**Rollback.** Disable promote/prune; the brief still works from existing data.

---

### Phase 4 — Pages

**Objective:** add cited, compression-guarded wiki pages that capture
cross-document structure and work with search. Page synthesis
(`Recollect.Dream.Synthesize`) joins the dream pipeline as an optional stage,
enabled with `pages.enabled`.

**Exit criteria:** see §1.3. **Estimated effort:** 13 ideal days.

#### MEM-027 — Add the page schema and CRUD

- **Priority:** P2
- **Estimate:** 2 days
- **Depends on:** MEM-013, MEM-014
- **Files:** `priv/repo/migrations/20261107000008_add_pages.exs`,
  `lib/recollect/schema/page.ex`,
  `lib/recollect/schema/page_source.ex`,
  `lib/recollect/page.ex`,
  `test/recollect/page_test.exs`

**Problem.** Recollect has no representation layer. Summaries are plain entries
with no slug, source hash, token count, or citations.

**Implementation.**

1. Add `recollect_pages` and `recollect_page_sources` from §5.2.
2. `Page.create/2` validates:
   - slug format (`[a-z0-9-/]+`),
   - at least one source,
   - `token_count` computed from the body,
   - unique `(scope_id, slug)`.
3. `Page.get/1`, `Page.list/2`, `Page.update/2`, `Page.delete/1` (soft delete
   optional).
4. Add `Page.sources/1` and `Page.citations/1`.
5. Do not generate pages automatically yet; this ticket is CRUD only.

**Tests.**

- Create/read/update/list.
- Duplicate slug returns a changeset error.
- A page with no sources is rejected.
- Deleting a page cascades to sources.

**Acceptance.** Pages are a first-class, queryable object.

**Rollback.** Drop the tables; no existing data is modified.

---

#### MEM-028 — Generate pages from claim clusters

- **Priority:** P2
- **Estimate:** 5 days
- **Depends on:** MEM-027, MEM-023
- **Files:** `lib/recollect/dream/synthesize.ex`,
  `lib/recollect/page.ex`,
  `lib/recollect/dream.ex`,
  `test/recollect/dream_synthesize_test.exs`

**Problem.** Consolidation merges entries into orphan summaries, not cited
pages. There is no cross-session synthesis.

**Implementation.**

1. Cluster claims by tags, entities, and path prefixes. Use blocking to avoid
   O(n²): group by primary tag/entity first, then compare within a block.
2. Require a minimum cluster size (e.g., 3 claims) and at least two distinct
   sources.
3. Generate a page with one of:
   - an LLM synthesis prompt that includes the claims and asks for citations;
   - a deterministic template fallback (bullets with citations).
4. One writer per page; use a per-page lock or a single-threaded dream stage.
5. Quote critical evidence verbatim; do not paraphrase contract-like facts.
6. Store `source_hash` and `version`; update incrementally instead of rebuilding
   from scratch when possible.
7. Emit telemetry: `pages_created`, `pages_updated`, `clusters_skipped`.

**Tests.**

- A cluster of three claims produces one page with three citations.
- A cluster from one source is skipped.
- A concurrent synthesis does not produce two pages for the same slug.
- The fallback template works without an LLM.

**Acceptance.** Pages capture cross-document structure with citations.

**Rollback.** Disable `pages.enabled`; generated pages remain readable.

---

#### MEM-029 — Enforce citations and the compression guard

- **Priority:** P2
- **Estimate:** 3 days
- **Depends on:** MEM-027, MEM-028
- **Files:** `lib/recollect/page.ex`,
  `lib/recollect/dream/synthesize.ex`,
  `test/recollect/page_guard_test.exs`

**Problem.** The article documents a wiki growing to 1.77× its corpus. Recollect
has no guard against synthesis bloat.

**Implementation.**

1. Every page must have at least one `page_source`; reject otherwise.
2. Compute source tokens from the cited entries/events.
3. Compression guard:
   ```
   page.token_count <= max(200, source_tokens * pages.compression_ratio)
   ```
   Default ratio `0.5`. A page that fails is rejected and the cluster is split
   or summarized more aggressively.
4. Page cap per scope (`pages.max_pages_per_scope`, default 100). On overflow,
   merge the lowest-value pages or refuse new ones with a clear error.
5. Add a `Page.check/1` function for dry-run validation.
6. Log a warning when a page is rejected; emit telemetry.

**Tests.**

- A page longer than the guard is rejected.
- A page with no sources is rejected.
- A page at the cap is refused or merged according to config.
- The guard uses the cited sources, not the whole corpus.

**Acceptance.** No page can exceed the compression guard.

**Rollback.** Set `pages.compression_ratio: 1.0` to relax; no data loss.

---

#### MEM-030 — Add page retrieval and search integration

- **Priority:** P2
- **Estimate:** 3 days
- **Depends on:** MEM-029, MEM-021
- **Files:** `lib/recollect/page.ex`,
  `lib/recollect/search.ex`,
  `lib/recollect/search/vector.ex`,
  `test/recollect/page_search_test.exs`

**Problem.** Pages are useless if retrieval cannot find them or fetch their
cited claims.

**Implementation.**

1. `Page.search(query, scope_id, opts)` uses title/summary vector similarity
   (and lexical in Phase 5).
2. `Search.search/2` with `include_pages: true` adds pages as a candidate
   source; dedupe against entries by citation.
3. `Search` result items of `kind: :page` include a `:summary` and a
   `:fetch_page` hint; the full body is not injected unless the budget allows.
4. `Page.get/1` returns the body plus cited claims/events for detail.
5. Add a page section to the brief index (slug + title + citation, no body).
6. Migrate existing consolidation summaries to pages only if they have
   `derived_from` edges; otherwise leave them as notes.

**Tests.**

- A page is returned for a matching query.
- A page hit includes citations.
- The full body is not injected when over budget.
- `include_pages: false` preserves the old behavior.

**Acceptance.** Wiki + search outperforms search-only on the eval set, or pages
stay disabled by default.

**Rollback.** Disable `pages.enabled`; search falls back to entries.

---

### Phase 5 — Hybrid retrieval and evaluation

**Objective:** make retrieval robust to exact names/symbols, fuse sources
properly, and prove that memory helps.

**Exit criteria:** see §1.3. **Estimated effort:** 16 ideal days.

#### MEM-031 — Add lexical indexes and search

- **Priority:** P2
- **Estimate:** 4 days
- **Depends on:** MEM-014
- **Files:** `priv/repo/migrations/20261107000009_add_lexical_indexes.exs`,
  `lib/recollect/search/lexical.ex`,
  `lib/recollect/migration_generator.ex`,
  `test/recollect/lexical_search_test.exs`

**Problem.** Vector-only retrieval misses exact identifiers, error strings, and
symbol names.

**Implementation.**

1. PostgreSQL:
   ```sql
   ALTER TABLE recollect_entries
     ADD COLUMN search_vector tsvector
     GENERATED ALWAYS AS (
       to_tsvector('english', coalesce(content, '') || ' ' || coalesce(summary, ''))
     ) STORED;
   CREATE INDEX recollect_entries_search_idx
     ON recollect_entries USING GIN (search_vector);
   ```
2. SQLite/libSQL: create an FTS5 table (`recollect_entries_fts`) keyed by
   `entry_id`, maintained by triggers or by `Knowledge` on write. If FTS5 is
   unavailable, return `{:error, :unsupported_backend}`.
3. `Search.Lexical.search(query, scope_id, opts)` returns items with
   `:lexical_score` and `source: :lexical`.
4. Keep the lexical query behind `retrieval.mode` (`:vector | :lexical |
   :hybrid`).
5. Add a migration-generator branch for both backends.

**Tests.**

- Exact identifier query returns the expected entry.
- Scope isolation.
- SQLite FTS5 returns the same logical result for the fixture.
- Missing FTS5 yields a clear error.

**Acceptance.** Lexical search works on both supported backends or fails
explicitly.

**Rollback.** Drop the index/FTS table; vector search remains.

---

#### MEM-032 — Fuse candidates with RRF and a global budget

- **Priority:** P2
- **Estimate:** 4 days
- **Depends on:** MEM-031, MEM-018, MEM-021
- **Files:** `lib/recollect/search.ex`,
  `lib/recollect/search/fusion.ex`,
  `lib/recollect/search/vector.ex`,
  `test/recollect/fusion_test.exs`,
  `test/recollect/search_test.exs`

**Problem.** `Search.search/2` applies `limit` per category and concatenates,
so a `limit: 10` request can return dozens of items with no global ranking.

**Implementation.**

1. Candidate generation:
   - vector over entries/pages/chunks (`k = limit * candidate_multiplier`);
   - lexical over entries/pages;
   - graph neighborhood from query entities;
   - recall anchors for the current path/symbol.
2. Fusion:
   - RRF with `k = 60` (configurable);
   - dedupe by `{kind, id}`;
   - diversity: max 2 items per `entry_type` unless the caller opts out.
3. Apply a global `limit` and then `Recollect.Budget.fit/3` for tokens.
4. Result shape: add `:items`, `:budget`, `:candidates_considered`,
   `:resolved_mode`; keep legacy keys for compatibility.
5. `mode: :vector` preserves the old behavior exactly.
6. Add a `:debug` option that returns the per-source ranks (never in
   production).

**Tests.**

- `limit: 10` returns at most 10 items across all sources.
- RRF puts an item found by two sources above an item found by one.
- Deduping removes the same entry returned by vector and lexical.
- Budget truncation is reported.
- `mode: :vector` matches the legacy result set on a fixture.

**Acceptance.** One global ranking, one global budget, no category bias.

**Rollback.** Set `retrieval.mode: :vector`; legacy behavior returns.

---

#### MEM-033 — Add an optional reranker behaviour

- **Priority:** P3
- **Estimate:** 2 days
- **Depends on:** MEM-032
- **Files:** `lib/recollect/reranker.ex`,
  `lib/recollect/search/fusion.ex`,
  `test/recollect/reranker_test.exs`

**Problem.** RRF is robust but not semantic. Some hosts can supply a
cross-encoder or LLM reranker.

**Implementation.**

1. Define `Recollect.Reranker` with `rerank(query, items, opts) ::
   {:ok, items} | {:error, term}`.
2. Default implementation is a no-op.
3. `retrieval.rerank: true` applies the configured reranker to the top
   `rerank_max_items` after fusion and before the budget.
4. Budget the reranker: max items, timeout, and fallback to the fused order on
   error.
5. Document that reranking is off by default and must be measured.

**Tests.**

- No-op reranker preserves order.
- A reversing reranker reverses the top N.
- A failing reranker falls back.
- The budget is applied after reranking.

**Acceptance.** Hosts can opt into reranking without changing the core.

**Rollback.** Set `retrieval.rerank: false`.

---

#### MEM-034 — Build the evaluation harness and telemetry

- **Priority:** P2
- **Estimate:** 6 days
- **Depends on:** MEM-019, MEM-032
- **Files:** `eval/` (new), `test/eval/`, `lib/recollect/telemetry.ex`,
  `docs/telemetry.md`, `README.md`

**Problem.** There is no way to prove that memory helps. Recall count rewards
retrieval, not usefulness.

**Implementation.**

1. Add an `eval/` directory with:
   - a small project Q&A set (20–50 questions with labeled relevant entries);
   - a sequential multi-session task fixture (CL-Bench-style);
   - memory-on/memory-off runner;
   - ablations: vector only, +lexical, +pages, +brief, +dreaming.
2. Metrics:
   - recall@k, precision@k;
   - answer correctness (exact match or LLM judge);
   - token efficiency (useful tokens / injected tokens);
   - time-to-context;
   - contradiction precision/recall;
   - duplicate rate, stale rate, conflict age.
3. Add telemetry events:
   - `[:recollect, :remember, :stop]` — duration, tags, level.
   - `[:recollect, :search, :stop]` — candidates, injected, tokens, truncated.
   - `[:recollect, :brief, :build]` — used tokens, items, cache hit.
   - `[:recollect, :dream, :stage]` — stage, items, duration, budget.
   - `[:recollect, :consolidation, :pass]` — pass, count, duration.
   - `[:recollect, :recall, :hit]` — anchor type, items.
4. Document how to run the harness and interpret the results.
5. Make the harness opt-in in CI (tagged `:eval`) because it may need an LLM.

**Tests.**

- The harness runs against the fixture with memory off and produces a baseline.
- Memory on produces a non-null delta.
- Metrics are emitted via telemetry.
- A deliberately bad memory set lowers the score (sanity check).

**Acceptance.** A release can state whether memory helped, with numbers.

**Rollback.** Remove the eval directory; no runtime impact.

---

## 8. Test strategy

### 8.1 Test layers

| Layer | Scope | Tooling | Runs in CI |
|---|---|---|---|
| Unit | Pure functions: `Strength`, `Budget`, `Tokenizer`, `SchemaFit` | ExUnit | Yes |
| Integration | Repo-backed modules: `Knowledge`, `Consolidation`, `Conflicts`, `Dream` | ExUnit + `Recollect.TestRepo` | Yes |
| Backend matrix | Same integration tests on Postgres and SQLite/libSQL | ExUnit + separate repos | Yes |
| Property | Invariants: no NaN, no budget overflow, idempotency | ExUnit or StreamData | Yes |
| Performance | 1k/10k entry smoke tests and p95 budgets | `@tag :perf` | Nightly / manual |
| Eval | Task success with memory on/off and ablations | `@tag :eval` + fixtures | Manual / release gate |

### 8.2 Required test files

| File | Covers |
|---|---|
| `test/recollect/consolidation_test.exs` | MEM-001, MEM-002, MEM-003 |
| `test/recollect/conflict_detection_test.exs` | MEM-004 |
| `test/recollect/tags_test.exs` | MEM-005 |
| `test/recollect/schema_fit_test.exs` | MEM-006 |
| `test/recollect/retrieval_counter_test.exs` | MEM-007 |
| `test/recollect/strength_test.exs` | MEM-001, MEM-008 |
| `test/recollect/mipmap_cost_test.exs` | MEM-009 |
| `test/recollect/context_cache_test.exs` | MEM-010 |
| `test/recollect/backend_parity_test.exs` | MEM-011 |
| `test/recollect/learning_idempotency_test.exs` | MEM-012, MEM-015 |
| `test/recollect/event_test.exs` | MEM-013 |
| `test/recollect/evidence_test.exs` | MEM-013 |
| `test/recollect/knowledge_lifecycle_test.exs` | MEM-014 |
| `test/recollect/harvest_events_test.exs` | MEM-016 |
| `test/recollect/review_test.exs` | MEM-017 |
| `test/recollect/tokenizer_test.exs` | MEM-018 |
| `test/recollect/brief_test.exs` | MEM-019 |
| `test/recollect/context_formatter_test.exs` | MEM-020 |
| `test/recollect/recall_test.exs` | MEM-021 |
| `test/recollect/sleep_atomic_test.exs` | MEM-022 |
| `test/recollect/dream_test.exs` | MEM-023 |
| `test/recollect/dream_verify_test.exs` | MEM-024 |
| `test/recollect/dream_reconcile_test.exs` | MEM-025 |
| `test/recollect/dream_promote_test.exs` | MEM-026 |
| `test/recollect/page_test.exs` | MEM-027 |
| `test/recollect/dream_synthesize_test.exs` | MEM-028 |
| `test/recollect/page_guard_test.exs` | MEM-029 |
| `test/recollect/page_search_test.exs` | MEM-030 |
| `test/recollect/lexical_search_test.exs` | MEM-031 |
| `test/recollect/fusion_test.exs` | MEM-032 |
| `test/recollect/reranker_test.exs` | MEM-033 |
| `test/recollect/guards_test.exs` | MEM-036 |
| `test/recollect/migration_status_test.exs` | MEM-037 |
| `test/recollect/search_fallback_test.exs` | MEM-038 |
| `test/recollect/project_mapping_test.exs` | MEM-039 |
| `test/recollect/staging_test.exs` | MEM-040 |
| `test/eval/*` | MEM-034 |

### 8.3 Property tests

| Invariant | Property |
|---|---|
| Strength is bounded | `0.0 <= Strength.calculate(entry) <= 1.0` for any entry, including nil fields |
| Decay never raises | Any `half_life_days` in `[-1, 0, 1, 7, 10_000]` returns a float |
| Budget never overflows | `Budget.fit/3` returns `used <= max_tokens` for any item list |
| Consolidation is idempotent | Running twice with no changes archives the same set and creates no duplicate runs |
| Dream is idempotent | Same input hash returns the same run and creates no duplicates |
| Fusion is stable | The same candidate set and config produce the same order |
| Page guard holds | Any created page satisfies `token_count <= max(200, source_tokens * ratio)` |

If `stream_data` is added, keep it a test-only dependency. Otherwise, use
deterministic generated lists and explicit edge cases.

### 8.4 Backend matrix

Add a second test repo for SQLite:

```elixir
# test/support/sqlite_repo.ex
defmodule Recollect.SQLiteTestRepo do
  use Ecto.Repo,
    otp_app: :recollect,
    adapter: Ecto.Adapters.SQLite3
end
```

CI jobs:

1. **postgres** — service container with pgvector; run `MIX_ENV=test mix check`.
2. **sqlite** — no service; run the integration suite excluding
   Postgres-only tests (`@tag :postgres_only`).
3. **perf** — nightly, Postgres, `mix test --only perf`.
4. **eval** — manual/release, `mix test --only eval`.

Tests that cannot run on SQLite must be tagged and documented, not silently
skipped.

### 8.5 Regression tests for the P0 bugs

Each P0 fix gets a test that would fail on the baseline:

| Bug | Regression test |
|---|---|
| Consolidation crash | One-entry scope runs without raising |
| Decay not persisted | Removed entries are archived in the DB |
| Union-find split | Chain graph produces one cluster |
| Conflict detection dead | Contradictory pair persists a conflict |
| Tags dropped | Tags round-trip and filter search |
| Retrieval undercount | 200 bumps → `access_count == 200` |
| Supersede `0.0` | `Strength.calculate/2` does not raise |
| Mipmap amplification | One write, one embedding with mipmaps off |
| Sleep race | Concurrent push during promote is retained |
| Learning re-import | Two runs produce one entry |

### 8.6 Definition of a good test

- It fails for the right reason on the baseline.
- It asserts behavior, not implementation details.
- It uses a fixture or a factory, not a shared mutable database.
- It cleans up ETS state (`RetrievalCounter`, `SchemaIndex`, `OutcomeTracker`)
  between tests.
- It is deterministic; no sleeps unless testing a timeout.

---

## 9. Telemetry and observability

### 9.1 Event names

| Event | Measurements | Metadata |
|---|---|---|
| `[:recollect, :remember, :stop]` | `duration_ms`, `tags_count`, `evidence_count` | `scope_id`, `memory_level`, `stability`, `dedupe` |
| `[:recollect, :search, :stop]` | `duration_ms`, `candidates`, `injected`, `tokens`, `truncated` | `scope_id`, `mode`, `tier` |
| `[:recollect, :brief, :build]` | `duration_ms`, `used_tokens`, `items`, `cache_hit` | `scope_id`, `budget` |
| `[:recollect, :recall, :hit]` | `items`, `tokens`, `duration_ms` | `anchor_type`, `scope_id` |
| `[:recollect, :consolidation, :pass]` | `count`, `duration_ms` | `pass`, `scope_id`, `dry_run` |
| `[:recollect, :dream, :stage]` | `items`, `duration_ms`, `budget_used` | `stage`, `scope_id`, `run_id` |
| `[:recollect, :dream, :stop]` | `duration_ms`, `stages`, `status` | `scope_id`, `run_id` |
| `[:recollect, :conflict, :detected]` | `score` | `scope_id`, `reason` |
| `[:recollect, :page, :created]` | `token_count`, `sources` | `scope_id`, `slug` |
| `[:recollect, :migration, :backfill]` | `rows`, `duration_ms` | `table`, `batch` |

### 9.2 Dashboards

- **Write health:** p50/p95 remember latency, embedding calls per write, tag
  count, dedupe rate.
- **Retrieval health:** p50/p95 search latency, candidates vs injected, token
  usage, truncation rate, lexical/vector/graph mix.
- **Memory health:** live entries, archived entries, stale rate, unverified
  rate, duplicate rate, conflict age.
- **Dream health:** runs per day, success/failure/aborted, stage durations,
  budget usage, pages created/rejected.
- **Cost:** embedding calls, LLM tokens, storage bytes.

### 9.3 Alerts

| Condition | Severity | Action |
|---|---|---|
| Consolidation failure rate > 0 | High | Page on-call; disable dream |
| Dream budget exceeded > 3 runs/day | Medium | Inspect scope, lower budget |
| Search p95 > 2× budget for 15 min | Medium | Check indexes/backends |
| Brief truncation > 50% of sessions | Low | Raise budget or prune |
| Conflict age > 30 days | Low | Review/reconcile |

---

## 10. Performance budgets

| Operation | Budget | Measurement |
|---|---|---|
| `Knowledge.remember/2` excluding embedding | p95 < 25 ms | 10k entries in scope, Postgres local |
| `Knowledge.remember/2` including embedding | p95 < 300 ms | Mock/local embedding provider |
| `Search.search/2` excluding embedding | p95 < 150 ms | 10k entries, hybrid mode |
| `Brief.build/2` | p95 < 50 ms | 1,500-token budget, 10k entries |
| `Recall.for_path/2` | p95 < 10 ms | 10k anchors |
| `Consolidation.run/1` | < 60 s | 10k entries, no conflicts |
| `Dream.run/2` | Within configured `max_wall_ms` | 500 items |
| Storage per claim (excluding embedding) | < 2 KB | Content + tags + evidence |
| Event retention | 30 days (default) | Configurable |

If a budget is exceeded:

1. Profile before changing semantics.
2. Check indexes first (`EXPLAIN ANALYZE`).
3. Reduce candidate multipliers or sample sizes.
4. Only then add caching or denormalization.

---

## 11. Migration, compatibility, and release plan

### 11.1 Version plan

| Version | Contents | Compatibility |
|---|---|---|
| `0.6.1` | Phase 0 bug fixes without schema (MEM-001, 002, 003, 008, 010, 035, 036) | Patch |
| `0.7.0` | Phase 0 schema (tags, source index), mipmap defaults, migration tooling (MEM-037) | Minor; additive |
| `0.8.0` | Phase 1 events, evidence, lifecycle fields, review/explain, keyword fallback, project mapping (MEM-038, 039) | Minor; additive |
| `0.9.0` | Phase 2 brief, recall, budgeted formatter, durable staging (MEM-040) | Minor; additive |
| `0.10.0` | Phase 3 dream v1 | Minor; feature-flagged |
| `0.11.0` | Phase 4 pages | Minor; feature-flagged |
| `1.0.0` | Phase 5 hybrid retrieval, eval gate; removes `WorkingMemory` and other deprecated behavior | Major |

### 11.2 Host upgrade guide

1. **Upgrade the dependency** to the target version.
2. **Generate the upgrade migration:**
   ```bash
   mix recollect.gen.upgrade --from 0.6.0 --to 0.8.0
   ```
   Review the generated file. It is additive; it does not drop columns.
3. **Run the migration** in a maintenance window or online:
   ```bash
   mix ecto.migrate
   ```
4. **Backfill tags and lifecycle defaults** in batches:
   ```bash
   mix recollect.backfill --table tags --batch-size 1000
   mix recollect.backfill --table lifecycle --batch-size 1000
   ```
5. **Verify:**
   ```elixir
   Recollect.Diagnostics.check!(repo: MyApp.Repo)
   ```
   The diagnostics check reports missing tables, indexes, duplicate
   `(source, source_id)` rows, and invalid lifecycle values.
6. **Enable features gradually:**
   ```elixir
   config :recollect,
     brief: [token_budget: 1_500],
     dream: [enabled: true],
     pages: [enabled: false],
     retrieval: [mode: :hybrid]
   ```
7. **Roll back** by disabling the feature flag first. Schema rollback is a last
   resort because it drops provenance.

### 11.3 Backfill details

| Backfill | Source | Destination | Batch | Idempotent |
|---|---|---|---|---|
| Tags | `metadata["tags"]` | `recollect_entry_tags` | 1,000 | Yes (PK) |
| Lifecycle | defaults | new columns | 1,000 | Yes |
| Source index | existing `(source, source_id)` | dedupe then index | 1,000 | Yes, but reports duplicates |
| Recall anchors | `metadata["path"/"file"]`, evidence | `recollect_recall_anchors` | 1,000 | Yes (unique lookup) |
| Pages | consolidation summaries with `derived_from` | `recollect_pages` | 100 | Yes (slug) |

The backfill must be resumable. Record progress in
`recollect_migration_state` (add it in the same migration as the first
backfill).

### 11.4 Deprecations

| Deprecated | Replacement | Warning | Removal |
|---|---|---|---|
| `:context_hints` | `:context` | `0.8.0` | `1.0.0` |
| `Mipmap.persist/1` eager behavior | `mipmaps.mode: :lazy` | `0.7.0` | `1.0.0` |
| `Knowledge.supersede/3` destructive behavior | `Knowledge.reconcile/3` | `0.8.0` | `1.0.0` |
| `ContextFormatter.format/1` | `format/2` | `0.9.0` | `1.0.0` |
| Per-category `limit` | Global `limit` + RRF | `1.0.0` | `2.0.0` |

### 11.5 Release checklist

- [ ] `MIX_ENV=test mix check` passes.
- [ ] Backend matrix passes.
- [ ] `mix hex.build` succeeds.
- [ ] Docs build (`mix docs`).
- [ ] Migration generator output compiles for both adapters.
- [ ] Upgrade migration tested against a copy of a 0.6.0 database.
- [ ] Changelog entry with migration notes.
- [ ] Version bumped in `mix.exs`; tag matches.
- [ ] Eval gate (for 1.0.0) shows no regression.

---

## 12. Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Consolidation fix exposes a performance cliff | Medium | High | Add the 1k/10k perf tests before enabling decay by default |
| Adding `NOT NULL` columns locks a large table | Medium | High | Use fast defaults on Postgres 11+; backfill separately; test on a copy |
| Tag normalization doubles write cost | Medium | Medium | Batch inserts; measure; add a denormalized cache only if needed |
| Event storage grows unbounded | High | Medium | Retention, size caps, consent, prune unreferenced events |
| Dreaming burns LLM tokens | High | High | Budget, dry run, per-scope lock, default off |
| Page synthesis bloats or hallucinates | Medium | High | Citations, compression guard, page cap, eval gate |
| Backend divergence returns | High | Medium | CI matrix, explicit `:unsupported_backend`, feature matrix docs |
| Eval set is too small or biased | High | Medium | Start small, document limits, expand with real project questions |
| Public API churn breaks hosts | Medium | High | Additive changes, deprecation cycle, upgrade guide |
| Concurrent dream runs corrupt pages | Low | High | Per-scope lock, one writer per page, idempotency |
| Users do not trust auto-memory | High | Medium | Review/explain, citations, feature flags, default conservative |
| Mipmap lazy mode has a cold-start cost | Medium | Low | Precompute for high-value entries; measure first escalation |
| SQLite cannot support a feature | Medium | Medium | Explicit error, document the matrix, do not silently degrade |
| Hosts pin divergent Recollect SHAs and skip mirrored migrations | High | High | Tag every release; `mix recollect.migration_status` (MEM-037) as a gate step; upgrade guide per version |
| Deprecated `WorkingMemory` keeps hosts on the ephemeral path | Medium | Low | Deprecation warnings, migration note, removal only at 1.0 |

---

## 13. Staffing and sequencing

### 13.1 Solo sequence

```
Weeks 1-5    Phase 0 (19 ideal days)
Weeks 6-8    Phase 1 (14 ideal days)
Weeks 9-11   Phase 2 (14 ideal days)
Weeks 12-16  Phase 3 (19 ideal days)
Weeks 17-19  Phase 4 (13 ideal days)
Weeks 20-23  Phase 5 (16 ideal days)
```

The ranges round phase boundaries to whole weeks and include roughly 20–30%
overhead over the ideal-day estimates in §0.

### 13.2 Two-engineer split

- **Engineer A (storage/maintenance):** MEM-001–008, 011, 013–016, 023–026,
  035–037, 040.
- **Engineer B (retrieval/UX):** MEM-009, 010, 012, 017–022, 027–034, 038, 039.
- **Shared review:** schema migrations, public API changes, and the eval
  harness.

Phase 0's consolidation tickets (001–003) touch the same file and should be one
review unit even if split.

### 13.3 Review checkpoints

| Checkpoint | What must be true |
|---|---|
| After Phase 0 | Consolidation, tags, conflicts, and counts verified on both backends |
| After Phase 1 | Every new claim has provenance; no duplicate harvests |
| After Phase 2 | Brief under budget with citations; recall works by path |
| After Phase 3 | Dream is idempotent, locked, budgeted, and reversible |
| After Phase 4 | Pages cite sources and pass the compression guard |
| Before 1.0 | Eval shows memory-on is not worse than memory-off |

---

## 14. Definition of done

### 14.1 Per ticket

- [ ] Code implements the described behavior.
- [ ] Tests cover the happy path and the failure path.
- [ ] Telemetry is emitted where relevant.
- [ ] Public API docs and `usage-rules` are updated.
- [ ] Backend impact is documented (Postgres, SQLite, libSQL).
- [ ] `MIX_ENV=test mix check` passes.
- [ ] No new compiler warnings; no dialyzer regressions.
- [ ] Migration is reversible or the rollback is documented.

### 14.2 Per phase

- [ ] Exit criteria in §1.3 are met.
- [ ] Migration tested on a copy of the previous release's database.
- [ ] Changelog and upgrade notes are written.
- [ ] Performance budgets are measured and recorded.
- [ ] Feature flags default to the conservative setting.

### 14.3 Before 1.0

- [ ] Hybrid retrieval beats vector-only on the eval set.
- [ ] Memory-on task success is not worse than memory-off.
- [ ] Page + search beats search-only, or pages remain off by default.
- [ ] No P0/P1 correctness bugs open.
- [ ] Docs describe the layer model, the budgets, and the backend matrix.
- [ ] A host can upgrade from 0.6.0 with one generated migration and a
      resumable backfill.

---

## 15. Execution log

Tracked here in addition to the ops_center backlog (family `ops-agent-memory`,
repo `recollect`). One row per landed ticket; the register in Appendix A carries
the live status column.

| Date | Ticket | B | Commit | Note |
|---|---|---|---|---|
| 2026-11-07 | — | B-2570…B-2609 | — | Family filed (40 tickets) from plan v2 |
| 2026-11-07 | MEM-001 | B-2570 | `2e36be6` | Consolidation loads via schema; Strength hardened; latent uuid-binding bugs fixed |
| 2026-11-07 | MEM-002 | B-2571 | `d56f519` | Decay archives inside the run transaction; dry-run honest; true counts |
| 2026-11-07 | MEM-008 | B-2577 | `228d45b` | supersede stores 0.01 half-life (configurable); no ArithmeticError |
| 2026-11-07 | MEM-003 | B-2572 | `dc3c591` | Tuple pairs; union-find grouped by root; merged counts clusters |
| 2026-11-07 | MEM-004 | B-2573 | `a4b2780` | Detection queries schema; persist reopens resolved; empty-tag + substring-polarity bugs fixed |
| 2026-11-07 | MEM-007 | B-2576 | `c79766a` | bump inserts missing keys; flush applies real counts, caps half-life, clears only on success |
| 2026-11-07 | MEM-035 | B-2605 | `f8374e7` | remember never throws :disabled; enrichment skipped with telemetry; nil-config crashes fixed |
| 2026-11-07 | MEM-036 | B-2606 | `005f2e1` | Recollect.Guards secret guard on remember; allow_secrets opt-out; telemetry on rejection |
| 2026-11-07 | MEM-005 | B-2574 | `a7bb21f` | entry_tags table + txn write + search filters + mipmap/embedder/conflict wiring + backfill task |
| 2026-11-07 | MEM-006 | B-2575 | `f50adc7` | Per-scope schema index from entry_tags; tag-fit sync, content-fit sampled async |
| 2026-11-07 | MEM-009 | B-2578 | `2ea632f` | mipmaps.mode (:lazy default); batched level embeddings; query_embedding passthrough; archived excluded |
| 2026-11-07 | MEM-010 | B-2579 | `f00a259` | detect_cached TTL cache; context_detection.mode; remember context: opt |
| 2026-11-07 | MEM-012 | B-2581 | `f2d492b` |
| 2026-11-08 | MEM-011 | B-2580 | `df74320` | Backend parity: six modules Ecto-ized (portable CASE/LOWER); Conflict/Handoff/ConsolidationRun schemas; counter SQLite per-row flush; $N ratchet test; feature matrix; minimal CI (PG only); since threaded; (source,source_id) dedupe; pipeline passes scope_id; suite fully green (272/0) |
| 2026-11-08 | MEM-013 | B-2582 | `907a06a` | Event ledger + evidence tables; record/1 SHA-256 dedupe (stable, race-rescued — Ecto can't report DO NOTHING on changeset inserts); list/2 since/until/session/type+limit/order; prune retention on occurred_at, evidence-shielded, NOT IN NULL-safe; Evidence.link/3 dedupe + typed errors; generator + facade; 290/0 |
| 2026-11-08 | MEM-014 | B-2583 | `6a45b38` | Lifecycle fields (level/stability/epistemic/window/verification/version/tombstone) + Entry.live/1 + soft forget (hard opt-out) + remember opts + dedupe :update version bump (MEM-012 deferral); vector/graph queries exclude tombstones; 3 legacy hard-delete tests updated; 301/0 (baseline worktree shows same load-linked flake — environmental) |
| 2026-11-08 | MEM-015 | B-2584 | `34165a3` | remember/2 = one Ecto.Multi (entry+tags+evidence, :evidence opt, atomic rollback on bad links); dedupe :update links evidence atomically; ingest_batch/2 with counts (skipped/failed semantics); harvest records carry stable :source_id (Mcp sink forwards to stage_memory); checkpoint no-op asserted; 311/0 |
| 2026-11-08 | MEM-016 | B-2585 | `5afdcde` | Pipeline records each extract as a ledger event and binds derived_from evidence atomically (owner_id opt, events.enabled:false -> records-only fallback); Event.record enforces max_content_bytes at write time (UTF-8-safe truncation + marker); harvest records carry :events raw material (Jsonl passthrough); consent upstream, dry-runs inert; 317/0 |
| 2026-11-08 | MEM-017 | B-2586 | `bdbff51` | Recollect.Review: candidates/2 (six reasons per plan + suggested-action precedence, most-flagged first) + explain/1 (evidence, usage, verification, supersedes directions, human :why); Knowledge.review/explain + facade delegates; telemetry spans; 328/0 |
| 2026-11-08 | — | B-2570 | `6658d50` | chore(format): pipeline_quarantine_test.exs — last pre-existing drift; format leg of mix check green repo-wide again |
| 2026-11-08 | — | v0.7.0 | `cf80a5b` | Released v0.7.0 (tag on mem-phase0; Hex publish deferred) — phase 0 + phase 1, 20/40 tickets; full mix check green (clean compile, format, 328/0). Tag hash note: 6658d50 was amended to 9d67d4c when the other five drifted files joined the format chore |
| 2026-11-08 | MEM-018 | B-2587 | `f18c8ef` | Tokenizer.estimate/1 (ceil chars/4, tokenizer_fn override) + Budget.fit/3 (priority>score>recency ranking, greedy packing past non-fitting items, whole-item drops, 10% reserve, :tokens_key opt, missing tokens raise); 340/0 |

---

## Appendix A — Canonical ticket register

| ID | Title | Phase | Est. (days) | Depends on | B-ticket | Status |
|---|---|---|---:|---|---|---|
| MEM-001 | Consolidation struct + strength hardening | 0 | 1 | — | B-2570 | implemented_local |
| MEM-002 | Persist decay removals | 0 | 1 | 001 | B-2571 | implemented_local |
| MEM-003 | Pair generation + union-find | 0 | 1.5 | 001 | B-2572 | implemented_local |
| MEM-004 | Conflict detection + persistence | 0 | 1.5 | 003, 005 | B-2573 | implemented_local |
| MEM-005 | Tags + filters | 0 | 3 | — | B-2574 | implemented_local |
| MEM-006 | SchemaIndex + SchemaFit | 0 | 2 | 005 | B-2575 | implemented_local |
| MEM-007 | RetrievalCounter counts | 0 | 1 | — | B-2576 | implemented_local |
| MEM-008 | Supersede + Strength | 0 | 1 | 001 | B-2577 | implemented_local |
| MEM-009 | Mipmap laziness + query embedding | 0 | 2 | 001, 005 | B-2578 | implemented_local |
| MEM-010 | Context detection cache | 0 | 1 | — | B-2579 | implemented_local |
| MEM-011 | Backend parity | 0 | 2.5 | 004, 007 | B-2580 | implemented_local |
| MEM-012 | Learning `since` + dedup | 0 | 1.5 | 005 | B-2581 | implemented_local |
| MEM-013 | Events + evidence tables | 1 | 4 | 005 | B-2582 | implemented_local |
| MEM-014 | Entry lifecycle fields | 1 | 2.5 | 013 | B-2583 | implemented_local |
| MEM-015 | Idempotent ingestion | 1 | 2 | 012, 014 | B-2584 | implemented_local |
| MEM-016 | Learning writes events | 1 | 3 | 013, 015 | B-2585 | implemented_local |
| MEM-017 | Review + explain | 1 | 2.5 | 013, 014 | B-2586 | implemented_local |
| MEM-018 | Tokenizer + budget | 2 | 2 | — | B-2587 | implemented_local |
| MEM-019 | Brief | 2 | 4 | 014, 018 | B-2588 | open |
| MEM-020 | ContextFormatter budget | 2 | 2 | 018, 019 | B-2589 | open |
| MEM-021 | Recall anchors | 2 | 4 | 014, 018 | B-2590 | open |
| MEM-022 | Handoff/WorkingMemory | 2 | 2 | 019 | B-2591 | open |
| MEM-023 | Dream orchestrator | 3 | 5 | 013, 014, 017 | B-2593 | open |
| MEM-024 | Dream verify | 3 | 5 | 023 | B-2594 | open |
| MEM-025 | Dream reconcile | 3 | 5 | 023, 024, 004 | B-2595 | open |
| MEM-026 | Dream promote/prune | 3 | 4 | 023, 024, 025 | B-2596 | open |
| MEM-027 | Pages schema + CRUD | 4 | 2 | 013, 014 | B-2597 | open |
| MEM-028 | Page synthesis | 4 | 5 | 027, 023 | B-2598 | open |
| MEM-029 | Citations + compression guard | 4 | 3 | 027, 028 | B-2599 | open |
| MEM-030 | Page retrieval | 4 | 3 | 029, 021 | B-2600 | open |
| MEM-031 | Lexical indexes | 5 | 4 | 014 | B-2601 | open |
| MEM-032 | RRF fusion + global budget | 5 | 4 | 031, 018, 021 | B-2602 | open |
| MEM-033 | Reranker behaviour | 5 | 2 | 032 | B-2603 | open |
| MEM-034 | Eval harness + telemetry | 5 | 6 | 019, 032 | B-2604 | open |
| MEM-035 | `remember/2` never throws on disabled enrichment | 0 | 1 | — | B-2605 | implemented_local |
| MEM-036 | Engine-level secret guard | 0 | 1 | — | B-2606 | implemented_local |
| MEM-037 | Migration status + upgrade generator | 0 | 2 | — | B-2607 | open |
| MEM-038 | Keyword fallback in search | 1 | 2 | — | B-2608 | open |
| MEM-039 | Project mapping from transcript cwd/remote | 1 | 1 | — | B-2609 | open |
| MEM-040 | Durable staging table | 2 | 3 | 014 | B-2592 | open |

**Total:** 105 ideal days.

---

## Appendix B — File-by-file change map

### New files

```
lib/recollect/schema/entry_tag.ex
lib/recollect/schema/event.ex
lib/recollect/schema/evidence.ex
lib/recollect/schema/page.ex
lib/recollect/schema/page_source.ex
lib/recollect/schema/recall_anchor.ex
lib/recollect/schema/dream_run.ex
lib/recollect/schema/reconciliation.ex
lib/recollect/schema/staging.ex
lib/recollect/event.ex
lib/recollect/evidence.ex
lib/recollect/guards.ex
lib/recollect/staging.ex
lib/recollect/tokenizer.ex
lib/recollect/budget.ex
lib/recollect/brief.ex
lib/recollect/brief/selector.ex
lib/recollect/brief/renderer.ex
lib/recollect/recall.ex
lib/recollect/dream.ex
lib/recollect/dream/run.ex
lib/recollect/dream/verify.ex
lib/recollect/dream/reconcile.ex
lib/recollect/dream/synthesize.ex
lib/recollect/dream/promote.ex
lib/recollect/dream/prune.ex
lib/recollect/dream/worker.ex
lib/recollect/page.ex
lib/recollect/review.ex
lib/recollect/reranker.ex
lib/recollect/search/lexical.ex
lib/recollect/search/fusion.ex
lib/recollect/sql.ex
lib/mix/tasks/recollect.gen.upgrade.ex
lib/mix/tasks/recollect.migration_status.ex
lib/mix/tasks/recollect.backfill.ex
priv/recollect_migrations.manifest.json
priv/repo/migrations/20261107000001_add_entry_tags.exs
priv/repo/migrations/20261107000002_add_source_unique_index.exs
priv/repo/migrations/20261107000003_add_events_and_evidence.exs
priv/repo/migrations/20261107000004_add_entry_lifecycle_fields.exs
priv/repo/migrations/20261107000005_add_recall_anchors.exs
priv/repo/migrations/20261107000006_add_dream_runs.exs
priv/repo/migrations/20261107000007_add_reconciliations.exs
priv/repo/migrations/20261107000008_add_pages.exs
priv/repo/migrations/20261107000009_add_lexical_indexes.exs
priv/repo/migrations/20261107000010_add_staging.exs
test/recollect/consolidation_test.exs
test/recollect/conflict_detection_test.exs
test/recollect/tags_test.exs
test/recollect/schema_fit_test.exs
test/recollect/retrieval_counter_test.exs
test/recollect/strength_test.exs
test/recollect/mipmap_cost_test.exs
test/recollect/context_cache_test.exs
test/recollect/backend_parity_test.exs
test/recollect/event_test.exs
test/recollect/evidence_test.exs
test/recollect/brief_test.exs
test/recollect/recall_test.exs
test/recollect/dream_test.exs
test/recollect/page_test.exs
test/recollect/fusion_test.exs
test/recollect/guards_test.exs
test/recollect/staging_test.exs
test/recollect/migration_status_test.exs
test/recollect/search_fallback_test.exs
eval/
```

### Modified files

| File | Tickets |
|---|---|
| `lib/recollect/consolidation.ex` | 001, 002, 003, 006 |
| `lib/recollect/strength.ex` | 001, 008 |
| `lib/recollect/conflict_detection.ex` | 003, 004, 011 |
| `lib/recollect/conflicts.ex` | 004, 011 |
| `lib/recollect/knowledge.ex` | 005, 008, 012, 014, 015, 017, 035, 036 |
| `lib/recollect/schema/entry.ex` | 005, 014 |
| `lib/recollect/search/vector.ex` | 005, 009, 010, 014, 030, 032, 038 |
| `lib/recollect/search.ex` | 014, 021, 030, 032, 038 |
| `lib/recollect/search/context_formatter.ex` | 020 |
| `lib/recollect/schema_index.ex` | 006, 011 |
| `lib/recollect/schema_fit.ex` | 006 |
| `lib/recollect/retrieval_counter.ex` | 007, 011 |
| `lib/recollect/mipmap/generator.ex` | 009 |
| `lib/recollect/pipeline/embedder.ex` | 009 |
| `lib/recollect/context/detector.ex` | 010 |
| `lib/recollect/handoff.ex` | 011, 022 |
| `lib/recollect/working_memory.ex` | 022, 040 |
| `lib/recollect/working_memory/server.ex` | 022 |
| `lib/recollect/sleep.ex` | 022, 040 |
| `lib/recollect/confidence.ex` | 011 |
| `lib/recollect/outcome.ex` | 011 |
| `lib/recollect/invalidation.ex` | 011 |
| `lib/recollect/learning/coding_agent.ex` | 012, 016, 039 |
| `lib/recollect/learning/pipeline.ex` | 012, 015, 016 |
| `lib/recollect/learning/harvest.ex` | 015, 016 |
| `lib/recollect/learning/project_mapping.ex` | 039 |
| `lib/recollect/migration_generator.ex` | 005, 013, 014, 027, 031, 037, 040 |
| `lib/recollect/config.ex` | 009, 010, 018, 019, 021, 023, 031, 036, 038, 040 |
| `lib/recollect/application.ex` | 010, 018, 023 |
| `mix.exs` | version bumps, optional test deps |
| `README.md`, `docs/architecture.md`, `usage-rules/*` | all phases |
| `test/test_helper.exs` | backend matrix, perf/eval tags |

---

## Appendix C — Host upgrade example

```elixir
# 1. mix.exs
{:recollect, "~> 0.8"}

# 2. Generate and inspect the upgrade migration
#    mix recollect.gen.upgrade --from 0.6.0 --to 0.8.0

# 3. config/config.exs
config :recollect,
  repo: MyApp.Repo,
  brief: [token_budget: 1_500],
  events: [enabled: true, retention_days: 30],
  mipmaps: [mode: :lazy],
  context_detection: [mode: :cached],
  retrieval: [mode: :hybrid],
  dream: [enabled: false],
  pages: [enabled: false]

# 4. Application supervision: no changes required for the library
#    (Dream is host-scheduled).

# 5. Start a session with a brief
{:ok, brief} = Recollect.Brief.build(scope_id, token_budget: 1_500)
IO.puts(brief.text)

# 6. Recall for a file
{:ok, items} = Recollect.Recall.for_path("lib/my_app/billing.ex", scope_id)

# 7. Run a dry-run dream
{:ok, plan} = Recollect.Dream.plan(scope_id)
{:ok, run} = Recollect.Dream.run(scope_id, dry_run: true)
```

---

## Appendix D — Evaluation harness specification

### D.1 Directory layout

```
eval/
  tasks/
    project_qa.jsonl          # question, expected entry ids, rubric
    sequential_sessions.jsonl # multi-session CL-Bench-style tasks
  fixtures/
    entries.jsonl
    events.jsonl
    pages.jsonl
  runner.exs
  metrics.ex
  README.md
```

### D.2 Task format

```json
{
  "id": "billing-retry-1",
  "session": 1,
  "query": "Why does the billing retry loop stop after 60 seconds?",
  "relevant_entry_ids": ["..."],
  "rubric": ["mentions exponential backoff", "mentions the 60s cap"],
  "memory": "on"
}
```

### D.3 Ablations

1. Vector only.
2. Vector + lexical.
3. Vector + lexical + graph.
4. + brief.
5. + pages.
6. + dreaming.

Run each ablation on the same task set. Report the marginal gain and the
marginal token cost.

### D.4 Metrics

| Metric | Definition |
|---|---|
| recall@k | Relevant IDs in the top k |
| precision@k | Injected items that are relevant |
| answer score | Rubric criteria met / total |
| token efficiency | Useful tokens / injected tokens |
| time-to-context | Wall time from session start to first useful item |
| contradiction precision | Correct conflicts / detected conflicts |
| contradiction recall | Detected conflicts / labeled conflicts |
| duplicate rate | Duplicate entries / new entries |
| stale rate | Stale entries / live entries |
| conflict age | Median days an open conflict stays open |

### D.5 Guardrail

If memory-on is worse than memory-off on the task set, the release is blocked
until the regression is explained. The fallback is to reduce the brief budget or
disable the new layer; injecting more memory is not an acceptable fix.

---

## Appendix E — Glossary

See the research report's Appendix D. Key terms repeated here for convenience:

- **L0 / event** — raw transcript or observation.
- **L1 / claim** — atomic, scoped, evidenced note.
- **L2 / page** — cited synthesis of claims.
- **L3 / brief** — budgeted injected context.
- **Dream** — offline consolidation pipeline.
- **Provenance** — link from a claim/page to its evidence.
- **RRF** — reciprocal rank fusion.
- **Compression guard** — rule limiting page size relative to its sources.
- **Recall anchor** — path/symbol key for just-in-time memory.
