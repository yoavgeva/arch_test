defmodule Mix.Tasks.ArchTest.Gen.Layers do
  use Igniter.Mix.Task

  @shortdoc "Generate a layered architecture test (web → context → repo)"

  @moduledoc """
  Generates a classic layered architecture test file.

  ## Usage

      mix arch_test.gen.layers

  Creates `test/arch/layers_arch_test.exs` enforcing that web may only depend
  on context, and context may only depend on repo — never upward.
  """

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    app = Igniter.Project.Application.app_name(igniter)
    ns = Macro.camelize(to_string(app))
    module = Module.concat([ns, "Layers", "ArchTest"])
    path = "test/arch/layers_arch_test.exs"

    Igniter.create_new_file(igniter, path, """
    defmodule #{inspect(module)} do
      use ExUnit.Case
      use ArchTest

      test "layers only depend downward" do
        define_layers(
          web:     "#{ns}.Web.**",
          context: "#{ns}.**",
          repo:    "#{ns}.Repo.**"
        )
        |> enforce_direction()
      end
    end
    """)
  end
end
