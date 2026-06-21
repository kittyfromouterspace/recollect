defmodule Recollect.Context.DetectorGitAbsentTest do
  @moduledoc """
  Regression: `git` may be absent (minimal prod VM). detect/0 ran `System.cmd("git", …)`
  which raises :enoent when the binary is missing — crashing remember/search.
  """
  use ExUnit.Case, async: false

  alias Recollect.Context.Detector

  setup do
    original = System.get_env("PATH")
    on_exit(fn -> if original, do: System.put_env("PATH", original) end)
    :ok
  end

  test "detect/0 degrades gracefully when git is not on PATH (no crash, no git keys)" do
    # Empty PATH → System.find_executable("git") returns nil → no git context.
    System.put_env("PATH", "")

    context = Detector.detect()

    assert is_map(context)
    # OS detection doesn't shell out, so it still works.
    assert Map.has_key?(context, :os)
    # No git context, and crucially no raise.
    refute Map.has_key?(context, :repo)
  end
end
