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

  They are `ArchTest.Effects.no_queries_in_loops/2`, `no_work_in_init/2` and `no_io_in_transactions/2`,
  `ArchTest.Processes`' `processes_have_one_interface/2`, `processes_are_supervised/2` and `no_unbounded_waits/2`,
  `ArchTest.API`'s `no_flag_arguments/2`, `no_stringly_typed_choices/2` and `no_alternative_return_types/2`,
  `ArchTest.Data`'s `no_mass_assignment/2`, `no_lost_updates/2` and `no_float_money/2`, all of `ArchTest.TestCode`,
  and all of `ArchTest.Guardrails`. `ArchTest.Effects.should_be_free_of_side_effects/2`,
  `ArchTest.Effects.writes_are_authorized/2`, `ArchTest.Effects.reads_are_authorized/2`,
  `ArchTest.Processes.processes_hold_state/2`, `ArchTest.API.typed_identifiers/2` and
  `ArchTest.Data.no_unbounded_queries/2` aren't: which modules are a functional core, which endpoints and records are
  public and what checks permissions, which processes may only organize code, where swapped ids cost most, and which
  tables stay small, are each project's call.

  `no_mass_assignment/2` takes `policy:`, as the other options go to every rule: an admin's endpoint that a policy
  checks may set roles.

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

  alias ArchTest.{API, Assertions, Data, Effects, Guardrails, ModuleSet, Processes, TestCode}
  alias ArchTest.Code.Rules

  @rules [
    no_queries_in_loops: &Effects.no_queries_in_loops/2,
    no_work_in_init: &Effects.no_work_in_init/2,
    no_io_in_transactions: &Effects.no_io_in_transactions/2,
    processes_have_one_interface: &Processes.processes_have_one_interface/2,
    processes_are_supervised: &Processes.processes_are_supervised/2,
    no_unbounded_waits: &Processes.no_unbounded_waits/2,
    no_flag_arguments: &API.no_flag_arguments/2,
    no_stringly_typed_choices: &API.no_stringly_typed_choices/2,
    no_alternative_return_types: &API.no_alternative_return_types/2,
    no_mass_assignment: &Data.no_mass_assignment/2,
    no_lost_updates: &Data.no_lost_updates/2,
    no_float_money: &Data.no_float_money/2,
    tests_use_their_subject: &TestCode.tests_use_their_subject/2,
    tests_dont_mock_pure_modules: &TestCode.tests_dont_mock_pure_modules/2,
    tests_dont_sleep: &TestCode.tests_dont_sleep/2,
    async_tests_share_no_state: &TestCode.async_tests_share_no_state/2,
    no_suppressions: &Guardrails.no_suppressions/2,
    no_stubs: &Guardrails.no_stubs/2,
    no_functions_only_tests_call: &Guardrails.no_functions_only_tests_call/2,
    no_swallowed_errors: &Guardrails.no_swallowed_errors/2
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
