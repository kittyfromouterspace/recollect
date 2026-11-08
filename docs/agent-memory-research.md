# Agent Memory: Research Report

> **Part 1 of 2.** The companion document is
> [`agent-memory-implementation-plan.md`](agent-memory-implementation-plan.md).
>
> **Baseline:** Recollect `v0.6.0`, commit `948cb2a`, 2026-11-07.
>
> **Status:** research complete; no implementation started. Every code claim in
> this report was verified by reading the source at the baseline commit. No
> benchmark or test suite was run as part of this research; that limitation is
> stated again in §1.4.

---

## 0. Executive summary

Anthropic's [The components of agent memory](https://www.anthropic.com/research/components-of-agent-memory)
(Nov 6, 2026) is not primarily a description of a storage schema. It is an
argument that agent memory is a **lifecycle of distillation**:

```
transcripts → memory notes → representations (wiki/pages) → injected context
                    ↑                    ↑                      ↑
                    └──────────── dreaming ────────────────────┘
```

Raw experience is cheap and large. Notes are curated and small. Representations
are synthesized and expensive. Injected context is tiny and loaded into every
session. **Dreaming** is the offline compute that moves information up this
hierarchy, corrects it against the transcript, fills gaps across sessions, and
keeps the top layer small.

The article's evidence is unusually concrete, and it points in one direction:
**selection and compression beat accumulation.** In the Pokémon experiment, a
model that wrote 413 memory files across 225 folders earned one badge; a model
that wrote 9 files in 2 folders plus a single `global.md` earned four. In the
CL-Bench database task, memory improved Opus 5.5 from 0.655 to 0.838, but the
naive rule "record only failures" *reduced* the memory gain by 0.234 for Opus 5.
In the wiki experiment, a 420M-token corpus produced the most value when the
wiki was paired with search: 61% versus 53% for search alone, while saving about
20,000 tokens per question. And in one legal task the wiki grew to 1.77× the size
of the corpus it was supposed to compress, which is a failure, not a success.

The Hacker News discussion supplies the objections the article underweights:
markdown notes are not weight learning; models are poor at judging what to
remember; users delete most auto-captured memory; provenance is usually lost;
and the word "dreaming" anthropomorphizes a maintenance job. The strongest
practical suggestions in the thread are **provenance**, **scope**, **review and
pruning**, and **pointers tied to code paths** rather than prose dumps.

Recollect already contains most of the article's nouns — working memory, notes,
summaries, graph edges, decay, consolidation, handoff — but it collapses the
layers into one table and its maintenance loops are either broken or do work
that never reaches the database. The audit in §6 found 20 issues, including:

- `Consolidation.run/1` raises on any non-empty scope.
- Decay classification is never persisted; nothing is archived or deleted.
- Merge summaries are inserted as orphan `note` entries with no provenance.
- Conflict detection never executes (nonexistent column, wrong UUID binding).
- Tags are accepted by `Knowledge.remember/2` and then silently dropped.
- `SchemaIndex` and `SchemaFit` are effectively disabled.
- Retrieval counts are undercounted by the flush path.
- `supersede/3` stores `half_life_days: 0.0`, which can raise in `Strength`.
- One memory write can cost 5 embedding calls and 8 mipmap statements.
- `Sleep.promote/1` can lose concurrent or failed items.
- Search applies `limit` per category and has no token budget anywhere.

The conclusion is blunt: **Recollect is a good memory store, but it is not yet a
memory system.** The highest-value work is not a new memory layer. It is:

1. **Make the existing maintenance loops correct and persistent.**
2. **Add provenance before synthesis**, so a summary can be traced and corrected.
3. **Separate the layers** so raw events, claims, pages, and the injected brief
   have different lifecycles and budgets.
4. **Budget the injected layer** with a hard token cap and citations.
5. **Treat dreaming as a measured, idempotent, budgeted job**, not an unbounded
   background LLM loop.
6. **Evaluate memory by task success**, not by recall count or store size.

---

## 1. Research questions and method

### 1.1 Questions

| ID | Question |
|---|---|
| RQ1 | What does the article actually claim, and what evidence supports each claim? |
| RQ2 | What does the HN discussion add, contest, or get wrong? |
| RQ3 | How does Recollect's current model compare, layer by layer? |
| RQ4 | Which gaps are correctness bugs versus missing capabilities? |
| RQ5 | What should Recollect build, in what order, and how will we know it worked? |

### 1.2 Method

1. Read the full article, including its figures and reported numbers.
2. Read the HN thread (101 points, 58 comments at the time of reading) and
   followed the substantive linked sources.
3. Read the linked primary sources: Google's Sleep framework, Particulars,
   myFleet, Innerloop Breadcrumb, CL-Bench 1.0, and Letta's sleep-time compute.
4. Performed a static audit of Recollect at `v0.6.0` / `948cb2a`: schemas,
   migrations, write paths, retrieval paths, maintenance jobs, tests, and docs.
5. Verified every cited bug by tracing the exact code path and, where relevant,
   the schema/migration that should have supported it.
6. Mapped findings to design implications and a phased implementation plan.

### 1.3 Evidence grading

| Grade | Meaning |
|---|---|
| **A** | Claim is stated in a primary source and independently verified in code or DDL. |
| **B** | Claim is stated in a primary source but could not be reproduced in this environment. |
| **C** | Inference from code or from combining sources; plausible but not directly proven. |

Most Recollect findings in §6 are grade **A** (code-verified). Most article
numbers are grade **B** (reported by Anthropic, not independently reproduced).
Design recommendations are grade **C** unless they follow directly from a
verified bug.

### 1.4 Limitations

- **No runtime experiments.** The audit is static. The P0 consolidation crash
  was verified by code inspection (`struct/2` with string keys, then
  `DateTime.diff/3` with `nil`), not by running a scope end to end.
- **No access to Anthropic's internal harness.** The article's numbers are taken
  at face value. They are repeated here as evidence, not as independently
  validated results.
- **The HN thread is anecdotal.** It is useful for failure modes and user
  experience, not for effect sizes.
- **The linked sources are heterogeneous.** Google Sleep, Particulars, myFleet,
  Breadcrumb, CL-Bench, and Letta address different problems; they are used as
  design inputs, not as a controlled literature review.
- **No user interviews.** The "users delete most auto-memory" claim comes from
  HN comments, not from Recollect's own users.

---

## 2. What the article argues

### 2.1 Definition: what counts as memory

The article deliberately excludes three other ways a model can change its
behavior:

- **Weight updates** — the model's parameters are fixed at training time.
- **In-context learning** — knowledge gained within a single conversation.
- **Compaction** — summaries that replace older turns so the model can continue
  in a new context window.

"Agent memory" is narrower: knowledge gained from experience, retained between
sessions, and saved as context the model can read later. This definition matters
for Recollect because it rules out the claim that a markdown file is "learning."
Recollect should describe its value as **external, inspectable adaptation**, not
as continual learning. The HN thread makes the same point repeatedly.

### 2.2 The four functional layers

The article's Figure 1 defines a hierarchy. The names are not a formal
ontology, but the functions are distinct:

| Layer | Contents | Cost profile | Failure mode |
|---|---|---|---|
| **Transcripts** | Raw sessions, tool calls, observations, file changes | Cheap to append, expensive to read at inference | Too large to search; evidence gets lost if discarded |
| **Memory notes** | Atomic facts, decisions, rules, traps, preferences | Medium write cost, high signal | Wrong from the start; drifts as the world changes |
| **Representations** | Wikis, topic pages, indexes, summaries | Expensive to produce, cheap to retrieve | Bloats past the corpus; cites nothing; drifts |
| **Injected context** | The small slice loaded into every session | Must be tiny; consumes tokens on every turn | Stale or wrong notes poison every session; long files reduce adherence |

The layers are not just storage tiers. They have **different update cadences and
different correctness requirements**:

- A transcript should be append-only and never "corrected."
- A note can be revised, but its history matters.
- A page is a synthesis and must be regenerated when its sources change.
- The injected layer must be aggressively pruned and must cite its sources.

Collapsing all four into one table forces one lifecycle on four different kinds
of object. That is Recollect's central architectural mismatch.

### 2.3 Dreaming is offline compute, not a feature

The article calls the offline process "dreaming." It is a bundle of operations:

- **Correct** notes against the transcript (the Mt. Moon example).
- **Synthesize** notes into representations such as wiki pages.
- **Promote** durable, high-value items into the injected layer.
- **Prune** duplicates, stale items, and contradicted claims.
- **Fill gaps** that a single session could not see (broken links, missing pages).
- **Focus** memory on a goal (e.g., a person, a deal, a codebase).

