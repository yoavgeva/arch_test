defmodule Mix.Tasks.ArchTest.Gen.Naming do
  use Igniter.Mix.Task

  @shortdoc "Generate naming convention rules"

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    app = Igniter.Project.Application.app_name(igniter)
    ns = Macro.camelize(to_string(app))
    module = Module.concat([ns, "Naming", "ArchTest"])
    path = "test/arch/naming_arch_test.exs"

    Igniter.create_new_file(igniter, path, """
    defmodule #{inspect(module)} do
      use ExUnit.Case
      use ArchTest

      test "no Manager modules" do
        modules_matching("#{ns}.**.*Manager") |> should_not_exist()
      end

      test "no God modules" do
        modules_matching("#{ns}.**.*God") |> should_not_exist()
      end

      test "Ecto schemas reside under a Schemas namespace" do
        modules_satisfying(fn m -> function_exported?(m, :__schema__, 1) end)
        |> should_reside_under("#{ns}.**.Schemas")
      end
    end
    """)
  end
end
