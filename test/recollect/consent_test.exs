defmodule Recollect.ConsentTest do
  use ExUnit.Case, async: false

  alias Recollect.Learner.Consent

  defmodule GrantedProvider do
    @moduledoc false
    def agent_name, do: :codex
  end

  defmodule UnaskedProvider do
    @moduledoc false
    def agent_name, do: :gemini
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "consent-test-#{System.unique_integer([:positive])}")
    previous = System.get_env("RECOLLECT_HOME")
    System.put_env("RECOLLECT_HOME", tmp)

    on_exit(fn ->
      if previous,
        do: System.put_env("RECOLLECT_HOME", previous),
        else: System.delete_env("RECOLLECT_HOME")

      File.rm_rf!(tmp)
    end)

    :ok
  end

  test "agents are unasked by default" do
    assert Consent.check(:codex) == :unasked
    refute Consent.granted?(:codex)
  end

  test "grant/deny roundtrip persists" do
    assert :ok = Consent.grant(:codex)
    assert Consent.check(:codex) == :granted
    assert Consent.granted?(:codex)

    assert :ok = Consent.deny(:codex)
    assert Consent.check(:codex) == :denied
    refute Consent.granted?(:codex)
  end

  test "statuses cover every registered provider" do
    statuses = Consent.statuses()
    assert is_list(statuses)
    assert Enum.any?(statuses, &(&1.agent == :codex))
    assert Enum.all?(statuses, &(&1.status in [:granted, :denied, :unasked]))
  end

  test "filter/0 allows only granted providers" do
    Consent.grant(:codex)

    assert Consent.filter().(GrantedProvider)
    refute Consent.filter().(UnaskedProvider)
  end

  test "filter/1 ANDs an extra provider predicate" do
    Consent.grant(:codex)

    refute Consent.filter(fn _provider -> false end).(GrantedProvider)
    assert Consent.filter(fn provider -> provider.agent_name() == :codex end).(GrantedProvider)
  end
end
