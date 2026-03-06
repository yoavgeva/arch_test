defmodule ArchTest.Freeze do
  @moduledoc """
  Violation baseline ("freeze") support for gradual architectural adoption.

  When a rule has existing violations that cannot be fixed immediately,
  use `freeze/2` to record the current set of violations as a baseline.
  Future test runs only fail on *new* violations not in the baseline.

  ## Usage

      test "legacy dependencies being cleaned up" do
        modules_matching("MyApp.**")
        |> should_not_depend_on(modules_matching("MyApp.Legacy.**"))
        |> freeze("legacy_deps")
      end

  ## Baseline files

  Baselines are stored as text files (one violation key per line) in
  the directory configured by:

      config :arch_test, freeze_store: "test/arch_test_violations"

  The default store path is `test/arch_test_violations/`.

  Commit these files to version control. To "unfreeze" and require all
  violations to be fixed, delete the corresponding file.

  ## Updating the baseline

  Run with `ARCH_TEST_UPDATE_FREEZE=true` to overwrite baselines with the
  current violation set:

      ARCH_TEST_UPDATE_FREEZE=true mix test
  """

  @default_store "test/arch_test_violations"

  @doc """
  Runs `assertion_fn` and freezes violations against a stored baseline.

  `rule_id` is used to name the baseline file (should be unique per rule).

  Only violations **not** in the baseline cause test failure.
  If `ARCH_TEST_UPDATE_FREEZE=true`, the baseline is updated to the current
  violation set.
  """
  @spec freeze(String.t(), (-> :ok)) :: :ok
  def freeze(rule_id, assertion_fn) when is_function(assertion_fn, 0) do
    violations = collect_violations(assertion_fn)
    store_path = store_path()
    baseline_file = Path.join(store_path, "#{rule_id}.txt")

    if update_freeze?() do
      write_baseline(baseline_file, violations)
      :ok
    else
      baseline = read_baseline(baseline_file)
      new_violations = violations -- baseline

      if new_violations == [] do
        :ok
      else
        count = length(new_violations)
        formatted = format_new_violations(new_violations)

        raise ExUnit.AssertionError,
          message:
            "Architecture rule '#{rule_id}' has #{count} NEW violation(s) " <>
              "(not in baseline #{baseline_file}):#{formatted}\n\n" <>
              "To update the baseline: ARCH_TEST_UPDATE_FREEZE=true mix test"
      end
    end
  end

  @doc """
  Returns the path to the freeze store directory.
  """
  @spec store_path() :: String.t()
  def store_path do
    Application.get_env(:arch_test, :freeze_store, @default_store)
  end

  @doc """
  Returns `true` if the `ARCH_TEST_UPDATE_FREEZE` environment variable is set.
  """
  @spec update_freeze?() :: boolean()
  def update_freeze? do
    System.get_env("ARCH_TEST_UPDATE_FREEZE") in ["1", "true", "yes"]
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  # Runs the assertion function and captures violations instead of raising.
  defp collect_violations(assertion_fn) do
    try do
      assertion_fn.()
      []
    rescue
      e in ExUnit.AssertionError ->
        extract_violation_keys(e.message)
    end
  end

  # Extracts sortable violation keys from an AssertionError message.
  # Each non-empty, non-header line is used as a key so that all violation
  # types (dependency, existence, naming, cycle, custom) are captured.
  defp extract_violation_keys(message) do
    # The message format is:
    #   "Architecture rule violated — N violations:\n\n    <line1>\n\n    <line2>..."
    # We skip the header line and blank lines, then use trimmed content lines.
    message
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn line ->
      line == "" or
        String.starts_with?(line, "Architecture rule") or
        String.starts_with?(line, "To update") or
        String.starts_with?(line, "has") or
        String.starts_with?(line, "(not in baseline")
    end)
    |> Enum.sort()
  end

  defp read_baseline(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.sort()

      {:error, :enoent} ->
        []
    end
  end

  defp write_baseline(path, violations) do
    File.mkdir_p!(Path.dirname(path))
    content = violations |> Enum.sort() |> Enum.join("\n")
    File.write!(path, content)
  end

  defp format_new_violations(violation_keys) do
    lines =
      violation_keys
      |> Enum.map(fn v -> "    " <> v end)
      |> Enum.join("\n")

    "\n\n#{lines}\n"
  end
end
