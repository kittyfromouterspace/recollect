[
  parallel: true,
  skipped: true,
  tools: [
    {:formatter, enabled: false},
    {:compiler, "mix compile --warnings-as-errors"},
    {:deps_unlock, "mix deps.unlock --check-unused"},
    {:test, "mix test", env: %{"MIX_ENV" => "test"}},

    {:ex_unit, false},
    {:unused_deps, false},

    {:mix_audit, "mix deps.audit"},

    {:dialyzer, false},
    {:doctor, false},
    {:gettext, false},
    {:npm_test, false}
  ]
]
