# Agent Memory: System Blueprint

> **Part 3 of 3.** Companions:
> [`agent-memory-research.md`](agent-memory-research.md) (Recollect internals,
> article + HN research, verified audit) and
> [`agent-memory-implementation-plan.md`](agent-memory-implementation-plan.md)
> (the MEM ticket register). This document zooms out: Recollect is one component
> in a fleet-wide memory system, and several of its "missing features" are
> already implemented — redundantly — in the repos around it.
>
> **Baseline:** 2026-11-07. Recollect HEAD `948cb2a` (`v0.6.0`, untagged).
> Findings verified by reading each repo's source, configs, and rules files.

---

## 0. Executive summary

The fleet already has an agent-memory **loop** — capture, distill, store,
inject, and act — but it is assembled from parts that don't quite fit:

```
 sessions ──▶ capture ──▶ staging ──▶ distill ──▶ claims ──▶ inject ──▶ agents
 (claude,     hooks,       durable    harvest,    Tier 2      brief,     forge,
  codex,      plugins,     tables     sleep       entries     recall,    coding
  opencode)   MCP writes              (LLM)       + graph     hooks      agents
     ▲                                                                        │
     └───────────────── outcome / fitness / eval ◀────────────────────────────┘
```

Findings that change the picture:

1. **kfos_upgrader does not feed Recollect.** It owns the *conventions layer*
   (agent-workflow, quality gate, repo manifests) that shapes the sessions
   Recollect later harvests. The harvest core (B-2163) was consolidated from
   ops_center, home, and kfos_teamkit. One real bug surfaced here: worktree
   sessions are **misattributed** — kfos_upgrader work done under a
   `kfos-agent` scratchpad is harvested into the `kfos_agent` scope.
2. **There are four Recollect deployments, not one**: home (personal memory,
   Postgres in `Home.Repo`), ops_center (fleet memory, fleet Postgres),
   AgentForge/kfos_agent (agent-team memory, local `agent_forge_memory`
   Postgres), and worth (product memory, path dep). They share **no scopes, no
   owner identity, and no data**. The only bridge is behavioral (forge reports
   to the ops_center backlog; the harvest MCP sink can push staged notes to
   ops-center).
3. **Production has independently confirmed the research report's audit.**
   kfos_agent's trap log (`docs/kb/learning.md`) lists ten upstream Recollect
   bugs; ops_center ran three months missing `recollect_mipmaps`,
   `recollect_conflicts`, `recollect_consolidation_runs`, and
   `recollect_handoffs`. Both hosts reimplemented pieces Recollect should own.
4. **Three hosts wrote the same three workarounds**: a durable staging table
   (replacing `Recollect.WorkingMemory`), an ILIKE keyword fallback (recollect
   `Search` errors without embeddings), and a secret guard in front of every
   write. That is the clearest possible signal for what belongs in the engine.
5. **Version drift is real**: home and ops_center pin `715abd2`, the forge pins
   the older `721db61`, worth builds against HEAD. Nothing measures whether
   memory helps anyone.

**What to add where, in one line each:**

- **Recollect** gets the duplicated pieces (durable staging, keyword fallback,
  secret guard, remember-contract, migration-status tooling) — six new tickets,
  folded into the implementation plan as MEM-035…MEM-040.
- **home** stays the personal memory host and becomes the first `Brief`/`Dream`
  consumer; cleanup of Cognee remnants and dead code.
- **ops_center** stays the fleet brain, adopts the outcome flywheel, and
  accepts the forge's distilled lessons into `shared`/`ops` scopes.
- **AgentForge** converges on one Recollect pin, deletes its workarounds as the
  engine absorbs them, and pushes distilled lessons to the fleet brain.
- **kfos_upgrader** gains a FleetConformance step that makes migration mirroring
  mechanical, and hosts the fleet-wide **memory routing** rules (what lives in
  AGENTS.md vs repo docs vs graphify vs memory MCP vs backlog).
- **The meta layer** (rules + graphify + KBs) gets an explicit routing contract,
  consistent ingest allowlists, and a retirement path for legacy `MEMORY.md`
  files.

