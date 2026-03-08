defmodule Mix.Tasks.ArchTest.Install do
  use Igniter.Mix.Task

  @shortdoc "Set up ArchTest with a basic architecture test file"

  @moduledoc """
  Generates a basic architecture test file with a cycle-freedom check.

  ## Usage

      mix arch_test.install

  Creates `test/<app>_arch_test.exs` with `use ArchTest` and a single
  `should_be_free_of_cycles/1` test as a starting point.
  """

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    app = Igniter.Project.Application.app_name(igniter)
    module = Module.concat([Macro.camelize(to_string(app)), "ArchTest"])
    path = "test/#{app}_arch_test.exs"

    Igniter.create_new_file(igniter, path, """
    defmodule #{inspect(module)} do
      use ExUnit.Case
      use ArchTest

      test "no circular dependencies" do
        all_modules() |> should_be_free_of_cycles()
      end
    end
    """)
  end
end
