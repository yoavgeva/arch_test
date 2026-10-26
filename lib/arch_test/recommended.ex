defmodule ArchTest.Recommended do
  @moduledoc """
  The design rules worth holding any Elixir project to, run as one test that reports what each finds.

      defmodule MyApp.DesignTest do
        use ExUnit.Case
        use ArchTest, app: :my_app

        test "recommended design rules" do
          ArchTest.Recommended.check(modules_matching("MyApp.**"), app: :my_app)
        end
      end

  They are `ArchTest.Effects.no_queries_in_loops/2` and `no_work_in_init/2`, `ArchTest.Processes`'
  `processes_have_one_interface/2` and `processes_are_supervised/2`, all of `ArchTest.TestCode`, and all of
  `ArchTest.Guardrails`. `ArchTest.Effects.should_be_free_of_side_effects/2` and
  `ArchTest.Processes.processes_hold_state/2` aren't: which modules are a functional core, and which processes may
  only organize code, is each project's call.

  On code that already breaks them, freeze what's there and fail only on new violations:

      test "recommended design rules" do
        ArchTest.Freeze.freeze("recommended_design_rules", fn ->
          ArchTest.Recommended.check(modules_matching("MyApp.**"), app: :my_app)
        end)
      end

  ## Options

  - `:except` — rules to leave out, such as `[:tests_dont_sleep]`

  The other options go to every rule: `:app`, `:paths`, `:test_paths` and the like.
  """

  alias ArchTest.{Assertions, Effects, Guardrails, ModuleSet, Processes, TestCode}
  alias ArchTest.Code.Rules

  @rules [
    no_queries_in_loops: &Effects.no_queries_in_loops/2,
    no_work_in_init: &Effects.no_work_in_init/2,
    processes_have_one_interface: &Processes.processes_have_one_interface/2,
    processes_are_supervised: &Processes.processes_are_supervised/2,
    tests_use_their_subject: &TestCode.tests_use_their_subject/2,
    tests_dont_mock_pure_modules: &TestCode.tests_dont_mock_pure_modules/2,
    tests_dont_sleep: &TestCode.tests_dont_sleep/2,
    async_tests_share_no_state: &TestCode.async_tests_share_no_state/2,
    no_suppressions: &Guardrails.no_suppressions/2,
    no_stubs: &Guardrails.no_stubs/2,
    no_functions_only_tests_call: &Guardrails.no_functions_only_tests_call/2
  ]

  @doc """
  The recommended rules' names, in the order they run.
  """
  @spec rules() :: [atom()]
  def rules, do: Keyword.keys(@rules)

  @doc """
  Runs every recommended rule on `subject`, and fails with all their violations, each marked with its rule.
  """
  @spec check(ModuleSet.t(), keyword()) :: :ok
  def check(%ModuleSet{} = subject, opts \\ []) do
    {except, opts} = Keyword.pop(opts, :except, [])

    violations =
      for {name, rule} <- @rules,
          name not in except,
          violation <- Assertions.capture_violations(fn -> rule.(subject, opts) end),
          do: violation

    Rules.report(violations, "recommended design rules")
  end
end