Two properties are easy to miss:

1. **Dreaming is an investment.** It spends compute now to make future inference
   cheaper or better. It is not free, and it is not obviously worth it for every
   memory.
2. **Dreaming needs ground truth.** The Mt. Moon correction worked because the
   transcript contained evidence the note was wrong. A dreaming pass without
   sources can hallucinate just as easily as a note.

The article is explicit that "directing Claude to continuously check *all* its
memories might not be practical." It suggests focusing on information likely to
change or tuning the cadence based on access frequency.

### 2.4 Evidence: CL-Bench and the learning loop

The CL-Bench 1.0 database task gives Claude a series of questions, tells it the
correct answer after each attempt, and lets it write memory between sessions.
The reported mean rewards (stateless → with memory) were:

| Model | Stateless | With memory | Delta |
|---|---:|---:|---:|
| Opus 5.5 | 0.655 | 0.838 | +0.183 |
| Sonnet 5.5 | 0.644 | 0.833 | +0.189 |
| Opus 5 | 0.564 | 0.828 | +0.264 |
| Opus 4.7 | 0.383 | 0.700 | +0.317 |
| Sonnet 5 | 0.306 | 0.610 | +0.304 |
| Sonnet 4.6 | 0.330 | 0.364 | +0.034 |

The interesting part is not the average gain. It is the qualitative difference
in what the models wrote:

- **Sonnet 4.6** wrote scattered files with untested guesses. It rarely read
  them before answering and rarely tested its theories. Prompting it to read
  memory and test theories raised its score from 0.364 to 0.641.
- **Opus 4.7** consolidated notes into a single reference document and marked
  which facts were checked versus unconfirmed.
- **Opus 5** closed the loop: entries included a rule, how it knew the rule was
  true, answers to earlier questions, and warnings about traps.
- **Opus 5.5 / Sonnet 5.5** also closed the loop, capturing validated rules.

This is the strongest argument for **provenance and verification** in Recollect.
A note that records only the conclusion is much less useful than a note that
records the conclusion, the evidence, and the conditions under which it was
verified.

### 2.5 Evidence: salience and the Pokémon experiment

Two runs at roughly 10,000 steps:

| Model | Memory files | Folders | Characters | Badges |
|---|---:|---:|---:|---:|
| Sonnet 3.7 | 413 | 225 | 977,930 | 1 |
| Fable 5 | 9 + `global.md` | 2 | 43,406 | 4 |

Sonnet 3.7 recorded everything that might matter: a file per battle, item, and
NPC. Much of that state was **readable from the screen every turn**, so storing
it was redundant. Worse, the game state changed constantly, so the archive went
out of date and had to be combed through. Around step 10,000 it spent 17 steps
creating six files and deleting nine others without taking a game action.

Fable 5 stored what could not be re-read: strategy, plans, tested rules, and a
`global.md` dashboard with the current goal, a gym plan, and its own memory-use
rules. Its Magikarp note is a good example of a durable lesson:

> "If 3+ balls fail in a row, VARY the timing (insert extra 'wait' presses
> between menu steps) — the catch landed right after doing this."

This is the practical form of "memory is a prediction about future needs." The
test is not "is this true?" but "will a future agent need this, and can it not
cheaply re-derive it?"

**Implication for Recollect:** store pointers and claims about re-readable
artifacts (code, docs, file contents), not the artifacts themselves. Recollect's
`context_hints` already capture repo/path/OS, but they are only a weak score
boost; there is no path/symbol anchor index.

### 2.6 Evidence: steering and the danger of fixed rules

Anthropic tested giving models explicit memory rules. The rule "record only
failures" reduced the memory gain:

| Model | Change in memory gain |
|---|---:|
| Opus 5 | −0.234 |
| Opus 4.7 | −0.150 |
| Sonnet 4.6 | −0.020 |