The compound payoff: every agent on the machine — Claude Code, Codex, OpenCode,
and the forge's Lua specialists — starts each session with a small, cited,
verified brief; every outcome strengthens or weakens the memories that produced
it; and every repo's docs and graphs stay ingestible without manual effort.

---

## 1. The system today

### 1.1 Component map

```
┌────────────────────────── meta layer (conventions) ──────────────────────────┐
│ kfos_upgrader: docs/agent-workflow.md · quality-gate.md · repo-manifest.json │
│ per-repo AGENTS.md (canonical) + CLAUDE.md (pointer) + .kfos/repo.json       │
│ graphify skill + graphify-out/ (local_foundation only) · B-NNN backlog (MCP) │
└───────────────┬──────────────────────────────────────────────┬───────────────┘
                │ shapes how agents work                        │ tickets, findings
                ▼                                               ▼
┌────────────────────────── agent sessions ────────────────────────────────────┐
│ Claude Code (~/.claude/projects/*.jsonl)   Codex (~/.codex)                  │
│ OpenCode (~/.local/share/opencode)         AgentForge runs (session_events)  │
└───────┬──────────────────┬─────────────────────┬─────────────────┬──────────┘
        │ curated files    │ transcripts         │ transcripts     │ runs
        ▼                  ▼                     ▼                 ▼
┌───────────────────┐  ┌────────────────┐  ┌────────────────┐  ┌──────────────┐
│ HOME (personal)   │  │ OPS_CENTER     │  │ AGENTFORGE     │  │ WORTH        │
│ Recollect in      │  │ Recollect in   │  │ Recollect in   │  │ Recollect as │
│ Home.Repo         │  │ OpsCenter.Repo │  │ AgentForge.Repo│  │ path dep     │
│ REST · MCP · hook │  │ MCP · workers  │  │ forge.* to Lua │  │ MCP+skills   │
│ daily import      │  │ hourly sleep   │  │ per-run memory │  │ global scope │
└───────────────────┘  └────────────────┘  └────────────────┘  └──────────────┘
        ▲                      ▲                  ▲
        └──────── overlaps: forge context compiler pulls fleet brain from
                  ops_center MCP; harvest MCP sink can push staged notes back.
```

### 1.2 The four deployments

