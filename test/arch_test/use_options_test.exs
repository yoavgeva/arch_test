defmodule ArchTest.UseOptionsTest do
  use ExUnit.Case, async: false

  alias ArchTest.{Assertions, Freeze, ModuleSet}

  defmodule FixtureScopedCase do
    use ArchTest, app: :fixture_app

    def rule_uses_configured_app do
      modules_matching("ArchTest.**") |> should_not_exist()
    end

    def layer_with_explicit_opts do
      define_layers([web: "FixtureApp.Web.**"], app: :arch_test)
    end

    def module_count_with_constraint_app_override do
      modules_matching("ArchTest.**")
      |> should_have_module_count(more_than: 0, app: :arch_test)
    end
  end

  defmodule AutoFreezeCase do
    use ArchTest, freeze: true

    def failing_rule(graph, rule_id) do
      modules_matching("A")
      |> should_not_depend_on(modules_matching("B"), graph: graph, rule_id: rule_id)
    end

    def attribute_value_rule(graph, value) do
      modules_matching("A")
      |> should_have_attribute_value(:example, value, graph: graph)
    end

    def satisfying_rule(graph, check_fn) do
      modules_matching("A")
      |> satisfying(check_fn, graph: graph)
    end

    def count_rule(graph) do
      modules_matching("A")
      |> should_have_module_count(exactly: 0, graph: graph)
    end

    def scoped_rule(graph, app) do
      modules_matching("A")
      |> should_not_depend_on(modules_matching("B"), graph: graph, app: app)
    end
  end

  @tmp_dir System.tmp_dir!() |> Path.join("arch_test_use_options_#{System.unique_integer()}")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    Application.put_env(:arch_test, :freeze_store, @tmp_dir)
    System.delete_env("ARCH_TEST_UPDATE_FREEZE")

    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
      Application.delete_env(:arch_test, :freeze_store)
      System.delete_env("ARCH_TEST_UPDATE_FREEZE")
    end)

    :ok
  end

  test "public API exports option-aware assertion wrappers" do
    assert function_exported?(ArchTest, :should_not_depend_on, 3)
    assert function_exported?(ArchTest, :should_only_depend_on, 3)
    assert function_exported?(ArchTest, :should_be_free_of_cycles, 2)
    assert function_exported?(ArchTest, :enforce_direction, 2)
  end

  test "use ArchTest, app: scopes assertions without manual arch_test_opts" do
    assert FixtureScopedCase.rule_uses_configured_app() == :ok
  end

  test "should_have_module_count honors app override passed with constraints" do
    assert FixtureScopedCase.module_count_with_constraint_app_override() == :ok
  end

  test "use ArchTest exposes arity-2 architecture helpers" do
    layers = FixtureScopedCase.layer_with_explicit_opts()

    assert %ArchTest.Layers{} = layers
    assert layers.app == :arch_test
  end

  test "empty subject fails by default and can be explicitly allowed" do
    subject = ModuleSet.new("NoMatch.**")
    object = ModuleSet.new("A")

    assert_raise ExUnit.AssertionError, ~r/subject resolved to 0 modules/, fn ->
      Assertions.should_not_depend_on(subject, object, graph: %{})
    end

    assert Assertions.should_not_depend_on(subject, object, graph: %{}, allow_empty: true) == :ok
  end

  test "freeze stores structured violation keys instead of parsing formatted text" do
    rule_id = "structured_freeze"
    graph = %{A => [B], B => []}

    System.put_env("ARCH_TEST_UPDATE_FREEZE", "true")

    assert Freeze.freeze(rule_id, fn ->
             ModuleSet.new("A")
             |> Assertions.should_not_depend_on(ModuleSet.new("B"), graph: graph)
           end) == :ok

    System.delete_env("ARCH_TEST_UPDATE_FREEZE")

    baseline = File.read!(Path.join(@tmp_dir, "#{rule_id}.txt"))
    assert baseline =~ "type=forbidden_dep"
    assert baseline =~ "caller=A"
    assert baseline =~ "callee=B"

    assert Freeze.freeze(rule_id, fn ->
             ModuleSet.new("A")
             |> Assertions.should_not_depend_on(ModuleSet.new("B"), graph: graph)
           end) == :ok
  end

  test "freeze update does not baseline empty-subject control failures" do
    rule_id = "empty_subject_is_not_freezable"

    System.put_env("ARCH_TEST_UPDATE_FREEZE", "true")

    assert_raise ExUnit.AssertionError, ~r/subject resolved to 0 modules/, fn ->
      Freeze.freeze(rule_id, fn ->
        ModuleSet.new("NoMatch.**")
        |> Assertions.should_not_depend_on(ModuleSet.new("B"), graph: %{})
      end)
    end

    refute File.exists?(Path.join(@tmp_dir, "#{rule_id}.txt"))
  end

  test "use ArchTest, freeze: true wraps assertion functions" do
    graph = %{A => [B], B => []}
    rule_id = "auto_freeze_rule"

    System.put_env("ARCH_TEST_UPDATE_FREEZE", "true")
    assert AutoFreezeCase.failing_rule(graph, rule_id) == :ok

    baseline = File.read!(Path.join(@tmp_dir, "#{rule_id}.txt"))
    assert baseline =~ "type=forbidden_dep"
  end

  test "use ArchTest, freeze: true baselines module count failures" do
    graph = %{A => []}

    System.put_env("ARCH_TEST_UPDATE_FREEZE", "true")

    assert AutoFreezeCase.count_rule(graph) == :ok

    baseline =
      @tmp_dir
      |> File.ls!()
      |> Enum.find(&String.contains?(&1, "should_have_module_count"))
      |> then(&File.read!(Path.join(@tmp_dir, &1)))

    assert baseline =~ "exactly 0"
    assert baseline =~ "got 1"
  end

  test "auto-freeze module count rule id ignores non-semantic graph option" do
    System.put_env("ARCH_TEST_UPDATE_FREEZE", "true")

    assert AutoFreezeCase.count_rule(%{A => []}) == :ok
    assert AutoFreezeCase.count_rule(%{A => [B], B => []}) == :ok

    files =
      @tmp_dir
      |> File.ls!()
      |> Enum.filter(&String.contains?(&1, "should_have_module_count"))

    assert length(files) == 1
  end

  test "auto-freeze rule ids distinguish rule arguments" do
    graph = %{A => []}

    check_a = fn _graph, mod -> [ArchTest.Violation.naming(mod, "a")] end
    check_b = fn _graph, mod -> [ArchTest.Violation.naming(mod, "b")] end

    System.put_env("ARCH_TEST_UPDATE_FREEZE", "true")

    assert AutoFreezeCase.attribute_value_rule(graph, :expected_a) == :ok
    assert AutoFreezeCase.attribute_value_rule(graph, :expected_b) == :ok
    assert AutoFreezeCase.satisfying_rule(graph, check_a) == :ok
    assert AutoFreezeCase.satisfying_rule(graph, check_b) == :ok

    files =
      @tmp_dir
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "ArchTest.UseOptionsTest.AutoFreezeCase."))

    assert length(files) == 4
  end

  test "auto-freeze rule ids distinguish scoped options" do
    graph = %{A => [B], B => []}

    System.put_env("ARCH_TEST_UPDATE_FREEZE", "true")

    assert AutoFreezeCase.scoped_rule(graph, :first_app) == :ok
    assert AutoFreezeCase.scoped_rule(graph, :second_app) == :ok

    files =
      @tmp_dir
      |> File.ls!()
      |> Enum.filter(&String.contains?(&1, "should_not_depend_on"))

    assert length(files) == 2
  end
end
