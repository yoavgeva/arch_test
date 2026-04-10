if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.ArchTest.Gen.Modulith do
    use Igniter.Mix.Task

    @shortdoc "Generate a modulith bounded-context isolation test"

    @moduledoc """
    Generates a modulith architecture test file.

    ## Usage

        mix arch_test.gen.modulith

    Creates `test/arch/modulith_arch_test.exs` with slice isolation and
    cycle-detection tests. Edit the generated slices to match your contexts.
    """

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app = Igniter.Project.Application.app_name(igniter)
      ns = Macro.camelize(to_string(app))
      module = Module.concat([ns, "Modulith", "ArchTest"])
      path = "test/arch/modulith_arch_test.exs"

      Igniter.create_new_file(igniter, path, """
      defmodule #{inspect(module)} do
        use ExUnit.Case
        use ArchTest

        # TODO: replace with your actual slices
        test "bounded contexts are isolated" do
          define_slices(
            orders:    "#{ns}.Orders",
            accounts:  "#{ns}.Accounts"
          )
          |> allow_dependency(:orders, :accounts)
          |> enforce_isolation()
        end

        test "no circular slice dependencies" do
          define_slices(
            orders:    "#{ns}.Orders",
            accounts:  "#{ns}.Accounts"
          )
          |> should_be_free_of_cycles()
        end
      end
      """)
    end
  end
end