| | home | ops_center | AgentForge (kfos_agent) | worth |
|---|---|---|---|---|
| **Role** | Personal ops hub; memory for local coding agents | Fleet control plane; project/ops/shared memory | Agent team runtime (Lua specialists) | Product app |
| **Storage** | `Home.Repo` + pgvector | `OpsCenter.Repo` (fleet Postgres) | `AgentForge.Repo` (`agent_forge_memory`) | host repo |
| **Pin** | `715abd2` | `715abd2` | `721db61` (older!) | `../recollect` path dep |
| **Embeddings** | OpenRouter via Cloak; 1536 dims; ILIKE fallback | OpenRouter via encrypted Secret; 1536 dims | OpenRouter via vault + **query-embedding cache** (B-033) | Local MiniLM or OpenRouter |
| **Extraction LLM** | own proxy `memory` model (`LlmJson.llm_fn`) | `LlmService.chat/2` | `LLM.chat(tier: :quality)` | per config |
| **Writes** | REST/MCP `memory_remember`, brief write-through, daily import | MCP `remember_memory`/`stage_memory`, backlog worker, learning loop, doc sync | `forge.memory.remember`, outcome lessons, handoffs, doc sync | `Worth.Memory.Manager` |
| **Reads** | REST/MCP search, SessionStart hook (limit 8), opencode plugin, insights UI | MCP `search_memory`, retriever in chat/log/alert prompts | `forge.memory.context`, context compiler block (4,096 tok cap) | `worth_memory_query` |
| **Uses** | Knowledge, Search, ContextFormatter, Harvest, Sleep.distill, Pipeline.health | Knowledge, Search, Ingester, Sleep, Harvest core + Checkpoint + Sink | Knowledge, Search, OutcomeTracker, Outcome, Sleep, Handoff, Invalidation, Decay, Consolidation, Ingester, CodingAgent | Knowledge/Search via Manager |
| **Replaced / rejected** | WorkingMemory (unused), Handoff (table mirrored, never called), Consolidation, Mipmap | **WorkingMemory → `agent_memory_staging` table**, Handoff (dead code), Outcome, Consolidation, Decay, Invalidation | **WorkingMemory → `forge_memory_staging` table** (modeled on ops_center's), Learning.Pipeline (own fitness loop) | — |
| **Scopes** | string names → md5 UUID (`shared` default) | project / `group:<slug>` / `ops` / `shared` (UUIDv5) | project + specialty (read fan-out) | global `worth` + workspace overlays |
| **Memory UX** | LiveView console + tactical overview | MCP tools + prompt wrapping ("historical operational memory") | system-prompt handoff + lessons | product feature |

### 1.3 How memory gets in (feed paths)

| Feed | Who | Mechanism |
|---|---|---|
| Explicit agent writes | Codex (global rule), Claude Code + OpenCode (home MCP/plugin) | `memory_remember` at session start/read pattern; "never store secrets" |
| Curated files | home importer, forge `ClaudeMemoryWorker` | `~/.claude/projects/*/memory/*.md`, `CLAUDE.md`, `AGENTS.md` — "the curated files ARE the distillation" |
| Transcript harvest | home (daily scheduler), ops_center (`mix ops_center.memory.harvest` + harvest sink, hourly sleep) | `Recollect.Learner.Harvest` over Claude/Codex/OpenCode JSONL, consent-enforced, checkpointed |
| Repo docs | forge DocumentSync (per run), ops_center DocumentSync + `DocAllowlist` | allow-listed markdown → Tier 1 ingest; backlog items via `BacklogMemoryWorker` |
| Incidents/findings | ops_center LearningLoop (3:25 nightly) | parses "What we learned / What changed" headings → pinned entries |
| Outcome feedback | forge only | `OutcomeTracker` + `Outcome.good/bad` strengthen/weaken on run success |

### 1.4 How memory gets out (injection paths)

| Surface | Who | Shape |
|---|---|---|
| Session-start hook | home → Claude Code | top-8 search results as markdown header |
| Context compiler | forge (B-1113) | budgeted ordered blocks: persona → ticket → repo AGENTS.md → **memory (4,096 tok)** → backlog → docs; 64 KB total |
| MCP tool call | Codex/OpenCode agents | `memory_search` on demand |
| Prompt wrapper | ops_center retriever | "historical operational memory… not current state" |
| Dashboard | home insights, forge handoffs | human-facing |

Note the asymmetry: the forge's prompt memory actually comes from **ops_center's
MCP** (`search_memory`) via the context compiler, while its local Recollect
serves `forge.memory.context` — two brains, by design, unbridged.

### 1.5 The meta layer

- **Rules**: per-repo `AGENTS.md` is canonical (~300-line cap), `CLAUDE.md` is a
  pointer, `.kfos/repo.json` is machine-readable; `FleetConformance` gate step
  enforces both. No repo's rules currently say **when to use memory vs graphify
  vs KB files** — each agent guesses.
- **Knowledge bases**: forge `docs/kb/*.md` (25 dated files; "append what you
  learn — that is how this repo pays its knowledge forward"), ops_center
  `docs/playbook` + `docs/operational-knowledge` + `docs/incidents` (blameless
  archive, parsed headings feed LearningLoop), legacy hand-maintained
  `.claude/MEMORY.md` files still maintained in mark_mesh and
  strategic_change_engine.
- **Graphify**: skill + CLI, AST-based (no API key), `graphify-out/` exists only
  in local_foundation; its gate has `graph_health` (warns when the graph is
  older than the code); `GRAPH_REPORT.md` is a 243 KB markdown audit that is in
  **no** memory ingest allowlist.
- **Backlog**: B-NNN in ops_center DB over MCP; ship narratives are "the
  institutional memory"; agent findings filed via `file_agent_finding`.

---

## 2. Production has already validated the audit

The research report's §6 audit was done statically on Recollect HEAD. The hosts'
trap logs independently hit the same bugs in production — strong evidence the
audit is correct and that Phase 0 is the fleet-wide unblock:

| Audit finding | Production evidence |
|---|---|
| Mipmaps broken (`tags_json`, bytea/pgvector) | "Mipmaps had never worked in any host" — fixed upstream only at `721db61`; ops_center prod ran **3 months** without the tables at all |
| `Outcome.do_update` silently no-ops | kfos_agent learned this the hard way (UUID strings into `= ANY`) and pins `721db61` for it — the forge's whole flywheel depends on this fix |
| `Handoff` dead code | the generator never created `recollect_handoffs`; ops_center mirrored the table but still never calls the module |
| `remember/2` throws `:disabled` after insert | forge must `catch :disabled` around every write (`memory/recollect.ex:75-81`) |
| `Search` has no keyword fallback | home built an ILIKE fallback, the forge built its own ILIKE search + chunk search, ops_center documents degraded mode — **three implementations** |
| `WorkingMemory` is ephemeral | **rejected and reimplemented twice** (`agent_memory_staging`, `forge_memory_staging`), with nearly identical moduledocs citing the same reason |
| Consolidation crashes / decay not persisted | forge runs `Consolidation.run` + `Decay.run` in `mix forge.memory.maintain` — on the pre-fix code, meaning maintenance there has never actually done what it claims |
| Secrets must never enter memory | home and ops_center each carry a private `possible_secret?/1` regex guard; forge mentions a "secret guard" in its facade — **three copies** |

Version drift compounds it: `721db61` (forge) < `715abd2` (home, ops_center) <
`948cb2a` (HEAD). worth builds against HEAD and embeds generated usage-rules
that can drift from any pinned host. There is no released tag hosts can
converge on.

---

## 3. Where the loop breaks

| # | Gap | Evidence | Consequence |
|---|---|---|---|
| G1 | **Engine correctness** (Phase 0) | pin drift; trap logs | every host carries workaround code and stale pins |
| G2 | **Migration mirroring treadmill** | hosts must hand-copy recollect migrations; 3-month prod drift; "when a recollect feature has no DB-backed test, assume it has not run" | silent feature absence; destructive recovery (drop both DBs) |
| G3 | **No keyword fallback in the engine** | 3 host reimplementations | every deployment reinvents degraded search |
| G4 | **WorkingMemory unfit; staging duplicated** | 2 reimplementation moduledocs | drift between hosts; recollect ships a module nobody can use |
| G5 | **Secret guard triplicated** | 3 private regexes | inconsistent protection; a miss in any host leaks secrets into memory |
| G6 | **`remember` contract violates "never raise"** | forge catch-around-call | documented convention broken at the API boundary |
| G7 | **Fleet-brain split** | forge lessons/handoffs/outcomes never leave `agent_forge_memory`; ops_center `shared`/`ops` never receive them | agent team relearns what the fleet already knows |
| G8 | **Session misattribution** | kfos_upgrader worktrees under `kfos-agent` slug; word-matching in `ProjectMapping` | lessons land in the wrong scope; wrong-scope briefs |
| G9 | **Transcripts discarded after distillation** | home imports curated files only for Claude; forge skips transcripts | dreaming cannot verify claims against ground truth (the article's core mechanism) |
| G10 | **Injection layer fragmented** | hook (limit 8) vs compiler (4,096 tok) vs retriever wrapper | no token budget discipline, no citations, no dedupe — exactly what the research says matters most |
| G11 | **Outcome/eval loop half-adopted** | forge only; ops_center and home never close the loop; no eval harness anywhere | nobody can say whether memory helps (the one metric that matters) |
| G12 | **Knowledge routing unspecified** | 4 knowledge sources, 0 routing rules; `GRAPH_REPORT.md` unallowlisted; legacy `MEMORY.md` files still maintained | knowledge lands in the wrong layer or nowhere; agents grep when the graph has the answer |

---

## 4. What to add where

### 4.1 In Recollect (the engine)

Most additions belong here because hosts keep proving the demand. Six new
tickets (MEM-035…MEM-040) have been folded into
[`agent-memory-implementation-plan.md`](agent-memory-implementation-plan.md#appendix-a--canonical-ticket-register):

| New | What | Kills |
|---|---|---|
| **MEM-035** | `remember/2` contract: embedding-disabled is data (`{:ok, entry, warnings}`), never a `throw :disabled` after insert | G6; deletes forge's catch-workaround |
| **MEM-036** | `Recollect.Guards.possible_secret?/1` in the engine, applied in `Knowledge.remember` (opt-out flag) | G5; one guard, three hosts delete theirs |
| **MEM-037** | `mix recollect.migration_status` (compares host-applied vs dep migrations) + `mix recollect.gen.upgrade` | G2; makes drift visible in one command, gate-checkable |
| **MEM-038** | Keyword fallback in `Search.search` (scoped ILIKE/FTS-lite, embedding-optional) | G3; three reimplementations collapse into one; full FTS stays MEM-031/Phase 5 |
| **MEM-039** | Project mapping from session `cwd`/git remote in the transcript, not the directory slug | G8; fixes misattribution at the source |
| **MEM-040** | Durable staging table `recollect_staging` + `Recollect.Staging.stage/drain`; `Sleep.distill` consumes it; deprecate the `WorkingMemory` GenServer (removal 1.0) | G4; two host tables migrate onto it |

Existing tickets that land on system gaps: MEM-001…012 (G1), MEM-013/016 event
ledger (G9), MEM-019/020/021 Brief + budgeted formatter + recall anchors (G10),
MEM-034 eval (G11), ADR-009 `memory_level` — which notably matches what
ops_center (project/group/ops/shared) and the forge (project/specialty) already
invented independently, strong validation for the model.

Also in Recollect, no ticket needed: keep `owner_id`/`scope_id` semantics as the
only cross-deployment contract, and document a single-user-fleet owner
convention so memories stay portable if deployments ever merge.

### 4.2 In home (personal memory host)

1. **Adopt Brief + Dream when they land.** home is the natural host for the
   personal layer: it already has the scheduler, the UI, and the "retrieval
   only, no auto-capture" discipline. `Brief.build/2` replaces the
   SessionStart hook's raw top-8 dump with a budgeted, cited brief;
   `Dream.run/2` gives scheduled capture a safe home (nightly, budgeted,
   dry-run-able) without violating the no-auto-capture rule — distillation
   stays offline.
2. **Switch the importer to harvest-with-events** once MEM-013/016 ship, so
   Claude/Codex/OpenCode claims become verifiable against transcripts instead
   of resting on curated files alone (consent-gated, retention-capped).
3. **Configurable extraction endpoint** — `http://127.0.0.1:4070` is
   hard-coded in `memory.ex:178`; move to config.
4. **Delete the dead ILIKE-tuple branch** in `memory_server.ex:84-94`, validate
   `tier`/`limit` params (an atom expected, JSON strings arrive), and **add an
   Importer test** — it is the only untested core module in the memory path.
5. **Retire Cognee remnants**: `cognee_dataset_snapshots` table, `"cognee"`
   model aliases, usage-tracker shims. The Insights module can keep its shape
   but should stop impersonating a retired system.
6. When MEM-038/031 land, **delete the ILIKE fallback** in `memory.ex:75-86`
   and let the engine degrade.

### 4.3 In ops_center (fleet brain)

1. **Adopt the outcome flywheel.** ops_center has approvals, runs, and
   incidents; `Recollect.OutcomeTracker`/`Outcome` are unused. Correlating
   "was this recalled memory present when the run succeeded/failed" is the
   cheapest possible eval signal and pre-figures MEM-034.
2. **Accept forge lessons into `shared`/`ops`.** The harvest MCP sink already
   speaks `stage_memory` to ops-center; extend it (or use `remember_memory`
   with an agent identity) so forge-distilled lessons reach the fleet brain
   with provenance. Keep raw trajectories local to the forge.
3. **Migrate `agent_memory_staging` onto `recollect_staging`** (MEM-040) and
   delete the duplicate table once the engine owns it.
4. **Keep the deterministic LearningLoop, add verification.** Heading-parsing
   incident import is good capture; when Dream exists, its verify stage should
   check those pinned entries against the incident docs they came from
   (evidence links, not hope).
5. **Allowlist graphify output** where it exists: add `graphify-out/GRAPH_REPORT.md`
   (and curated community labels) to `DocAllowlist` so repo-structure knowledge
   becomes searchable memory instead of a 35 MB JSON nobody reads.

### 4.4 In AgentForge / kfos_agent (agent team)

1. **Converge the pin.** Move to the next released recollect (post-Phase 0) and
   record the bump in `docs/kb/learning.md` per the established procedure.
2. **Delete workarounds as the engine absorbs them**: `catch :disabled`
   (MEM-035), the private ILIKE search (MEM-038), `forge_memory_staging`
   (MEM-040), the local secret guard (MEM-036). That is roughly 200+ lines of
   host code that exists only because the engine lagged.
3. **Push distilled lessons to the fleet brain** (see 4.3.2) and keep
   handoffs/outcomes local. The forge should stop being an island; the
   `/team` dashboard's cross-run learning is currently invisible to ops.
4. **Use `Recall.for_path/for_symbol`** (MEM-021) as a candidate source for the
   context compiler's memory block — path/symbol-keyed injection beats scope-wide
   search for a coding agent.
5. **Feed the eval harness** (MEM-034) with `evaluation_reports` and fitness
   data — the forge already measures agent quality; it is the only place with
   labeled outcome data for memory ablations.
6. Enable **DocumentSync in prod** once mipmap/doc-sync costs are fixed
   (MEM-009), instead of the current dev/test-only gate.

### 4.5 In kfos_upgrader (conventions + gate)

1. **Add a FleetConformance check: recollect migration parity.** For any repo
   whose deps include recollect, compare the dep's `priv/repo/migrations` with
   the host's mirrored copies (MEM-037 makes this one `mix` call). This turns
   the "3 months missing tables" incident class into a red gate instead of
   patroni log noise.
2. **Author the memory routing table** in `docs/agent-workflow.md` (canonical,
   referenced by every AGENTS.md):

   | Knowledge | Lives in | Read via | Written via |
   |---|---|---|---|
   | Repo contracts, fences | `AGENTS.md` | auto-loaded | by humans/agents with a ticket |
   | Subsystem gotchas, ADRs | `docs/kb/`, `docs/playbook`, `docs/operational-knowledge` | read-before-work rule; auto-ingested to memory | dated append on discovery |
   | Code structure/architecture | `graphify-out/` | `graphify query/explain/path` | `scripts/graphify-refresh` (gate checks freshness) |
   | Cross-session operational memory | Recollect (home/ops MCP) | `memory_search`, hooks, briefs | `memory_remember`, harvest, sleep |
   | Planned work, decisions in flight | ops_center B-NNN | MCP backlog tools | `file_backlog_item` + narrative on ship |

   Today no file says this; agents guess, and the research shows guessing is
   where salience failures come from.
3. **Make graphify a fleet convention, not a local_foundation quirk**: document
   `graphify-out/` + `graph_health` as recommended gate steps for repos above a
   size threshold (local_foundation's corpus check: 989 files ≈ 800k words →
   "graph structure adds value").
4. **Nudge retirement of legacy `.claude/MEMORY.md`** files (mark_mesh,
   strategic_change_engine): a FleetConformance warning pointing at the routing
   table, not a hard fail — the content should migrate into memory/KB first.

### 4.6 In the meta layer (rules, graphify, KBs)

1. **One routing contract** (4.5.2), referenced everywhere, so "what lives
   where" stops being tribal knowledge. This is the highest-leverage
   documentation change in the fleet: it costs nothing and fixes salience at
   the source.
2. **Consistent ingest allowlists**: forge already ingests `docs/**/*.md`
   (including `docs/kb/`); ops_center allowlists playbook/operational-knowledge/
   incidents/runbooks; home ingests curated Claude files. Add `GRAPH_REPORT.md`
   (ops_center side) and keep secrets-redaction ahead of ingestion everywhere.
3. **Graphify and Recollect are complementary, not competitors**: graphify is
   the deterministic structure of a codebase (AST, no API key, per-repo);
   Recollect is cross-session operational memory. When Recollect pages arrive
   (Phase 4), a page should be able to cite a graphify community or god-node as
   a `source_type: "graphify"` source — synthesis grounded in structure.
4. **The eval loop closes across repos**: forge fitness + ops_center outcomes +
   home usage logs (`llm_usage_logs` already attributes the `memory` tool) feed
   MEM-034's harness. The fleet finally gets an answer to "is memory helping?"
   per scope, per surface.

---

## 5. Sequencing (system-level)

The MEM plan's phase order is unchanged; this adds host-side actions that ride
on it:

| When | Engine (MEM) | Hosts |
|---|---|---|
| **Now** | Phase 0 + MEM-035/036/037 | kfos_upgrader routing table + gate check; ops_center starts logging outcome signals |
| **0.7/0.8** | Phase 1 + MEM-038/039 | all hosts converge on one pin; forge deletes workarounds; home cleans Cognee remnants |
| **0.9** | Phase 2 + MEM-040 | home adopts Brief for the hook; forge adopts Recall in the compiler; both staging tables migrate |
| **0.10** | Phase 3 (Dream) | home schedules personal dreams; ops_center verify-on-incident-lessons; forge pushes distilled lessons to `shared` |
| **0.11** | Phase 4 (Pages) | graphify-cited pages; ops_center allowlists GRAPH_REPORT |
| **1.0** | Phase 5 + eval | fleet-wide memory-on vs memory-off gate; outcome correlation per deployment |

---

## 6. What "all agents more effective" concretely means

Each closed gap buys a specific, observable behavior:

1. **Every session starts warm** — brief under budget, cited, scoped
   (MEM-019/021 + home hook + forge compiler), instead of a stale top-8 dump.
2. **No agent relearns a paid-for lesson** — harvest + staging + distill run on
   a schedule that actually works (Phase 0 fixes + MEM-040), and the forge's
   lessons reach the fleet brain (4.3.2).
3. **Wrong memories die** — outcome feedback everywhere (forge today,
   ops_center next), dream verification against transcripts (MEM-016/024), so
   the "users delete 95% of auto-memory" failure mode never appears here.
4. **Knowledge lands in the right layer the first time** — the routing table
   (4.5.2) plus consistent allowlists; graphify answers structure questions,
   memory answers operational questions, AGENTS.md fences behavior.
5. **The system can prove its own value** — outcome correlation + MEM-034
   harness per deployment; the release gate is memory-on ≥ memory-off, not
   vibes.
6. **Maintenance stops being silent** — migration parity in the gate
   (4.5.1), `migration_status` in CI, DB-backed tests as the definition of
   "feature exists" (already the forge's rule; make it recollect's).

The deepest leverage is unchanged from the research report: fix the loops
before adding layers — but "the system" turns out to be bigger than Recollect,
and half of the fixing is *deleting* the copies hosts built while Recollect
lagged.

---

## Appendix A — Evidence index

| Claim | Source |
|---|---|
| home pins `715abd2`; forge pins `721db61`; ops_center pins `715abd2` | `mix.exs` in each repo; forge `mix.lock:55` |
| WorkingMemory rejected twice | `ops_center/lib/ops_center/agent/memory_staging.ex` moduledoc; `kfos_agent/lib/agent_forge/memory/staging.ex` moduledoc |
| Codex global memory rule | `~/.codex/AGENTS.md` ("`memory_search` at the start of a task… Never store secrets") |
| Harvest lineage (not kfos_upgrader) | `recollect/lib/recollect/learning/harvest.ex:6-8` (B-2163: ops_center, home, kfos_teamkit) |
| Misattribution risk | `recollect/lib/recollect/learning/project_mapping.ex:70-95` (word matching); kfos_upgrader worktree at `/tmp/claude-1000/-home-lenz-code-kfos-agent/…` |
| Three ILIKE reimplementations | `home/lib/home/memory.ex:75-86`; `kfos_agent/lib/agent_forge/memory/recollect.ex:237-265`; ops_center degraded-mode docs |
| Ten upstream bugs fixed by hosts | `kfos_agent/docs/kb/learning.md:398-437` |
| Migration drift incident | ops_center `priv/repo/migrations/20261007150000_add_missing_recollect_schema.exs` header; `kfos_agent/docs/kb/learning.md:439-459` |
| Forge context compiler budgets | `kfos_agent/lib/agent_forge/context.ex` (B-1113; memory block 4,096 tokens) |
| Graphify conventions | `~/.claude/skills/graphify/SKILL.md`; `local_foundation/AGENTS.md` §Knowledge graph; `kfos_upgrader/docs/quality-gate.md:68-70` |
| Legacy MEMORY.md files | `mark_mesh/.claude/MEMORY.md`; `strategic_change_engine/.claude/memory.md` |
| Ship narrative convention | ops_center `docs/backlog/README.md` §Shipped log; backlog skill |
