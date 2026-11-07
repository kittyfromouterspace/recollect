defmodule Recollect.GuardsTest do
  use Recollect.DataCase, async: false

  alias Recollect.Guards

  @sample_key "sk-proj-abcdef1234567890abcdef123456"

  describe "possible_secret?/1" do
    test "flags provider-style secret keys" do
      assert Guards.possible_secret?("the key is #{@sample_key} rotate it")
    end

    test "flags PEM private key blocks" do
      assert Guards.possible_secret?("-----BEGIN RSA PRIVATE KEY-----\nMIIE...")
    end

    test "flags credential-style assignments" do
      assert Guards.possible_secret?("api_key: hunter2secret")
      assert Guards.possible_secret?("password=hunter2secret")
    end

    test "flags bearer headers" do
      assert Guards.possible_secret?("Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6")
    end

    test "does not flag ordinary operational knowledge" do
      refute Guards.possible_secret?("Billing retries use exponential backoff capped at 60 seconds.")
      refute Guards.possible_secret?("Deploy scripts live in /app/scripts; run mix check before pushing.")
      refute Guards.possible_secret?("The bug was in the backoff token bucket — refill rate was off by one.")
    end
  end

  describe "remember/2 integration" do
    setup do
      original = Application.get_env(:recollect, :guards)

      on_exit(fn ->
        if original == nil do
          Application.delete_env(:recollect, :guards)
        else
          Application.put_env(:recollect, :guards, original)
        end
      end)

      :ok
    end

    test "a credential-shaped string is rejected with {:error, :possible_secret}" do
      result =
        Recollect.remember("Found the leaked key: #{@sample_key} — do not commit",
          owner_id: Fixtures.owner_id(),
          scope_id: Fixtures.scope_id()
        )

      assert {:error, :possible_secret} = result
    end

    test "allow_secrets: true overrides the guard" do
      result =
        Recollect.remember("Found the leaked key: #{@sample_key} — do not commit",
          owner_id: Fixtures.owner_id(),
          scope_id: Fixtures.scope_id(),
          allow_secrets: true
        )

      assert {:ok, _entry} = result
    end

    test "a credential in string metadata is rejected" do
      result =
        Recollect.remember("Rotation note for the incident",
          owner_id: Fixtures.owner_id(),
          scope_id: Fixtures.scope_id(),
          metadata: %{"secret" => @sample_key}
        )

      assert {:error, :possible_secret} = result
    end

    test "guards enabled: false disables the check" do
      Application.put_env(:recollect, :guards, enabled: false)

      result =
        Recollect.remember("Found the leaked key: #{@sample_key} — do not commit",
          owner_id: Fixtures.owner_id(),
          scope_id: Fixtures.scope_id()
        )

      assert {:ok, _entry} = result
    end

    test "custom extra_patterns are honored" do
      Application.put_env(:recollect, :guards, extra_patterns: [~r/INTERNALPASS/])

      assert {:error, :possible_secret} =
               Recollect.remember("signing with INTERNALPASS-42 for the job",
                 owner_id: Fixtures.owner_id(),
                 scope_id: Fixtures.scope_id()
               )
    end
  end
end
