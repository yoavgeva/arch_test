defmodule Mix.Tasks.ArchTest.Gen.Onion do
  use Igniter.Mix.Task

  @shortdoc "Generate an onion/hexagonal architecture test"

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    app = Igniter.Project.Application.app_name(igniter)
    ns = Macro.camelize(to_string(app))
    module = Module.concat([ns, "Onion", "ArchTest"])
    path = "test/arch/onion_arch_test.exs"

    Igniter.create_new_file(igniter, path, """
    defmodule #{inspect(module)} do
      use ExUnit.Case
      use ArchTest

      test "dependencies point inward only" do
        define_onion(
          domain:      "#{ns}.Domain.**",
          application: "#{ns}.Application.**",
          adapters:    "#{ns}.Adapters.**",
          web:         "#{ns}.Web.**"
        )
        |> enforce_onion_rules()
      end
    end
    """)
  end
end
