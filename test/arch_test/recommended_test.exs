defmodule ArchTest.RecommendedTest do
  use ExUnit.Case, async: false

  alias ArchTest.{Assertions, CompiledFixture, ModuleSet, Recommended}

  @root Path.join(System.tmp_dir!(), "arch_test_recommended_fixtures")

  setup_all do
    File.rm_rf!(@root)

    sources = [
      {"lib/recommended_fixture/orders.ex",
       """
       defmodule RecommendedFixture.Orders do
         def totals(ids), do: Enum.map(ids, fn id -> :httpc.request(id) end)

         def refund(_order), do: raise("not implemented")
       end
       """}
    ]

    for {file, source} <- sources do
      File.mkdir_p!(Path.join(@root, Path.dirname(file)))
      File.write!(Path.join(@root, file), source)
    end

    CompiledFixture.compile(Path.join(@root, "ebin"), sources)
    File.mkdir_p!(Path.join(@root, "test"))

    File.write!(Path.join(@root, "test/orders_test.exs"), """
    defmodule RecommendedFixture.OrdersTest do
      use ExUnit.Case, async: true

      test "totals" do
        Process.sleep(10)
        assert RecommendedFixture.Orders.totals([]) == []
      end
    end
    """)

    :ok
  end

  test "runs every recommended rule, and reports what each finds in one assertion" do
    rules = Enum.map(check(), &{&1.rule, &1.line})

    assert rules == [
             {"no_queries_in_loops", 2},
             {"no_unbounded_waits", 2},
             {"no_stubs", 4},
             {"tests_dont_sleep", 5}
           ]
  end

  test "leaves out the rules a project names" do
    assert Enum.map(check(except: [:no_stubs, :tests_dont_sleep, :no_unbounded_waits]), & &1.rule) ==
             [
               "no_queries_in_loops"
             ]
  end

  test "lists its rules, leaving out the ones that need a project's own judgement" do
    assert Recommended.rules() == [
             :no_queries_in_loops,
             :no_work_in_init,
             :no_io_in_transactions,
             :processes_have_one_interface,
             :processes_are_supervised,
             :no_unbounded_waits,
             :no_flag_arguments,
             :no_stringly_typed_choices,
             :no_alternative_return_types,
             :tests_use_their_subject,
             :tests_dont_mock_pure_modules,
             :tests_dont_sleep,
             :async_tests_share_no_state,
             :no_suppressions,
             :no_stubs,
             :no_functions_only_tests_call,
             :no_swallowed_errors
           ]
  end

  defp check(opts \\ []) do
    subject = ModuleSet.new("RecommendedFixture.**")
    opts = Keyword.merge([paths: [Path.join(@root, "ebin")], test_paths: ["test"]], opts)

    File.cd!(@root, fn ->
      Assertions.capture_violations(fn -> Recommended.check(subject, opts) end)
    end)
  end
end
