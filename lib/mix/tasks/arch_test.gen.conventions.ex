defmodule Mix.Tasks.ArchTest.Gen.Conventions do
  use Igniter.Mix.Task

  @shortdoc "Generate code convention checks (no IO.puts, dbg, bare raise, etc.)"

  @moduledoc """
  Generates a code conventions architecture test file.

  ## Usage

      mix arch_test.gen.conventions

  Creates `test/arch/conventions_arch_test.exs` checking that production
  modules contain no `IO.puts`, `dbg`, or bare `raise` string calls.
  """

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    app = Igniter.Project.Application.app_name(igniter)
    ns = Macro.camelize(to_string(app))
    module = Module.concat([ns, "Conventions", "ArchTest"])
    path = "test/arch/conventions_arch_test.exs"

    Igniter.create_new_file(igniter, path, """
    defmodule #{inspect(module)} do
      use ExUnit.Case
      use ArchTest
      use ArchTest.Conventions

      test "no IO.puts in production code" do
        no_io_puts_in(modules_matching("#{ns}.**"))
      end

      test "no dbg calls left in" do
        no_dbg_in(modules_matching("#{ns}.**"))
      end

      test "no bare raise strings" do
        no_raise_string_in(modules_matching("#{ns}.**"))
      end
    end
    """)
  end
end