For stronger models, freedom to judge salience beat fixed rules. This does not
mean "never guide the model"; it means **guidance about purpose** ("a memory
folder is available; use it when something is worth remembering") works better
than **hard rules about content** ("only record failures"). Recollect's
`Classification` module is a set of regex rules. It can be useful as a cheap
hint, but it should not be the sole salience policy.

### 2.7 Evidence: wikis, search, and the compression problem

The wiki experiment used a corpus of roughly 350,000 files and 420M tokens from
Stainless, with 25 evaluation questions. Over 128 dreaming sessions, agents
built and maintained linked wiki pages.

| Configuration | Score / behavior |
|---|---|
| Wiki alone, early (2 sessions) | 13% of graded criteria |
| Wiki alone, 128 sessions | 48% |
| Search alone | 53% |
| Wiki + search, early | 54% |
| Wiki + search, 128 sessions | 61% |
| Tokens saved by wiki + search | ~20,000 per question |

Two conclusions:

1. **Wiki + search beats either alone.** The wiki provides cross-document
   synthesis; search provides grounding and detail. The article's best
   wiki-only score (48%) was still below search alone (53%), but the combination
   was better than both.
2. **Synthesis has a compression-ratio problem.** In one Harvey LAB task, a
   10-document, 115 KB corpus produced a 68-page, 255-link, 203 KB wiki — 1.77×
   the source. The article compares this to Borges's map that was as large as the
   empire. A representation that is larger than its sources has abstracted
   nothing.

On a merger-question task where most criteria required combining information
from multiple documents, the wiki scored 87% versus 73% for search alone. On a
task where most criteria could be found in a single document, the wiki showed no
clear gain.

This is the correct way to think about Recollect's summaries and mipmaps: they
are only valuable when they **compress cross-document structure**, not when they
restate what a search result already contains.

### 2.8 Evidence: parallel synthesis can destroy facts

In the legal-brief task, several agents wrote to a shared `provisions.md` page
at the same time. One agent's save erased another's lines. Only 41 of 57 graded
contract facts (72%) survived. After the instructions changed so that each
contract got its own page, written by a single agent, and terms were quoted
verbatim, 57 of 57 facts (100%) survived.

This is a warning for any multi-agent or concurrent dreaming design:

- **Do not let multiple writers share one synthesis target** without
  single-flight or optimistic concurrency.
- **Quote critical evidence verbatim** instead of paraphrasing it into a shared
  table.
- **One source, one page** is a safer default than many-to-one merging.

Recollect's current consolidation has no lock and no provenance, so it is
exposed to the same class of loss.

### 2.9 Evidence: the injected layer must stay small

The article cites Claude Code's auto memory: it loads only the first **200 lines
or 25 KB** of `MEMORY.md` into every session. That header acts as an index, not
as the whole memory. It also warns that longer instruction files reduce
adherence: loading a note does not guarantee the model acts on it.

This is the most directly actionable finding for Recollect. `Search.ContextFormatter`
currently concatenates every section with no token budget, no dedupe, and no
citations, and truncates entries to 200 characters. That is the opposite of a
budgeted index: it includes too many items, each with too little detail, and
gives the model no way to ask for more.

### 2.10 Failure modes the article names

The article is candid about what can go wrong:

| Failure | Description | Recollect analogue |
|---|---|---|
| Wrong from the start | A note is incorrect when written | No verification; `confidence` defaults to 1.0 |
| Drift | A note becomes stale as the environment changes | Decay is time-based, not evidence-based; consolidation crashes |
| Redundant capture | Storing what can be re-read | No pointer/anchor index; mipmap stores four copies |
| Salience failure | Recording everything or the wrong thing | `Classification` regexes; no learned salience |
| Wiki bloat | Representation larger than the corpus | Merged summaries can exceed cluster size; no ratio guard |
| Citation loss | Synthesis cannot be traced to sources | Merge summaries have no `derived_from` edges |
| Injection poisoning | A bad note is loaded every session | Handoff pushes everything into working memory |
| Concurrent overwrite | Parallel writers erase each other | No lock around consolidation/dreaming |
| Compute blowup | Dreaming runs without a budget | O(n²)/O(n³) maintenance; no cost cap |

### 2.11 Open questions the article leaves

The article ends with questions that are also Recollect's questions:

1. **When should memory be created?** In-session capture is immediate but
   distracts the agent; dreaming is cheaper but delayed.
2. **How do you keep memory up to date?** Checking everything is impractical;
   focus on likely-to-change information and tune cadence by access.
3. **Is transcript search the foundation?** The article suggests it may be,
   with representations as an optimization on top.
4. **How much synthesis is worth it?** The compression ratio is the guard, but
   the right threshold is task-dependent.
5. **How do you evaluate memory?** Task success, not recall count, is the
   metric the article implicitly endorses.

---

## 3. What the HN discussion adds

The HN thread is valuable because it supplies the objections the article
glosses over. At the time of reading it had 101 points and 58 comments. The
themes below are synthesized from the top-level comments and the earlier
discussion; usernames are included where a claim is quoted.

### 3.1 "Notes are not learning"

`grey-area` and `aszen` make the strongest epistemological objection: biological
memory changes weights, while these systems write markdown. `aszen`:

> "these models cannot learn continuously i.e. update their weights ... no amount
> of markdown tricks will change that."

The article pre-empts this by defining agent memory narrowly, but the marketing
framing still invites the confusion. Recollect should be precise:

- It provides **external, inspectable adaptation**, not weight updates.
- The correct claim is "the agent can act on past experience," not "the model
  learned."
- Evaluation should measure task-level adaptation, not store growth.

`troupo` pushes further:

> "Then it's not 'memory'. It's just telling the model to read a text/spec file
> before implementing something."

This is uncharitable but useful: if the only mechanism is "put text in the
prompt," then the quality of selection and formatting *is* the product. That is
exactly where Recollect's missing token budget and citations hurt.

### 3.2 Models are bad at creating useful memories

`ford`:

> "I've found models to be terrible at creating useful memories, or doing
> anything incremental over time."

`yfontana`:

> "I probably delete 95% of them. The memories it creates are almost always
> relevant only to the specific task that it is currently working on."

This is the strongest argument against maximal capture. Bad memory is worse than
no memory because it consumes context and can mislead. The design response is
not "capture less" alone; it is:

- gate capture by salience or explicit intent,
- make review and pruning fast,
- attach a source to every injected item,
- prefer pointers over prose.

`prtmnth` describes a `memory-prune` skill that decides whether a memory belongs
in a code comment, a project rule, a global `AGENTS.md`/`CLAUDE.md`, or nowhere.
That is a useful product pattern: **memory placement is a decision, not a
default.**

### 3.3 Provenance and dialectic instead of overwriting

`benfortuna`:

> "Conflict resolution is important, but the thing I think most memory models are
> missing is provenance. Memories are modified/overwritten instead of retained as
> the source of any resolution."

He links [Particulars](https://particulars.fyi/), a dialectical knowledge format:
thesis → antithesis → synthesis → next thesis. The synthesis preserves the
reasoning and declares what remains unresolved.

For Recollect, this is a direct critique of `Knowledge.supersede/3`, which
zeroes the old entry's confidence and half-life and loses the reasoning. A
better model is:

- keep the old claim with `valid_to` and a link to the new claim,
- record the evidence on both sides,
- store the synthesis and the unresolved questions,
- never silently overwrite.

### 3.4 Scoping is a first-class problem

`russellbeattie` discovered that his Claude Code project had 61 memory files and
that they were scoped to that project, not global. He had assumed some rules
were global. This is a common UX failure: users do not know where a memory
lives or how broadly it applies.

Recollect has `scope_id` and `owner_id`, but no explicit **memory level**
(global / workspace / session / agent) or inheritance semantics. A global
preference, a workspace convention, a session note, and a subagent scratchpad
all look the same in `recollect_entries`. The implementation plan adds a
`memory_level` field and a precedence order.

### 3.5 Users want review, not just write

The thread repeatedly describes memory hygiene as an explicit activity:
pruning, reviewing, promoting to rules, deleting. `yfontana` deletes 95%;
`prtmnth` has a prune skill; `russellbeattie` cleans up 61 files. A memory system
needs a **review API** and a **why is this here?** query, not just `remember/1`
and `forget/1`.

### 3.6 Transcripts are under-used

`yfontana` suggests ingesting transcripts into DuckDB and analyzing tool-call
failures, cache misses, and token efficiency. The article also treats
transcripts as the ground truth for dreaming. Recollect's learning pipeline
reads coding-agent transcripts but extracts records and discards the raw events,
which makes later verification impossible.

### 3.7 Wiki + search beats dreaming-only

`andai` reads Figure 10 correctly:

> "it looks like wiki + search beats dreaming, and that dreaming adds only
> marginal gains to the wiki + search configuration."

The article's own numbers support this: search alone 53%, wiki + search 61%,
wiki alone 48%. Dreaming is the process that builds the wiki; it is not a
substitute for retrieval. Recollect should not replace search with a
consolidation job. It should use retrieval to ground synthesis and synthesis to
improve retrieval.

### 3.8 Operational skepticism

`bob1029` is worried about volatility:

> "The biggest thing I want to avoid with a long running agent is volatility.
> Anything that pushes it into one direction or the other that quickly is not
> desirable."

`MASNeo` and `xtiansimon` object to the anthropomorphism of "dreaming." These are
not just tone objections. They imply product requirements:

- memory changes should be gradual and auditable,
- the system should be able to explain why a memory was promoted or pruned,
- the vocabulary in docs should be precise ("offline consolidation," not
  "the agent dreams").

### 3.9 What the thread gets wrong

The thread sometimes conflates **storage** with **learning** and concludes that
external memory is worthless. That is too strong. The CL-Bench and wiki results
show real gains from external memory, even if they are not weight updates. The
thread also underestimates the value of a good index: a small, well-cited brief
can outperform a large archive. The right response is not defensiveness; it is
to build the measurement that separates good memory from bad.

---

## 4. Linked sources

| Source | Core idea | What Recollect should take |
|---|---|---|
| [Google Sleep framework](https://research.google/blog/the-sleep-framework-a-new-way-for-llms-to-retain-knowledge-in-continual-learning/) | Offline consolidation with generate → validate → consolidate; guard against catastrophic forgetting | Stage the dream job; validate before merging; keep the previous state on failure |
| [Particulars / Dialectical Knowledge Format](https://particulars.fyi/) | Thesis → antithesis → synthesis, preserving reasoning and unresolved questions | Replace destructive supersession with an explicit reconciliation record |
| [myFleet](https://gitlab.com/doering-ai/libs/fleet) | Skills, charters, behavior policies for agent fleets; sync across harnesses | Memory levels and policy inheritance; agent-specific vs workspace-wide rules |
| [Innerloop Breadcrumb](https://innerloop.works/breadcrumb) | Folder scopes with rules and notes; session/screen capture | Global + project rule inheritance; scoped review UI |
| [CL-Bench 1.0](https://continual-learning-bench.com/news/cl-bench-1-0/) | Sequential tasks that measure retention and interference | Evaluation harness: memory on/off, sequential sessions, ablations |
| [Letta sleep-time compute](https://arxiv.org/abs/2504.13171) | Background compute reorganizes memory to reduce test-time cost | Treat dreaming as an investment with a budget and a cost model |

The common thread: **memory is a lifecycle, not a table.** The value comes from
what is promoted, pruned, and injected, not from how much is stored.

---

## 5. Recollect today

### 5.1 Layer map

| Article layer | Recollect today | Storage | Gap |
|---|---|---|---|
| Transcripts | `Recollect.Learning.*` reads coding-agent events, extracts records, then discards the raw events | none (host-dependent) | No append-only event ledger; no evidence links |
| Memory notes | `recollect_entries` via `Knowledge.remember/2` | `recollect_entries` | No tags, memory level, stability, epistemic status, validity window, or evidence |
| Representations | `recollect_mipmaps` (4 levels), `recollect_documents.summary`, consolidation summaries | `recollect_mipmaps`, `recollect_documents`, `recollect_entries` | No pages/wiki; no citations; summaries are orphan entries |
| Injected context | `Search.ContextFormatter.format/1`, `Handoff`, `WorkingMemory.load_handoff/1` | prompt text / JSON blobs | No token budget, dedupe, citations, or stable brief |
| Dreaming | `Consolidation.run/1`, `ConflictDetection`, `Sleep.promote/1` | `recollect_consolidation_runs`, `recollect_conflicts` | Broken or non-persisting; no verification, budget, or idempotency |

### 5.2 What a memory actually is

`recollect_entries` (see `lib/recollect/schema/entry.ex:13-36`) has:

```
id, scope_id, owner_id, entry_type, content, summary, source, source_id,
embedding, embedding_model_id, metadata, access_count, last_accessed_at,
confidence, half_life_days, pinned, emotional_valence, schema_fit,
outcome_score, confidence_state, context_hints, inserted_at, updated_at
```

Notably absent:

- `tags` — accepted by `Knowledge.remember/2` and then dropped.
- `memory_level` — no global/workspace/session/agent distinction.
- `stability` — no stable/evolving/volatile distinction.
- `epistemic` — no observed/inferred/held distinction.
- `valid_from` / `valid_to` — no bi-temporal validity.
- `verified_at` / `verification` — no record of how a claim was checked.
- `evidence` links — no connection to the transcript or source.
- `version` / `deleted_at` — no explicit versioning or tombstone.

### 5.3 Write paths

There are three:

1. **Tier 1 document ingestion** — `Pipeline.Ingester` → documents → chunks →
   embeddings → entities/relations. This is a separate, well-defined pipeline.
2. **Tier 2 knowledge** — `Knowledge.remember/2` inserts an entry, then
   asynchronously embeds it and (via `Embedder.embed_entry_async/1`) persists
   four mipmaps.
3. **Learning** — `Learning.Pipeline` reads git/coding-agent events, extracts
   records, and calls `Knowledge.remember/2` for each.

The Tier 2 write path is the one that matters for agent memory.

### 5.4 Retrieval path

```
Search.search/2
  → Vector.search/2
      → embed query (once)
      → chunks query
      → entries query (Postgres or SQLite)
      → document summaries query
      → mipmap escalation if results < 3
  → graph expansion (entities + relations)
  → edge following (related entries)
  → ContextFormatter.format/1
```

There is no lexical retrieval, no rank fusion, no global limit, and no token
budget. Results are concatenated by category, not ranked globally.

### 5.5 Maintenance path

```
Consolidation.run/1
  → decay_pass (in memory)
  → merge_pass (pairwise text overlap)
  → ConflictDetection.detect/1
  → SchemaIndex.rebuild/0
  → persist stats + conflicts + summary entries
```

Plus:

- `Maintenance.Decay.run/1` — archive stale entries (works, Ecto-based).
- `Invalidation` — weaken entries matching migration patterns (Postgres-only
  raw SQL).
- `Confidence` — stale/observed/verified lifecycle (partially Postgres-only).
- `Outcome` — half-life feedback (Postgres-only).
- `RetrievalCounter` — batch retrieval counts (Postgres-only flush).
- `Sleep.promote/1` — working memory → permanent memory.

### 5.6 Capability matrix versus the article

| Capability | Article | Recollect | Status |
|---|---|---|---|
| Raw transcript retention | Yes | Partial (read, then discarded) | Missing L0 |
| Atomic notes | Yes | Yes | Present, but no tags/evidence |
| Salience judgment | Learned/model-driven | Regex `Classification` | Weak |
| Wiki/pages | Yes | No | Missing L2 |
| Citations/provenance | Yes | No (orphan summaries) | Missing |
| Offline correction | Yes | Broken consolidation | Missing |
| Budgeted injection | Yes (200 lines / 25 KB) | No budget | Missing |
| Search + wiki | Yes | Search only | Partial |
| Decay/pruning | Yes | Intended, not persisted | Broken |
| Conflict reconciliation | Yes (dialectic) | Dead code | Broken |
| Evaluation by task success | Yes | No harness | Missing |
| Backend parity | N/A | Advertised, not delivered | Partial |

---

## 6. Correctness bugs found while mapping the system

These are not stylistic issues. Each one either prevents a documented feature
from working or silently corrupts the signal that the rest of the system depends
on. They should be fixed before adding layers.

### 6.1 P0: `Consolidation.run/1` raises on any non-empty scope

**Where:** `lib/recollect/consolidation.ex:120-122`, `:143-144`;
`lib/recollect/strength.ex:26-33`.

`fetch_entries/2` builds maps with **string keys** via
`Recollect.Util.row_to_map(columns, row)`. `decay_pass/2` then does:

```elixir
entry = struct(Recollect.Schema.Entry, entry)
entry.pinned || Strength.calculate(entry, now) >= threshold
```

`struct/2` only uses atom keys. Every string key is ignored, so every field on
the resulting struct is `nil`:

```elixir
iex> struct(Recollect.Schema.Entry, %{"pinned" => true, "content" => "x"})
%Recollect.Schema.Entry{pinned: nil, content: nil, ...}
```

`entry.pinned` is `nil` (falsy), so `Strength.calculate/2` runs. It calls
`decay_factor/2`, which does:

```elixir
last = entry.last_accessed_at || entry.inserted_at  # nil
days = DateTime.diff(now, last, :second)
```

`DateTime.diff(now, nil, :second)` raises `FunctionClauseError`. Result:
**`Consolidation.run/1` raises for any scope with at least one non-archived
entry.** The `mix recollect.consolidate` task is effectively broken. There are
no consolidation tests in `test/`.

**Fix:** build atom-keyed structs correctly (e.g. select into the schema with
Ecto, or map the raw row through a typed changeset/`Ecto.Type.load`), and add a
test with at least one entry. Also treat `half_life_days <= 0` defensively in
`Strength.decay_factor/2`.

### 6.2 P0: Decay never removes anything

**Where:** `lib/recollect/consolidation.ex:77-94`, `:138-148`.

`decay_pass/2` splits entries into `survivors` and `removed` in memory, but
`run/1` only records `removed: length(decay_result.removed)` in
`recollect_consolidation_runs`. There is no `DELETE`, no
`UPDATE ... SET entry_type = 'archived'`, and no edge cleanup. Entries below the
threshold remain fully searchable forever.

The returned stats are also misleading: `decayed` and `removed` are both the
in-memory count, not a database effect.

**Fix:** apply the removal in the same transaction as the run record, or archive
with `entry_type = 'archived'` (which the search filters already exclude) and
record the actual affected rows. Make `dry_run` truly side-effect free.

### 6.3 P0: Merge summaries are orphan noise

**Where:** `lib/recollect/consolidation.ex:150-197`, `:199-227`, `:229-242`,
`:277-292`.

`merge_pass/4` finds clusters by pairwise text overlap and creates summary text,
but `create_summary_entries/4` inserts each summary as a plain `note` entry:

```sql
INSERT INTO recollect_entries
  (id, scope_id, owner_id, entry_type, content, confidence, ...)
VALUES ($1, $2, $3, 'note', $4, 0.8, ...)
```

It does **not**:

- create `derived_from` edges to the cluster members,
- supersede or archive the members,
- mark the entry as a synthesis (`entry_type`, metadata, or a page),
- record which entries were merged.

So the cluster members remain, the summary competes with them in vector search,
and there is no way to trace the summary back to its sources. This is the
opposite of the article's "representations" layer.

Additional bugs in the same area:

- **Union-find grouping is wrong.** `build_clusters/2` groups by the raw parent
  value (`Enum.group_by(fn {_k, v} -> v end, ...)`) instead of resolving the
  root with `find`. Chains like `0 -> 1 -> 2` split into `{1: [0], 2: [1, 2]}`
  instead of one cluster. The `find` function exists but is not used at grouping
  time.
- **O(n³) list access.** `merge_pass/4` computes `Enum.at(entries, i)` and
  `Enum.at(entries, j)` inside an O(n²) pair loop. `Enum.at/2` on a list is
  O(i), so the pair loop is O(n³) in list traversal. `ConflictDetection` has the
  same pattern. For 1,000 entries this is already painful; for 10,000 it is
  unusable.
- **`merged` counts members, not merges**: `length(List.flatten(valid_clusters))`.
- **`create_semantic_summary/1`'s `length(cluster) <= 2` branch is dead** with
  the default `min_cluster: 3`.

**Fix:** use a typed struct/tuple for O(1) access, block candidates by tag/entity
or MinHash before pairwise comparison, fix the union-find grouping, create
`derived_from` edges from summary → members, supersede or archive members, and
store the summary as a page (or a dedicated `synthesis` entry type) with source
links.

### 6.4 P0: Conflict detection never runs

**Where:** `lib/recollect/conflict_detection.ex:113-147`.

```elixir
SELECT id, content, tags_json FROM recollect_entries
WHERE scope_id = $1 AND entry_type != 'archived'
```

Two independent failures:

1. **`tags_json` does not exist.** The column is not in the schema or in any
   migration. The query errors, and `get_active_entries/1` returns `[]`, so
   `detect/1` returns `[]` before comparing anything.
2. **The UUID parameter is passed as a string.** `[scope_id]` is used directly,
   whereas every other Postgres path uses `Recollect.Util.uuid_to_bin(scope_id)`.
   Even if `tags_json` existed, the query would fail on the UUID encoding.

Consequences:

- `recollect_conflicts` is never populated by consolidation.
- `Conflicts.list/1` and the resolution API are dead code in practice.
- The `Knowledge.check_contradiction/3` path is also not called from
  `Knowledge.remember/2`, so there is no other automatic path.
- `Conflicts.persist/3` has `ON CONFLICT (entry_a_id, entry_b_id) DO NOTHING`;
  a previously resolved conflict will not reopen if detected again, and pair
  order is not canonicalized (the query has no `ORDER BY`), so `(a,b)` and
  `(b,a)` can both be inserted on different runs.

**Fix:** add a real `tags` column (or drop the select), pass `uuid_to_bin`, add
`ORDER BY id`, canonicalize pair order (or use a `least/greatest` expression
index), and update an existing open/resolved row deliberately instead of
`DO NOTHING`.

### 6.5 P0/P1: Tags are accepted, then discarded

**Where:** `lib/recollect/knowledge.ex:41`, `:64-80`;
`lib/recollect/schema/entry.ex:13-36`;
`lib/recollect/migration_generator.ex:215-237`;
`priv/repo/migrations/20240101000000_create_mneme_tables.exs:162-183`.

`Knowledge.remember/2` reads `tags = Keyword.get(opts, :tags, [])` but never
puts them in `attrs`, and `recollect_entries` has no tags column. The same is
true for the migration generator, so new installs do not get one either.

This breaks several advertised behaviors:

- `Search.Vector`'s moduledoc advertises `:tags` filtering
  (`lib/recollect/search/vector.ex:39-43`), but `build_entry_filters_pg/1` and
  `build_entry_filters_sqlite/1` only implement `entry_type`, `confidence_min`,
  and `temporal` (`:675-751`). A `tags` filter is silently ignored.
- `ConflictDetection` expects `tags_json` (which never existed).
- `SchemaIndex.rebuild/0` selects `tags_json` (`lib/recollect/schema_index.ex:27`);
  the query errors, `entries` is `[]`, `entry_count` is 0, and
  `SchemaFit.compute/3` therefore returns the neutral `0.5` for every write.
  `SchemaFit` has been effectively disabled. Worse, `Consolidation.run/1` is the
  **only** caller of `SchemaIndex.rebuild/0` (`lib/recollect/consolidation.ex:72`),
  and consolidation crashes in `decay_pass/2` before it ever reaches line 72 —
  so the index is never populated in practice.
- `Mipmap.to_full/1`, `to_summary/1`, and `to_abstract/1` reference
  `entry.tags` (`lib/recollect/mipmap/generator.ex:223`, `:237`, `:254`). On a
  `%Recollect.Schema.Entry{}` that key does not exist, so `Mipmap.generate_for/1`
  raises `KeyError` if called with a struct (the embedder works around this by
  passing a plain map with `tags: []`).

**Fix:** add `tags` to the schema and both migrations (`text[]` on Postgres,
JSON text on SQLite/libSQL), store it in `Knowledge.remember/2`, implement the
filter in both query builders, index it (GIN on Postgres), and backfill from
`metadata["tags"]` if any host has been storing tags there.

### 6.6 P1: Retrieval counts are undercounted

**Where:** `lib/recollect/retrieval_counter.ex:74-105`.

`do_flush/0` reads `entries = :ets.tab2list(@table)`, which yields
`{entry_id, count}` pairs, but the SQL ignores `count`:

```sql
UPDATE recollect_entries
SET access_count = access_count + 1,
    half_life_days = half_life_days + $1,
    ...
WHERE id = ANY($3)
```

If a memory is retrieved 200 times in a 30-second flush window, it gets
`+1`, not `+200`. The half-life boost is also per flush, not per retrieval. Since
`Strength.retrieval_boost/1` uses `log2(count + 1)`, this materially distorts
which memories survive decay.

**Fix:** pass `{id, count}` pairs and update with `access_count + count` (e.g.
`UPDATE ... FROM unnest($3::uuid[], $4::int[]) AS t(id, count)`), and scale the
half-life boost by the count with a cap.

### 6.7 P1: `Search.search/2` applies `limit` per category

**Where:** `lib/recollect/search/vector.ex:57-62`;
`lib/recollect/search.ex:40-81`.

`Vector.search/2` passes the same `limit` to chunks, entries, document
summaries, and mipmap escalation. Results are concatenated in category order.
With `tier: :both`, a `limit: 10` request can return 10 chunks + 10 entries +
10 document summaries + up to 30 summary-derived chunks (3 per summary) + mipmap
results, plus graph entities and related entries. There is no global score
fusion and no global cap.

`Search.search/2` then separates by `result_type` and adds graph results. The
context pack can be far larger than the caller asked for, and the first category
wins on ordering rather than relevance.

**Fix:** retrieve a candidate pool per source (e.g. `k = limit * 3`), fuse with
reciprocal rank fusion or a weighted score, dedupe by entry id, apply a global
`limit`, then apply a token budget. Keep per-source limits as an internal
detail.

### 6.8 P1: Context detection shells out on every write and search

**Where:** `lib/recollect/search/vector.ex:766-776`;
`lib/recollect/knowledge.ex:44-50`;
`lib/recollect/context/detector.ex:83-103`.

`Knowledge.remember/2` calls `Detector.detect()` unless `:context_hints` is
provided. `Search.Vector.add_context_boost/1` calls it on every entry search.
`Detector.detect/0` runs two subprocesses when inside a git repo:

```elixir
System.cmd("git", ["rev-parse", "--show-toplevel"], ...)
System.cmd("git", ["remote", "get-url", "origin"], ...)
```

That is two process spawns per memory write and per search. It is pure overhead
for the common case where the cwd has not changed.

**Fix:** cache detected context per process/scope with a short TTL (or accept an
explicit `:context` option), and make auto-detection opt-in. The docs claim the
detectors are pure; they are not — they shell out.

### 6.9 P1: Mipmap write amplification and redundant query embedding

**Where:** `lib/recollect/mipmap/generator.ex:50-106`, `:121-200`;
`lib/recollect/pipeline/embedder.ex:84-141`;
`lib/recollect/search/vector.ex:52-62`, `:192-213`.

Every `Knowledge.remember/2` triggers:

- 1 entry embedding (`Embedder.embed_entry_async/1`),
- 4 mipmap embeddings (`Mipmap.persist/1` calls `Embedder.embed_query/1` once
  per level),
- 4 `INSERT ... ON CONFLICT` + 4 `UPDATE` statements.

So a single memory write can cost **5 embedding calls and 8 mipmap statements**
on top of the entry insert. The mipmap embedding calls are serial and could be
batched (`EmbeddingProvider.generate/1` accepts a list).

On the read side, `Mipmap.retrieve/3` embeds the query again
(`lib/recollect/mipmap/generator.ex:139`) even though `Vector.search/2` already
embedded it at `:53`. The escalation path therefore doubles query embedding
cost.

`determine_level/1` picks one level by query character length and searches only
that level. It is not a coarse-to-fine cascade, so the "mipmap" name overstates
what it does.

**Fix:** embed the query once and pass the vector into mipmap retrieval; batch
the four level texts into one provider call; generate mipmaps lazily or only for
entries above a salience threshold; consider a single coarse pass followed by a
detail fetch instead of four stored levels.

### 6.10 P1: `Sleep.promote/1` can lose memories

**Where:** `lib/recollect/sleep.ex:69-107`.

```elixir
{:ok, candidates} = WorkingMemory.read(scope_id)
distilled = distill(candidates, opts)
...
{:ok, n} = WorkingMemory.clear(scope_id)
```

Two loss modes:

1. **Concurrent pushes between read and clear are discarded.** The buffer is not
   drained atomically.
2. **Partial promotion failure still clears everything.** Failed `persist/3`
   calls are logged and skipped, but the entire buffer is flushed regardless.

There is also no provenance: promoted items are new entries with
`metadata.origin = "sleep"` and no link to the working-memory item or the
transcript that produced it.

**Fix:** add an atomic `drain` operation to the `WorkingMemory.Server` (swap the
list under a single `handle_call`), remove only successfully persisted items,
and attach source IDs/evidence to the promoted entry.

### 6.11 P1: Postgres-only SQL in "adapter-agnostic" modules

Recollect advertises PostgreSQL, SQLite, and libSQL support. Several maintenance
and feedback paths use Postgres-only placeholders and functions:

| Module | Lines | Issue |
|---|---|---|
| `Consolidation` | `:244-267`, `:277-292` | `$1` placeholders |
| `ConflictDetection` | `:116-122` | `$1`, plus string UUID |
| `Conflicts` | `:15-22`, `:36-43`, `:64-91`, `:147-165` | `$1` placeholders |
| `Handoff` | `:51-69`, `:81-90`, `:124-131`, `:159-171` | `$1` placeholders |
| `Confidence` | `:43-50`, `:64-67` | `$1`, `ANY($2)` |
| `Outcome` | `:63-72` | `$1`, `ANY($4)` |
| `Invalidation` | `:169-181`, `:193-204` | `$1`, `ILIKE` |
| `RetrievalCounter` | `:88-98` | `$1`, `ANY($3)` |
| `SchemaIndex` | `:25-28` | `tags_json` |

On SQLite/libSQL these either raise (often rescued and silently ignored) or
return `{:error, _}` that callers treat as "nothing happened." The result is
that decay/consolidation/conflict/outcome behavior differs by backend in ways
the docs do not describe.

**Fix:** either (a) use Ecto queries/`Ecto.Adapters.SQL` with adapter-aware
placeholders, or (b) explicitly gate these features with a clear
`{:error, :unsupported_backend}` and document the matrix. Add a CI matrix test
that runs the maintenance suite on both backends.

### 6.12 P1: Supersession writes `half_life_days: 0.0`, which can crash `Strength`

**Where:** `lib/recollect/knowledge.ex:211-216`;
`lib/recollect/strength.ex:26-33`.

`Knowledge.supersede/3` zeroes `half_life_days` unless `keep_strength: true`:

```elixir
%{metadata: metadata, half_life_days: 0.0, confidence: 0.0}
```

`Strength.decay_factor/2` does:

```elixir
half_life = entry.half_life_days || 7.0
:math.pow(0.5, days / half_life)
```

`0.0` is truthy in Elixir (only `nil` and `false` are falsy), so `half_life`
stays `0.0` and `days / 0.0` raises `ArithmeticError`. Any code that calls
`Strength.calculate/2` on a superseded entry — including a fixed consolidation
pass that fetches all non-archived entries — will crash. `Outcome` and
`Conflicts.resolve` use `GREATEST(1, ...)`, so they avoid it, but the stored
value is still a landmine.

**Fix:** store a small positive half-life (e.g. `0.01`), or make
`decay_factor/2` handle `half_life <= 0` explicitly.

### 6.13 P1: Learning re-imports every event on every run

**Where:** `lib/recollect/learning/coding_agent.ex:46-65`;
`lib/recollect/learning/pipeline.ex:44-55`, `:105-130`.

`Learning.Pipeline.run/1` passes `since` to each learner. For the coding-agent
learner, `fetch_since/2` ignores it:

```elixir
def fetch_since(_since, scope_id) do
```

It calls `fetch_events/2` without a time/project filter. Every pipeline run
re-reads all sessions, re-extracts every record, and calls
`Knowledge.remember/2` again. There is no dedup on `source_id` or content, so
repeated runs create duplicate entries. `Learner.Harvest` has a checkpointed
path (`fetch_authorized_events/2` with `since`), but the `Learning.Pipeline`
path does not use it.

**Fix:** thread the `since` cursor through `fetch_since/2`, and make
`Knowledge.remember/2` upsert or skip on `(source, source_id)`. A unique index
on `(source, source_id)` (partial, where `source_id IS NOT NULL`) would make the
dedup enforceable.

### 6.14 P2: Classification context hints never match

**Where:** `lib/recollect/classification.ex:93-115`;
`lib/recollect/context/detector.ex:28-31`, `:88-97`.

`Knowledge.remember/2` passes `context_hints` from `Detector.detect/0`, which
returns keys like `:repo`, `:path_prefix`, and `:os`. `Classification.classify/2`
matches `%{git_repo: _}` and `%{file_path: path}`. The keys never line up, so
the context-aware boost is dead code.

**Fix:** align the key names (or use the detector's keys in `classify/2`), and
add a test with a real detected context map.

### 6.15 P2: `SchemaFit.compute/3` becomes an O(500) tokenization per write

**Where:** `lib/recollect/schema_fit.ex:60-92`.

Today the schema index is broken, so `compute/3` short-circuits at `n == 0` and
returns `0.5`. Once the index is fixed, every `Knowledge.remember/2` will:

- query the 500 most recent entries in the scope,
- tokenize each entry's content,
- compute a Jaccard similarity for each.

That is up to 500 tokenizations + comparisons per write, on the critical path.
The fix to the index would expose a write-path performance cliff.

**Fix:** precompute token sets in the index or a separate table, sample instead
of scanning 500, move the computation to an async enrichment step, or use a
cheap sketch (MinHash) instead of full Jaccard.

### 6.16 P2: `ContextFormatter` has no budget, dedupe, or citations

**Where:** `lib/recollect/search/context_formatter.ex:6-21`, `:38-52`,
`:56-67`.

`format/1` concatenates every section. Entries are truncated to 200 characters
(`String.slice(content, 0, 200)`), which loses the exact detail that made them
worth retrieving, while still including up to 20 entities and 20 relations.
There is no dedupe between `entries` and `related_entries`, no token estimate,
no citation IDs, and no way for the model to ask for more detail.

**Fix:** add `format/2` with `:max_tokens`, `:include_citations`, and
`:dedupe`; return item IDs and a compact index; prefer summaries for the brief
and expose full content through a follow-up fetch.

### 6.17 P2: `Handoff` is unbounded and `WorkingMemory` is ephemeral

**Where:** `lib/recollect/handoff.ex:35-72`, `:77-116`;
`lib/recollect/working_memory.ex:25-56`;
`lib/recollect/working_memory/server.ex:44-74`.

`Handoff.create/2` stores `what`, `next`, `artifacts`, and `blockers` as JSON
text with no token budget. `WorkingMemory.load_handoff/1` pushes every item into
a 20-slot buffer at high importance, so a large handoff can evict the session's
actual working notes.

`WorkingMemory` is a per-scope GenServer with no persistence, no TTL, and no
cross-node replication. A node restart loses the bulletin. That may be
acceptable for Tier 0, but the docs should say so, and there should be an
explicit promotion path before shutdown.

**Fix:** make the handoff a budgeted brief (`Recollect.Brief`), cap the loaded
items, and document the ephemerality. Add an optional persistence adapter for
working memory if a host needs it.

### 6.18 P2: `Outcome` overwrites instead of accumulating

**Where:** `lib/recollect/outcome.ex:63-72`.

```sql
SET outcome_score = $2
```

`$2` is `1` for good and `-1` for bad. Repeated feedback overwrites the previous
score instead of accumulating or averaging. `Outcome.do_update/3` also sets
`confidence_state = 'verified'` for any positive score (`outcome.ex:68`), so a
single "good" signal permanently promotes the entry to the highest trust state.

**Fix:** accumulate (`outcome_score = outcome_score + $2`) with a clamp, or store
a separate `positive_outcomes`/`negative_outcomes` pair and derive a score. Only
mark `verified` after a stronger signal (e.g. test pass or explicit user
confirmation).

### 6.19 P2: `Search.Vector` owner search does not reinforce memories

**Where:** `lib/recollect/search/vector.ex:322-348`, `:301-320`.

`do_search_entries/6` calls `bump_retrieval/1`, `track_for_outcome/2`, and
`Confidence.wake_up_stale_entries/1`. `do_search_entries_by_owner/6` does not.
Global-brain search therefore never increments access counts, never wakes stale
entries, and never records the last-retrieved set for outcome feedback.

**Fix:** move the reinforcement into a shared helper and call it from both
paths.

### 6.20 P2: Minor consistency issues

- `Consolidation.run/1` calls `SchemaIndex.rebuild/0` even in `dry_run`
  (`:72`), mutating global ETS state during a preview.
- `SchemaIndex.rebuild/0` scans **all** entries across all scopes, not just the
  scope being consolidated, so tag frequencies are global and unrelated scopes
  influence each other.
- `Recollect.Search.Vector.search/2` embeds the query even when both `scope_id`
  and `owner_id` are nil, then returns an empty result.
- `Recollect.Knowledge.remember/2` returns before the async embedding and
  mipmap persistence complete, so an immediate search may miss the new entry.
  This is eventual consistency by design, but it is not documented.
- `Knowledge.remember/2` does not enforce uniqueness on `(source, source_id)`,
  so repeated learning imports duplicate.
- `ConflictDetection.detect/1` and `Consolidation.merge_pass/4` both use
  `Enum.at/2` inside O(n²) loops, making the pair generation O(n³) in list
  traversal.
- `Recollect.Maintenance.Decay.run/1` archives entries but leaves their edges
  and mipmaps in place; searches exclude archived entries, but mipmap retrieval
  joins `recollect_entries` by `scope_id` without excluding `archived`, so an
  archived entry's mipmaps can still surface. (Verify and add the same
  `entry_type != 'archived'` predicate.)
- `recollect_edges` has a unique index on
  `(source_entry_id, target_entry_id, relation)`, which helps forward traversal
  but not the `NOT EXISTS` superseded-exclusion subquery by
  `(target_entry_id, relation)`. Add a target-side index.

---

## 7. Efficiency analysis

### 7.1 Cost model (current code)

| Operation | Embedding calls | DB queries | Subprocesses | Notes |
|---|---:|---:|---:|---|
| `Knowledge.remember/2` | 1 + 4 | ~10 | 2 | entry insert, 4 mipmap inserts + 4 updates, schema-fit 500-row scan once fixed |
| `Search.search/2` (`:both`) | 1 + 1 (mipmap escalation) | up to ~12 | 2 | chunks, entries, summaries, mipmaps, retrieval flush, confidence, graph/edge queries |
| `Consolidation.run/1` | 0 | O(n) + O(n²) comparisons | 0 | crashes today; O(n³) list traversal; full schema rebuild |
| `ConflictDetection.detect/1` | 0 | 1 + O(n²) comparisons | 0 | query errors today; O(n³) list traversal |
| `SchemaIndex.rebuild/0` | 0 | 1 full-table scan | 0 | global, not per-scope |
| `Sleep.promote/1` | 1 per promoted item | 1 read + 1 clear + N inserts | 0 | loses concurrent/unsuccessful items |

### 7.2 The four amplifiers

1. **Write amplification.** One logical memory becomes an entry + 4 mipmap
   rows + 4 mipmap embeddings + 4 updates. The mipmaps are generated eagerly
   even for low-value notes.
2. **Read amplification.** Per-category `limit`s, graph N+1, edge following,
   and no dedupe mean a `limit: 10` search can inject dozens of items.
3. **Maintenance amplification.** O(n²) pair generation with O(n) `Enum.at`
   inside, plus a full-table schema rebuild, plus a second O(n²) conflict pass.
4. **Process amplification.** Two git subprocesses per write and per search.

### 7.3 Efficiency principles for the redesign

- **Embed once, reuse everywhere.** Query embeddings should flow through
  retrieval, mipmap escalation, and reranking.
- **Generate representations lazily.** A mipmap or page should exist because it
  was useful, not because a row was written.
- **Retrieve coarse-to-fine.** Start with a cheap index, expand only the
  candidates that survive.
- **Budget the prompt.** Tokens are the real cost unit; rows are not.
- **Block before comparing.** Tags, entities, and locality should reduce the
  candidate set before any O(n²) pass.
- **Make maintenance incremental.** Track a cursor/high-water mark per scope;
  do not rescan the world.
- **Measure the right things.** Useful tokens per injected token, task success
  delta, and p95 latency matter more than total recall count.

---

## 8. Design implications

### 8.1 Adopt, adapt, reject

| Article element | Decision | Rationale | Recollect action |
|---|---|---|---|
| Four-layer separation | **Adopt** | The layers have different lifecycles, costs, and failure modes | Add L0 events, L1 claims, L2 pages, L3 brief |
| Dreaming as offline compute | **Adopt, with guardrails** | Valuable, but unbounded synthesis is expensive and hard to audit | `Recollect.Dream` with lock, budget, dry run, metrics |
| Wiki + search | **Adopt** | The article's strongest result; synthesis without grounding drifts | Pages with citations + lexical/vector fusion |
| Budgeted injected layer | **Adopt** | Tokens are the real cost; long instruction files reduce adherence | `Recollect.Brief` with a hard token cap |
| Provenance and citations | **Adopt** | Without sources, synthesis cannot be corrected | Evidence table + page sources |
| Task-success evaluation | **Adopt** | Recall count rewards retrieval, not usefulness | Eval harness with memory on/off and ablations |
| Learned salience | **Adopt incrementally** | Fixed rules can reduce the memory gain | Keep regex hints; add outcome-based promotion and review |
| "Dreaming" vocabulary | **Adapt** | Anthropomorphic and vague | Use "offline consolidation" in docs; `Dream` as an internal module name |
| Mipmaps as representations | **Adapt** | Four eager copies per entry is write amplification | Make them lazy; replace with page sections where possible |
| Handoff as injected context | **Adapt** | Unbounded JSON can evict working notes | Render it through the brief with a budget |
| Unbounded capture | **Reject** | More memory increases distractors | Salience gates + review + pruning |
| Overwrite-on-supersede | **Reject** | Loses reasoning and evidence | Dialectic reconciliation + validity windows |
| Recall count as success | **Reject** | Rewards the wrong thing | Measure token efficiency and task delta |
| One memory table for everything | **Reject** | Forces one lifecycle on four objects | Separate tables with explicit links |

### 8.2 Target architecture

```
L0  Event ledger          append-only transcripts, tool calls, observations
L1  Claims / notes        atomic, tagged, scoped, evidenced, versioned
L2  Pages / wiki          synthesized, cited, compression-guarded
L3  Brief                 budgeted, rendered injection context
    Recall index          path/symbol → claim/page anchors
    Dream orchestrator    verify → reconcile → synthesize → promote → prune
```

The layers are connected by explicit provenance:

```
event ──supports/contradicts──▶ claim ──derived_from──▶ page
  │                              │                      │
  └──────── evidence ────────────┘                      │
                                                        ▼
                                                     brief
```

The full data model, API surface, and phased delivery plan are in
[`agent-memory-implementation-plan.md`](agent-memory-implementation-plan.md).

### 8.3 Design principles

1. **Memory is a prediction, not an archive.** Every stored item should have a
   plausible future use. If it can be cheaply re-read, store a pointer.
2. **Every claim has provenance.** If you cannot trace it, you cannot correct it.
3. **Every layer has a budget.** Bytes, tokens, items, and compute.
4. **Forgetting is first-class.** Archive, demote, and prune are normal
   operations, not failures.
5. **Maintenance is incremental, idempotent, and observable.** Track a cursor;
   do not rescan the world; make reruns safe.
6. **Synthesis must compress.** A page that is larger than its sources has
   abstracted nothing.
7. **Search grounds synthesis; synthesis improves search.** Neither replaces the
   other.
8. **The injected layer is the most expensive real estate.** Keep it small,
   cited, and layered by stability.
9. **Do not overwrite history.** Supersede with validity windows and keep the
   reasoning.
10. **Evaluate downstream.** Memory quality is task success, not store growth.

### 8.4 What success looks like

A successful redesign has these observable properties:

- A non-empty scope can run consolidation without raising, and the run record
  matches the rows actually archived.
- Every new claim has at least one evidence row, or an explicit
  `source: "user"`/`source: "agent"` marker.
- Re-running the learning pipeline produces no duplicates.
- A session starts with a brief under the configured token budget, and every
  item in it cites an entry, page, or handoff.
- Touching a file can inject a small recall block keyed by path/symbol.
- A dream run is idempotent, budget-capped, and on failure rolls back only the
  failing stage while recording completed stages for resumption.
- Every page cites at least one source and passes the compression guard.
- Hybrid retrieval beats vector-only on recall and token efficiency.
- The eval harness shows memory-on is not worse than memory-off, and reports the
  delta.

### 8.5 Open research questions

1. **Is `recollect_entries` the right L1, or should claims be a separate table?**
   Extending the existing table is incremental; a separate table is cleaner.
2. **How much raw transcript retention is acceptable?** Privacy, disk, and
   consent push toward short retention; verification pushes toward longer.
3. **Should dreaming run inside Recollect or in the host?** Recollect has no job
   queue; hosts often have Oban. A library API plus an optional worker is the
   likely split.
4. **What is the default token budget?** 1,500 tokens is a reasonable starting
   point for a coding agent, but it should be configurable per host and model.
5. **How should multi-agent scopes resolve conflicts?** Precedence plus evidence;
   "last write wins" is not acceptable.
6. **What is the migration path for entries without provenance?** Mark them
   `epistemic: :inferred`, `verification: :none`, and keep them out of the brief
   until verified.
7. **Can SQLite/libSQL support the same retrieval quality?** FTS5 + sqlite-vec
   can approximate it, but the planner and index options differ.
8. **How do we evaluate memory without a task harness?** Start with a small
   labeled set of project questions and a scripted multi-session task.

---

## 9. Conclusion

The article's deepest claim is not that agents need a bigger memory store. It is
that they need a **distillation pipeline**: capture raw experience, curate it
into claims, synthesize those claims into representations, and inject only the
small, cited slice a future session needs. The HN thread adds the operational
corollary: users will not tolerate a memory system that creates noise, loses
provenance, or cannot be reviewed.

Recollect has the right instincts — decay, consolidation, working memory,
handoff, graph edges — but the implementation currently collapses the layers and
breaks the loops that would make them useful. The audit in §6 is not a list of
polish items; it is the difference between a memory store and a memory system.

The recommended order is deliberate:

1. **Fix correctness first**, because a broken consolidation pass makes every
   later layer untrustworthy.
2. **Add provenance before synthesis**, because an untraceable summary is worse
   than no summary.
3. **Budget the injected layer before adding more memory**, because tokens are
   the real cost.
4. **Then add dreaming, pages, and hybrid retrieval**, with measurement at every
   step.

The companion implementation plan turns this into phases, tickets, schemas,
tests, and acceptance criteria.

---

## Appendix A — Source notes

| Source | What was read | Key takeaway |
|---|---|---|
| [The components of agent memory](https://www.anthropic.com/research/components-of-agent-memory) | Full article, figures, reported numbers | Memory is a prediction; four layers; dreaming corrects, synthesizes, promotes, and prunes; compression and injection budgets matter |
| [HN discussion](https://news.ycombinator.com/item?id=50402212) | Story and top-level comments | Notes are not weight learning; models are bad at salience; users delete most auto-memory; provenance, scoping, and review are missing |
| [Google Sleep framework](https://research.google/blog/the-sleep-framework-a-new-way-for-llms-to-retain-knowledge-in-continual-learning/) | Blog post | Offline consolidation should generate, validate, and consolidate; guard against forgetting |
| [Particulars](https://particulars.fyi/) | Site and dialectical format | Thesis → antithesis → synthesis preserves reasoning and unresolved questions |
| [myFleet](https://gitlab.com/doering-ai/libs/fleet) | README | Skills, charters, and policies across agent harnesses; scoping is a first-class concern |
| [Innerloop Breadcrumb](https://innerloop.works/breadcrumb) | Site/docs | Folder scopes with global + project rules; session/screen capture |
| [CL-Bench 1.0](https://continual-learning-bench.com/news/cl-bench-1-0/) | Announcement | Sequential-task evaluation for retention and interference |
| [Letta sleep-time compute](https://arxiv.org/abs/2504.13171) | Abstract | Background compute can reduce test-time cost; treat it as an investment with a budget |

## Appendix B — Evidence table

| Claim | Source | Grade | Implication for Recollect |
|---|---|---|---|
| Memory improved CL-Bench scores across six models | Article, Figure 3 | B | External memory has real task value; measure it |
| "Record only failures" reduced the memory gain | Article, Figure 5 | B | Do not hard-code salience rules; learn from outcomes |
| A small, strategy-focused memory folder outperformed a large archive | Article, Pokémon experiment | B | Prefer selective capture and pointers |
| Dreaming corrected a wrong note against the transcript | Article, Mt. Moon | B | Keep transcripts as evidence; verify against them |
| Wiki + search beat either alone | Article, Figure 10 and Harvey LAB | B | Build pages and keep search; do not replace one with the other |
| A wiki can grow larger than its corpus | Article, Figure 12 | B | Enforce a compression guard |
| Concurrent writers can erase facts | Article, Figure 14 | B | Single-flight synthesis; quote critical evidence |
| Injected context must stay small | Article, Claude Code memory docs | A (documented behavior) | Add a hard token budget |
| Models are poor at creating useful memories | HN, `ford`, `yfontana` | C (anecdotal) | Add review/prune and salience gates |
| Provenance is commonly missing | HN, `benfortuna` | C | Add evidence links |
| Users want scoping and review | HN, `russellbeattie`, `prtmnth` | C | Add memory levels and a review API |
| Consolidation crashes on a non-empty scope | Code audit | A | Fix before any new layer |
| Conflict detection never executes | Code audit | A | Fix the query and binding |
| Tags are dropped | Code audit | A | Add the column and filters |
| Retrieval counts are undercounted | Code audit | A | Use the actual ETS counts |
| Mipmap writes amplify cost | Code audit | A | Make mipmaps lazy/batched |

## Appendix C — Code reference index

| Claim | File:line |
|---|---|
| Consolidation builds string-keyed maps | `lib/recollect/consolidation.ex:120-122` |
| `struct/2` on string keys yields nil fields | `lib/recollect/consolidation.ex:143` |
| `DateTime.diff/3` with nil raises | `lib/recollect/strength.ex:26-33` |
| Decay removal is never persisted | `lib/recollect/consolidation.ex:77-94`, `:138-148` |
| Merge summaries are plain notes | `lib/recollect/consolidation.ex:277-292` |
| Union-find grouping uses raw parent | `lib/recollect/consolidation.ex:199-227` |
| O(n³) `Enum.at` in pair loops | `lib/recollect/consolidation.ex:154-174`; `lib/recollect/conflict_detection.ex:32-39` |
| Conflict detection selects `tags_json` | `lib/recollect/conflict_detection.ex:118` |
| Conflict detection passes string UUID | `lib/recollect/conflict_detection.ex:121` |
| Tags are read but not stored | `lib/recollect/knowledge.ex:41`, `:64-80` |
| Entry schema has no tags | `lib/recollect/schema/entry.ex:13-36` |
| Migration generator has no tags | `lib/recollect/migration_generator.ex:215-238` |
| Tag filter is documented but not implemented | `lib/recollect/search/vector.ex:39-43`, `:675-751` |
| Schema index selects `tags_json` | `lib/recollect/schema_index.ex:27` |
| Retrieval flush ignores counts | `lib/recollect/retrieval_counter.ex:74-105` |
| Per-category `limit` | `lib/recollect/search/vector.ex:57-62` |
| Context detection per search | `lib/recollect/search/vector.ex:766-776` |
| Context detection per write | `lib/recollect/knowledge.ex:44-50` |
| Git subprocesses | `lib/recollect/context/detector.ex:83-103` |
| Mipmap 4× embedding | `lib/recollect/mipmap/generator.ex:50-106` |
| Mipmap re-embeds query | `lib/recollect/mipmap/generator.ex:139` |
| Mipmaps persisted after every embed | `lib/recollect/pipeline/embedder.ex:116` |
| Sleep read/clear race | `lib/recollect/sleep.ex:73`, `:92-98` |
| Supersede zeroes half-life | `lib/recollect/knowledge.ex:211-216` |
| Learning ignores `since` | `lib/recollect/learning/coding_agent.ex:46-65` |
| Classification hint keys mismatch | `lib/recollect/classification.ex:93-115` |
| SchemaFit scans 500 entries | `lib/recollect/schema_fit.ex:60-92` |
| ContextFormatter has no budget | `lib/recollect/search/context_formatter.ex:6-21` |
| Handoff is unbounded JSON | `lib/recollect/handoff.ex:35-72` |
| WorkingMemory is ephemeral | `lib/recollect/working_memory.ex:25-56`; `server.ex:44-74` |
| Outcome overwrites score | `lib/recollect/outcome.ex:63-72` |
| Owner search does not reinforce | `lib/recollect/search/vector.ex:322-348` |
| Archived entries can surface via mipmaps | `lib/recollect/mipmap/generator.ex:147-181` |

## Appendix D — Glossary

| Term | Meaning in this report |
|---|---|
| **L0 / event** | Append-only raw transcript or observation; evidence, not a retrieval target |
| **L1 / claim** | Atomic knowledge note with tags, scope, evidence, and validity |
| **L2 / page** | Synthesized representation (wiki/topic page) with citations |
| **L3 / brief** | Budgeted rendered context injected into a session |
| **Dream** | Offline consolidation pipeline: verify, reconcile, synthesize, promote, prune |
| **Provenance** | The link from a claim or page back to the evidence that supports it |
| **Evidence** | A transcript event, file reference, test result, or user statement |
| **Compression guard** | A rule that rejects a page larger than a fraction of its sources |
| **RRF** | Reciprocal rank fusion; combines ranked lists from multiple retrievers |
| **Mipmap** | A stored detail level (anchor/abstract/summary/full) for an entry |
| **Brief** | The small, cited, budgeted view injected at session start |
| **Recall anchor** | A path/symbol key that retrieves a small memory block just in time |
| **Salience** | The estimated future value of capturing an item |
| **Dialectic** | Thesis → antithesis → synthesis, preserving reasoning and open questions |

## Appendix E — Canonical work items

The canonical ticket register (MEM-001 … MEM-040), estimates, dependencies, and
acceptance criteria live in
[`agent-memory-implementation-plan.md`](agent-memory-implementation-plan.md#appendix-a--canonical-ticket-register).
This report deliberately does not duplicate them.
