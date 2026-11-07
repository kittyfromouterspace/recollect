defmodule Recollect.StrengthTest do
  use ExUnit.Case, async: true

  alias Recollect.Strength

  describe "calculate/2 with hostile inputs" do
    test "returns a float in [0, 1] when every timestamp is nil" do
      entry = %{
        pinned: false,
        last_accessed_at: nil,
        inserted_at: nil,
        half_life_days: nil,
        access_count: nil,
        confidence: nil,
        emotional_valence: nil
      }

      strength = Strength.calculate(entry)
      assert is_float(strength)
      assert strength >= 0.0 and strength <= 1.0
    end

    test "does not raise on half_life_days: 0.0" do
      entry = %{
        pinned: false,
        last_accessed_at: DateTime.add(DateTime.utc_now(), -1, :day),
        inserted_at: DateTime.utc_now(),
        half_life_days: 0.0,
        access_count: 1,
        confidence: 0.8,
        emotional_valence: "neutral"
      }

      strength = Strength.calculate(entry)
      assert is_float(strength)
    end

    test "does not raise on a negative half_life_days" do
      entry = %{
        pinned: false,
        last_accessed_at: DateTime.add(DateTime.utc_now(), -1, :day),
        inserted_at: DateTime.utc_now(),
        half_life_days: -3.0,
        access_count: 0,
        confidence: 1.0,
        emotional_valence: "neutral"
      }

      assert Strength.calculate(entry) in [0.0, 1.0] or is_float(Strength.calculate(entry))
    end

    test "does not raise on a future last_accessed_at (negative age)" do
      entry = %{
        pinned: false,
        last_accessed_at: DateTime.add(DateTime.utc_now(), 5, :day),
        inserted_at: nil,
        half_life_days: 7.0,
        access_count: 0,
        confidence: 1.0,
        emotional_valence: "neutral"
      }

      strength = Strength.calculate(entry)
      assert strength <= 1.0
    end

    test "pinned entries always return 1.0" do
      assert Strength.calculate(%{pinned: true}) == 1.0
    end

    test "a fresh entry with defaults stays near 1.0" do
      now = DateTime.utc_now()

      entry = %{
        pinned: false,
        last_accessed_at: now,
        inserted_at: now,
        half_life_days: 7.0,
        access_count: 1,
        confidence: 1.0,
        emotional_valence: "neutral"
      }

      assert Strength.calculate(entry, now) > 0.99
    end

    test "an old entry with a short half-life decays below 0.05" do
      now = DateTime.utc_now()

      entry = %{
        pinned: false,
        last_accessed_at: DateTime.add(now, -400, :day),
        inserted_at: nil,
        half_life_days: 7.0,
        access_count: 0,
        confidence: 1.0,
        emotional_valence: "neutral"
      }

      assert Strength.calculate(entry, now) < 0.05
    end
  end
end
