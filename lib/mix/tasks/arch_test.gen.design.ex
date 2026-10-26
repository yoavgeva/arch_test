if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.ArchTest.Gen.Design do
    use Igniter.Mix.Task

    @shortdoc "Generate the recommended design rules (N+1 queries, processes, tests, guardrails)"

    @moduledoc """
    Generates a test running `ArchTest.Recommended`, the design rules worth holding any project to.

    ## Usage

        mix arch_test.gen.design

    Creates `test/arch/design_arch_test.exs`. The rules run inside `ArchTest.Freeze.freeze/2`, so the first run
    records the violations the code already has, and later runs fail only on new ones.
    """

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app = Igniter.Project.Application.app_name(igniter)
      ns = Macro.camelize(to_string(app))
      module = Module.concat([ns, "Design", "ArchTest"])
      path = "test/arch/design_arch_test.exs"

      Igniter.create_new_file(igniter, path, """
      defmodule #{inspect(module)} do
        use ExUnit.Case
        use ArchTest, app: #{inspect(app)}

        # N+1 queries, GenServer init, process interfaces and supervision, mass assignment, lost updates, float money,
        # tests, and guardrails against
        # silenced warnings, stubs and code made public for tests. See ArchTest.Recommended.
        test "recommended design rules" do
          ArchTest.Freeze.freeze("recommended_design_rules", fn ->
            ArchTest.Recommended.check(modules_matching("#{ns}.**"), app: #{inspect(app)})
          end)
        end
      end
      """)
    end
  end
end
