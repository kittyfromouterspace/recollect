# Upgrading Recollect

How to upgrade a host application to a new Recollect version, with the
lessons learned from upgrading `ops_center` and `agent_forge` to v1.0.

## Host procedure

1. **Bump the dependency** in `mix.exs`:

   ```elixir
   {:recollect, "~> 1.0"}
   ```

   then `mix deps.get` (or `mix deps.update recollect`).

2. **Compile and run your tests** before touching the database:

   ```bash
   mix compile && MIX_ENV=test mix test
   ```

3. **Check schema drift** (see "Two drift checks" below):

   ```bash
   mix recollect.migration_status --tables
   ```

4. **Generate the additive mirror migration** for any upstream migrations
   your host does not have yet:

   ```bash
   mix recollect.gen.upgrade --from UPSTREAM_VERSION --to UPSTREAM_VERSION
   ```

   `--from` and `--to` are **upstream Recollect migration versions** (the
   `YYYYMMDDHHMMSS` prefixes in recollect's own `priv/repo/migrations`), not
   your host's mirror versions. Use the newest upstream version your schema
   already includes as `--from`; omit `--to` to default to the latest.

   Review the generated file in `priv/repo/migrations/`, then apply:

   ```bash
   mix ecto.migrate
   ```

5. **Smoke-test the new code path** on a running node:

   ```elixir
   Recollect.search("deploy", scope_id: scope, owner_id: owner, mode: :hybrid)
   ```

   Confirm you get `{:ok, context_pack}` back, and watch for
   `[:recollect, :search, :fallback]` telemetry when embeddings are disabled
   or vector recall is poor.

6. **Roll out canary-first** (one VM, watch logs and probes, then the rest).

## Two drift checks — pick the right one

`mix recollect.migration_status` has two modes, and choosing the wrong one
produces misleading output:

| Check | What it compares | Use it for |
|---|---|---|
| default (version files) | version-stamped migration files in `priv/repo/migrations` + `schema_migrations` vs the manifest | hosts that mirror upstream migrations **verbatim** with the same timestamps |
| `--tables` | tables the manifest creates vs tables that actually exist in the database | hosts that **bundle** upstream migrations under their own timestamps; production drift gates |

**Lesson from ops_center:** its schema was bundled under host-chosen
timestamps (e.g. `20261007150000_add_missing_recollect_schema.exs`), so the
version-file check reported all 22 upstream migrations as `missing` even
though most of the schema was present. That is expected for bundled mirrors —
`--tables` is the correct check there (it reported exactly which of the new
v1.0 tables were actually absent).

## What the generated mirror migration does

`mix recollect.gen.upgrade` emits a migration that:

- `Code.require_file`s each upstream migration from the dependency's
  `priv/repo/migrations` and calls it through an `apply_upstream/1` helper
  that dispatches to **`up/0` if it exists, otherwise `change/0`**. Upstream
  Recollect migrations use both styles — calling `.up()` directly fails on
  the many migrations that only define `change/0`.
- In `down`, **requires the upstream files again** before delegating.
  Rollback runs in a fresh process, so without the requires the upstream
  modules are not loaded, `function_exported?` returns `false`, and the
  rollback would silently no-op.
- Applies in dependency order (oldest first for `up`, newest first for `down`).

Re-running is guarded by Ecto's `schema_migrations` table; upstream DDL keeps
its original semantics (no extra `IF NOT EXISTS` wrapping is added).

## Rollback

- Revert the dependency pin (`mix.exs` + `mix.lock`) and redeploy.
- New Recollect schema is **additive** (new tables/columns), so no
  down-migration is needed to roll back application code. The generated
  mirror migration's `down` is available if you do want to drop the new
  tables.
- Runtime kill-switches for new retrieval behavior:
  `config :recollect, retrieval: [keyword_fallback: false]` and
  `config :recollect, retrieval: [rerank: false]`.

## Gotchas hit during the v1.0 upgrade

- **Postgrex parameter types:** new search SQL uses binary UUIDs
  (`Recollect.Util.uuid_to_bin/1`) for `uuid` columns and interpolates
  `LIMIT` as a literal integer — parameterized `LIMIT $n` fails with
  "could not determine data type of parameter".
- **String-keyed rows:** results from `Recollect.Util.row_to_map/2` use
  string keys. Anything that consumes them with atom keys (e.g. `item.id`,
  `Map.get(item, :id)`) silently fails — use `item["id"] || item[:id]`.
- **`mix recollect.migration_status` starts the app** (`Mix.Task.run("app.start")`)
  so the host Repo is running; expect your app's normal startup logs before
  the report.
- **Smoke expectation with an empty scope:** `Recollect.search(...,
  mode: :hybrid)` returns `items: []` and `resolved_mode: :both` when
  embeddings are enabled but the scope has no entries — the keyword fallback
  ran alongside vector search and found nothing, which is correct behavior,
  not an error.
