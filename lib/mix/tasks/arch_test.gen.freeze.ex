defmodule Mix.Tasks.ArchTest.Gen.Freeze do
  use Igniter.Mix.Task

  @shortdoc "Generate a freeze baseline test for gradual adoption"

  @moduledoc """
  Generates a freeze baseline architecture test file.

  ## Usage

      mix arch_test.gen.freeze

  Creates `test/arch/freeze_arch_test.exs`. Run with
  `ARCH_TEST_UPDATE_FREEZE=true mix test` to establish the baseline, then
  commit the generated `test/arch_test_violations/` files. Only new violations
  introduced after the baseline will cause failures.
  """

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    app = Igniter.Project.Application.app_name(igniter)
    ns = Macro.camelize(to_string(app))
    module = Module.concat([ns, "Freeze", "ArchTest"])
    path = "test/arch/freeze_arch_test.exs"

    Igniter.create_new_file(igniter, path, """
    defmodule #{inspect(module)} do
      use ExUnit.Case
      use ArchTest

      # Run: ARCH_TEST_UPDATE_FREEZE=true mix test to establish the baseline.
      # Commit test/arch_test_violations/ to version control.
      test "no new dependency violations (frozen)" do
        ArchTest.Freeze.freeze("all_deps", fn ->
          all_modules()
          |> should_be_free_of_cycles()
        end)
      end
    end
    """)
  end
end
