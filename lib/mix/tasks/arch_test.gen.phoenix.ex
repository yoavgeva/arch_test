if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.ArchTest.Gen.Phoenix do
    use Igniter.Mix.Task

    @shortdoc "Generate an opinionated Phoenix architecture test (layers + conventions)"

    @moduledoc """
    Generates an opinionated Phoenix architecture test file.

    ## Usage

        mix arch_test.gen.phoenix

    Creates `test/arch/phoenix_arch_test.exs` combining layer direction
    (web → context → repo), context isolation from the web layer, cycle
    detection, naming rules, and code convention checks.
    """

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app = Igniter.Project.Application.app_name(igniter)
      ns = Macro.camelize(to_string(app))
      module = Module.concat([ns, "Phoenix", "ArchTest"])
      path = "test/arch/phoenix_arch_test.exs"

      Igniter.create_new_file(igniter, path, """
      defmodule #{inspect(module)} do
        use ExUnit.Case
        use ArchTest
        use ArchTest.Conventions

        # Layer direction: Web may only depend on Contexts; Contexts may not call Web
        test "web layer does not leak into contexts" do
          define_layers(
            web:     "#{ns}Web.**",
            context: "#{ns}.**",
            repo:    "#{ns}.Repo"
          )
          |> enforce_direction()
        end

        # Contexts must not import Plug or Phoenix modules
        test "contexts don't depend on the web layer" do
          modules_matching("#{ns}.**")
          |> excluding("#{ns}Web.**")
          |> should_not_depend_on(modules_matching("#{ns}Web.**"))
        end

        test "no circular dependencies" do
          all_modules() |> should_be_free_of_cycles()
        end

        # Naming
        test "no Manager modules" do
          modules_matching("#{ns}.**.*Manager") |> should_not_exist()
        end

        # Code conventions
        test "no IO.puts in production code" do
          no_io_puts_in(modules_matching("#{ns}.**"))
        end

        test "no dbg calls left in" do
          no_dbg_in(modules_matching("#{ns}.**"))
        end
      end
      """)
    end
  end
end
