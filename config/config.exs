import Config

config :logger, level: :warning

config :recollect, Recollect.TestRepo,
  database: "recollect_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool_size: 10,
  pool: Ecto.Adapters.SQL.Sandbox,
  migration_repo: Recollect.TestRepo,
  priv: "priv/repo",
  types: Recollect.PostgrexTypes

config :recollect, ecto_repos: [Recollect.TestRepo]

# The library's own test/dev runs never scan the developer's real coding-agent
# transcripts: the learning pipeline's default sources are pinned to Git (the
# checkout itself is the fixture). CodingAgent is exercised directly in
# coding_agent_test.exs. Library config does not propagate to host apps.
config :recollect,
  learning: [sources: [Recollect.Learner.Git]]

config :recollect,
  repo: Recollect.TestRepo,
  embedding: [provider: Recollect.Embedding.Mock, mock: true],
  table_prefix: "recollect_test_"
