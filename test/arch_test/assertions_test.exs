defmodule ArchTest.AssertionsTest do
  use ExUnit.Case, async: true

  alias ArchTest.{ModuleSet, Violation}

  # In-memory graph representing the fixture app
  @graph %{
    FixtureApp.Orders => [FixtureApp.Accounts],
    FixtureApp.Orders.Checkout => [FixtureApp.Inventory.Repo],
    FixtureApp.Orders.OrderService => [FixtureApp.Repo.OrderRepo],
    FixtureApp.Orders.OrderManager => [],
    FixtureApp.Inventory => [],
    FixtureApp.Inventory.Repo => [],
    FixtureApp.Inventory.Item => [],
    FixtureApp.Accounts => [],
    FixtureApp.Accounts.User => [],
    FixtureApp.Web.Controller => [FixtureApp.Repo.OrderRepo],
    FixtureApp.Repo.OrderRepo => [],
    FixtureApp.Domain.Order => [],
    FixtureApp.Domain.CycleA => [FixtureApp.Domain.CycleB],
    FixtureApp.Domain.CycleB => [FixtureApp.Domain.CycleA]
  }

  # Helper: inject the graph so assertions use it without xref
  describe "should_not_depend_on/2" do
    test "passes when no forbidden deps exist" do
      subject = ModuleSet.new("FixtureApp.Inventory.**")
      object = ModuleSet.new("FixtureApp.Accounts.**")

      # Inventory modules have no deps on Accounts
      assert check_should_not_depend_on(subject, object, @graph) == []
    end

    test "detects forbidden dep (Checkout → InventoryRepo)" do
      subject = ModuleSet.new("FixtureApp.Orders.**")
      object = ModuleSet.new("FixtureApp.Inventory.*")

      violations = check_should_not_depend_on(subject, object, @graph)
      assert length(violations) >= 1

      assert Enum.any?(violations, fn v ->
               v.caller == FixtureApp.Orders.Checkout and
                 v.callee == FixtureApp.Inventory.Repo
             end)
    end
  end

  describe "should_only_depend_on/2" do
    test "passes when all deps are in allowed set" do
      subject = ModuleSet.new("FixtureApp.Orders")
      allowed = ModuleSet.new("FixtureApp.Accounts")

      violations = check_should_only_depend_on(subject, allowed, @graph)
      assert violations == []
    end

    test "detects dep outside allowed set" do
      subject = ModuleSet.new("FixtureApp.Orders.*")
      allowed = ModuleSet.new("FixtureApp.Accounts.*")

      violations = check_should_only_depend_on(subject, allowed, @graph)
      # Checkout → InventoryRepo, OrderService → OrderRepo are not in allowed
      assert length(violations) >= 1
    end
  end

  describe "should_not_be_called_by/2" do
    test "detects callers of protected module" do
      object = ModuleSet.new("FixtureApp.Repo.*")
      callers = ModuleSet.new("FixtureApp.Web.*")

      violations = check_should_not_be_called_by(object, callers, @graph)
      assert Enum.any?(violations, fn v -> v.caller == FixtureApp.Web.Controller end)
    end

    test "passes when no callers exist" do
      object = ModuleSet.new("FixtureApp.Domain.*")
      callers = ModuleSet.new("FixtureApp.Web.*")

      violations = check_should_not_be_called_by(object, callers, @graph)
      assert violations == []
    end
  end

  describe "should_not_exist/1" do
    test "detects Manager modules" do
      subject = ModuleSet.new("**.*Manager")
      violations = check_should_not_exist(subject, @graph)
      assert Enum.any?(violations, fn v -> v.module == FixtureApp.Orders.OrderManager end)
    end

    test "passes when no matching modules exist" do
      subject = ModuleSet.new("**.*Helper")
      violations = check_should_not_exist(subject, @graph)
      assert violations == []
    end
  end

  describe "should_reside_under/2" do
    test "passes when all modules are in namespace" do
      subject = ModuleSet.new("FixtureApp.Repo.*")
      violations = check_should_reside_under(subject, "FixtureApp.Repo.*", @graph)
      assert violations == []
    end

    test "detects module not in expected namespace" do
      subject = ModuleSet.new("FixtureApp.Inventory.*")
      violations = check_should_reside_under(subject, "FixtureApp.Inventory.Schemas.*", @graph)
      assert length(violations) >= 1
    end
  end

  describe "should_be_free_of_cycles/1" do
    test "detects cycles in cycle modules" do
      subject = ModuleSet.new("FixtureApp.Domain.**")
      violations = check_should_be_free_of_cycles(subject, @graph)
      assert length(violations) >= 1
    end

    test "passes for modules with no cycles" do
      subject = ModuleSet.new("FixtureApp.Accounts.**")
      violations = check_should_be_free_of_cycles(subject, @graph)
      assert violations == []
    end
  end

  describe "should_not_transitively_depend_on/2" do
    test "detects transitive dependency" do
      # CycleA → CycleB → CycleA (transitive), also Checkout → InventoryRepo
      subject = ModuleSet.new("FixtureApp.Orders.**")
      object = ModuleSet.new("FixtureApp.Inventory.*")

      violations = check_should_not_transitively_depend_on(subject, object, @graph)
      assert length(violations) >= 1
    end

    test "passes when no transitive dep exists" do
      subject = ModuleSet.new("FixtureApp.Accounts.*")
      object = ModuleSet.new("FixtureApp.Inventory.*")

      violations = check_should_not_transitively_depend_on(subject, object, @graph)
      assert violations == []
    end
  end

  describe "should_have_name_matching/2" do
    test "passes when all modules match name pattern" do
      subject = ModuleSet.new("FixtureApp.Repo.*")
      violations = check_should_have_name_matching(subject, "**.*Repo", @graph)
      assert violations == []
    end

    test "detects modules not matching name pattern" do
      # FixtureApp.Inventory.Repo matches but FixtureApp.Inventory.Item does not match *Repo
      subject = ModuleSet.new("FixtureApp.Inventory.*")
      violations = check_should_have_name_matching(subject, "**.*Repo", @graph)
      assert Enum.any?(violations, fn v -> v.module == FixtureApp.Inventory.Item end)
      # Inventory.Repo should pass
      refute Enum.any?(violations, fn v -> v.module == FixtureApp.Inventory.Repo end)
    end
  end

  describe "satisfying/2 custom check" do
    test "custom check can accumulate violations" do
      subject = ModuleSet.new("FixtureApp.Orders.*")

      violations =
        subject
        |> ModuleSet.resolve(@graph)
        |> Enum.flat_map(fn mod ->
          deps = ArchTest.Collector.dependencies_of(@graph, mod)
          if length(deps) > 0, do: [Violation.forbidden_dep(mod, hd(deps), "custom")], else: []
        end)

      assert is_list(violations)
    end
  end

  describe "edge cases" do
    test "empty subject produces no violations for should_not_depend_on" do
      subject = ModuleSet.new("NoMatch.Namespace.*")
      object = ModuleSet.new("FixtureApp.**")
      assert check_should_not_depend_on(subject, object, @graph) == []
    end

    test "empty object produces no violations for should_not_depend_on" do
      subject = ModuleSet.new("FixtureApp.Orders.*")
      object = ModuleSet.new("NoMatch.Namespace.*")
      assert check_should_not_depend_on(subject, object, @graph) == []
    end

    test "should_not_exist with no matching modules" do
      subject = ModuleSet.new("NonExistent.**")
      assert check_should_not_exist(subject, @graph) == []
    end

    test "cycles on single-module set are empty" do
      subject = ModuleSet.new("FixtureApp.Orders")
      violations = check_should_be_free_of_cycles(subject, @graph)
      assert violations == []
    end

    test "should_only_depend_on with empty subject returns no violations" do
      subject = ModuleSet.new("NoMatch.**")
      allowed = ModuleSet.new("FixtureApp.**")
      assert check_should_only_depend_on(subject, allowed, @graph) == []
    end
  end

  describe "should_implement_behaviour/2" do
    test "passes when modules implement the behaviour" do
      mod = FixtureApp.Behaviours.Implementing
      beh = FixtureApp.Behaviours.MyBehaviour
      graph = %{mod => []}
      ms = ModuleSet.satisfying(fn m -> m == mod end)

      assert ArchTest.Assertions.should_implement_behaviour(ms, beh, graph: graph) == :ok
    end

    test "fails when module does not implement the behaviour" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert_raise ExUnit.AssertionError, ~r/should_implement_behaviour/, fn ->
        ArchTest.Assertions.should_implement_behaviour(ms, GenServer, graph: graph)
      end
    end

    test "passes vacuously for empty subject" do
      ms = ModuleSet.satisfying(fn _ -> false end)

      assert ArchTest.Assertions.should_implement_behaviour(ms, GenServer, graph: %{}) == :ok
    end
  end

  describe "should_not_implement_behaviour/2" do
    test "passes when module does not implement behaviour" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert ArchTest.Assertions.should_not_implement_behaviour(ms, GenServer, graph: graph) ==
               :ok
    end

    test "fails when module implements the forbidden behaviour" do
      mod = FixtureApp.Behaviours.Implementing
      beh = FixtureApp.Behaviours.MyBehaviour
      graph = %{mod => []}
      ms = ModuleSet.satisfying(fn m -> m == mod end)

      assert_raise ExUnit.AssertionError, ~r/should_not_implement_behaviour/, fn ->
        ArchTest.Assertions.should_not_implement_behaviour(ms, beh, graph: graph)
      end
    end
  end

  describe "should_implement_protocol/2" do
    test "passes when module implements protocol" do
      # Atom implements String.Chars (String.Chars.Atom exists)
      graph = %{Atom => []}
      ms = ModuleSet.satisfying(fn mod -> mod == Atom end)

      assert ArchTest.Assertions.should_implement_protocol(ms, String.Chars, graph: graph) == :ok
    end

    test "fails when module does not implement protocol" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert_raise ExUnit.AssertionError, ~r/should_implement_protocol/, fn ->
        ArchTest.Assertions.should_implement_protocol(ms, Enumerable, graph: graph)
      end
    end
  end

  describe "should_not_implement_protocol/2" do
    test "passes when module does not implement protocol" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert ArchTest.Assertions.should_not_implement_protocol(ms, Enumerable, graph: graph) ==
               :ok
    end

    test "fails when module implements the forbidden protocol" do
      # List implements Enumerable (Enumerable.List exists)
      graph = %{List => []}
      ms = ModuleSet.satisfying(fn mod -> mod == List end)

      assert_raise ExUnit.AssertionError, ~r/should_not_implement_protocol/, fn ->
        ArchTest.Assertions.should_not_implement_protocol(ms, Enumerable, graph: graph)
      end
    end
  end

  describe "should_only_be_called_by/2" do
    test "passes when all callers are in the allowed set" do
      # FixtureApp.Repo.OrderRepo is called by OrderService AND Web.Controller
      # Allow both → should pass
      object = ModuleSet.new("FixtureApp.Repo.*")

      allowed =
        ModuleSet.new("FixtureApp.Orders.**")
        |> ModuleSet.union(ModuleSet.new("FixtureApp.Web.*"))

      assert ArchTest.Assertions.should_only_be_called_by(object, allowed, graph: @graph) == :ok
    end

    test "fails when an unauthorized caller exists" do
      # FixtureApp.Repo.OrderRepo is called by Web.Controller
      # Only allow Orders.** → Web.Controller is unauthorized
      object = ModuleSet.new("FixtureApp.Repo.*")
      allowed = ModuleSet.new("FixtureApp.Orders.**")

      assert_raise ExUnit.AssertionError, ~r/should_only_be_called_by/, fn ->
        ArchTest.Assertions.should_only_be_called_by(object, allowed, graph: @graph)
      end
    end

    test "violation message mentions the unauthorized caller" do
      object = ModuleSet.new("FixtureApp.Repo.*")
      allowed = ModuleSet.new("FixtureApp.Orders.**")

      assert_raise ExUnit.AssertionError, ~r/FixtureApp.Web.Controller/, fn ->
        ArchTest.Assertions.should_only_be_called_by(object, allowed, graph: @graph)
      end
    end

    test "passes when object has no callers at all" do
      # FixtureApp.Domain.Order has no callers in the graph
      object = ModuleSet.new("FixtureApp.Domain.Order")
      allowed = ModuleSet.new("FixtureApp.Orders.**")
      assert ArchTest.Assertions.should_only_be_called_by(object, allowed, graph: @graph) == :ok
    end

    test "respects message: opt in error output" do
      object = ModuleSet.new("FixtureApp.Repo.*")
      allowed = ModuleSet.new("FixtureApp.Orders.**")

      assert_raise ExUnit.AssertionError, ~r/custom note/, fn ->
        ArchTest.Assertions.should_only_be_called_by(object, allowed,
          graph: @graph,
          message: "custom note"
        )
      end
    end
  end

  # ------------------------------------------------------------------
  # Module attribute assertion tests
  # ------------------------------------------------------------------

  describe "should_have_attribute/2" do
    test "passes when module has the attribute" do
      # Implementing declares @behaviour MyBehaviour, so :behaviour attribute exists
      mod = FixtureApp.Behaviours.Implementing
      graph = %{mod => []}
      ms = ModuleSet.satisfying(fn m -> m == mod end)
      assert ArchTest.Assertions.should_have_attribute(ms, :behaviour, graph: graph) == :ok
    end

    test "passes when module has :vsn attribute (all compiled modules do)" do
      graph = %{ArchTest.Violation => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Violation end)
      assert ArchTest.Assertions.should_have_attribute(ms, :vsn, graph: graph) == :ok
    end

    test "fails when module does not have the attribute" do
      graph = %{ArchTest.Violation => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Violation end)

      assert_raise ExUnit.AssertionError, ~r/should_have_attribute/, fn ->
        ArchTest.Assertions.should_have_attribute(ms, :nonexistent_attr_xyz, graph: graph)
      end
    end

    test "error message lists present attributes" do
      graph = %{ArchTest.Violation => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Violation end)

      assert_raise ExUnit.AssertionError, ~r/Present attributes/, fn ->
        ArchTest.Assertions.should_have_attribute(ms, :nonexistent_attr_xyz, graph: graph)
      end
    end

    test "error message mentions the missing attribute name" do
      graph = %{ArchTest.Violation => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Violation end)

      assert_raise ExUnit.AssertionError, ~r/:nonexistent_attr_xyz/, fn ->
        ArchTest.Assertions.should_have_attribute(ms, :nonexistent_attr_xyz, graph: graph)
      end
    end
  end

  describe "should_not_have_attribute/2" do
    test "passes when module does not have the attribute" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert ArchTest.Assertions.should_not_have_attribute(ms, :nonexistent_attr_xyz,
               graph: graph
             ) == :ok
    end

    test "fails when module has the forbidden attribute" do
      # All compiled modules have :vsn
      graph = %{ArchTest.Violation => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Violation end)

      assert_raise ExUnit.AssertionError, ~r/should_not_have_attribute/, fn ->
        ArchTest.Assertions.should_not_have_attribute(ms, :vsn, graph: graph)
      end
    end

    test "fails when module has the :behaviour attribute" do
      # FixtureApp.Behaviours.Implementing declares @behaviour MyBehaviour
      mod = FixtureApp.Behaviours.Implementing
      graph = %{mod => []}
      ms = ModuleSet.satisfying(fn m -> m == mod end)

      assert_raise ExUnit.AssertionError, ~r/should_not_have_attribute/, fn ->
        ArchTest.Assertions.should_not_have_attribute(ms, :behaviour, graph: graph)
      end
    end
  end

  describe "should_have_attribute_value/3" do
    test "passes when attribute has the expected value" do
      # Implementing declares @behaviour MyBehaviour
      mod = FixtureApp.Behaviours.Implementing
      beh = FixtureApp.Behaviours.MyBehaviour
      graph = %{mod => []}
      ms = ModuleSet.satisfying(fn m -> m == mod end)

      assert ArchTest.Assertions.should_have_attribute_value(ms, :behaviour, [beh], graph: graph) ==
               :ok
    end

    test "fails when attribute has a different value" do
      mod = FixtureApp.Behaviours.Implementing
      graph = %{mod => []}
      ms = ModuleSet.satisfying(fn m -> m == mod end)

      assert_raise ExUnit.AssertionError, ~r/should_have_attribute_value/, fn ->
        ArchTest.Assertions.should_have_attribute_value(ms, :behaviour, [GenServer], graph: graph)
      end
    end

    test "error message shows actual and expected values" do
      mod = FixtureApp.Behaviours.Implementing
      graph = %{mod => []}
      ms = ModuleSet.satisfying(fn m -> m == mod end)

      assert_raise ExUnit.AssertionError, ~r/expected \[GenServer\]/, fn ->
        ArchTest.Assertions.should_have_attribute_value(ms, :behaviour, [GenServer], graph: graph)
      end
    end

    test "passes for nil when attribute does not exist" do
      graph = %{ArchTest.Violation => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Violation end)

      assert ArchTest.Assertions.should_have_attribute_value(ms, :nonexistent, nil, graph: graph) ==
               :ok
    end
  end

  describe "should_not_have_attribute_value/3" do
    test "passes when attribute has a different value" do
      mod = FixtureApp.Behaviours.Implementing
      graph = %{mod => []}
      ms = ModuleSet.satisfying(fn m -> m == mod end)

      assert ArchTest.Assertions.should_not_have_attribute_value(ms, :behaviour, [GenServer],
               graph: graph
             ) == :ok
    end

    test "fails when attribute has the forbidden value" do
      mod = FixtureApp.Behaviours.Implementing
      beh = FixtureApp.Behaviours.MyBehaviour
      graph = %{mod => []}
      ms = ModuleSet.satisfying(fn m -> m == mod end)

      assert_raise ExUnit.AssertionError, ~r/should_not_have_attribute_value/, fn ->
        ArchTest.Assertions.should_not_have_attribute_value(ms, :behaviour, [beh], graph: graph)
      end
    end

    test "passes when attribute does not exist (nil != forbidden value)" do
      graph = %{ArchTest.Violation => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Violation end)

      assert ArchTest.Assertions.should_not_have_attribute_value(
               ms,
               :nonexistent,
               [FixtureApp.Behaviours.MyBehaviour],
               graph: graph
             ) == :ok
    end
  end

  describe "should_use/2" do
    test "passes when module uses the target (appears in attribute values)" do
      # Implementing declares @behaviour MyBehaviour, so MyBehaviour appears in attributes
      mod = FixtureApp.Behaviours.Implementing
      beh = FixtureApp.Behaviours.MyBehaviour
      graph = %{mod => []}
      ms = ModuleSet.satisfying(fn m -> m == mod end)
      assert ArchTest.Assertions.should_use(ms, beh, graph: graph) == :ok
    end

    test "fails when module does not use the target" do
      graph = %{ArchTest.Violation => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Violation end)

      assert_raise ExUnit.AssertionError, ~r/should_use/, fn ->
        ArchTest.Assertions.should_use(ms, GenServer, graph: graph)
      end
    end

    test "error message mentions the expected module" do
      graph = %{ArchTest.Violation => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Violation end)

      assert_raise ExUnit.AssertionError, ~r/GenServer/, fn ->
        ArchTest.Assertions.should_use(ms, GenServer, graph: graph)
      end
    end
  end

  describe "should_not_use/2" do
    test "passes when module does not use the target" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)
      assert ArchTest.Assertions.should_not_use(ms, GenServer, graph: graph) == :ok
    end

    test "fails when module uses the target" do
      mod = FixtureApp.Behaviours.Implementing
      beh = FixtureApp.Behaviours.MyBehaviour
      graph = %{mod => []}
      ms = ModuleSet.satisfying(fn m -> m == mod end)

      assert_raise ExUnit.AssertionError, ~r/should_not_use/, fn ->
        ArchTest.Assertions.should_not_use(ms, beh, graph: graph)
      end
    end

    test "error message mentions the forbidden module" do
      mod = FixtureApp.Behaviours.Implementing
      beh = FixtureApp.Behaviours.MyBehaviour
      graph = %{mod => []}
      ms = ModuleSet.satisfying(fn m -> m == mod end)

      assert_raise ExUnit.AssertionError, ~r/MyBehaviour/, fn ->
        ArchTest.Assertions.should_not_use(ms, beh, graph: graph)
      end
    end
  end

  describe "should_export/3" do
    test "passes when module exports the function" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)
      # ArchTest.Pattern exports compile/1
      assert ArchTest.Assertions.should_export(ms, :compile, 1, graph: graph) == :ok
    end

    test "fails when module does not export the function" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert_raise ExUnit.AssertionError, ~r/should_export/, fn ->
        ArchTest.Assertions.should_export(ms, :nonexistent_function, 99, graph: graph)
      end
    end

    test "error message mentions the missing function" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert_raise ExUnit.AssertionError, ~r/nonexistent_function\/99/, fn ->
        ArchTest.Assertions.should_export(ms, :nonexistent_function, 99, graph: graph)
      end
    end
  end

  describe "should_not_export/3" do
    test "passes when module does not export the function" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)
      assert ArchTest.Assertions.should_not_export(ms, :nonexistent_fn, 99, graph: graph) == :ok
    end

    test "fails when module exports the forbidden function" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert_raise ExUnit.AssertionError, ~r/should_not_export/, fn ->
        ArchTest.Assertions.should_not_export(ms, :compile, 1, graph: graph)
      end
    end
  end

  describe "should_have_public_functions_matching/2" do
    test "passes when module has a matching function" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)
      # ArchTest.Pattern has matches?/2 -- pattern "matches*" should match
      assert ArchTest.Assertions.should_have_public_functions_matching(ms, "matches*",
               graph: graph
             ) == :ok
    end

    test "fails when no function matches the pattern" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert_raise ExUnit.AssertionError, ~r/should_have_public_functions_matching/, fn ->
        ArchTest.Assertions.should_have_public_functions_matching(ms, "nonexistent_prefix_xyz*",
          graph: graph
        )
      end
    end

    test "error message includes sample exports" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert_raise ExUnit.AssertionError, ~r/Sample exports/, fn ->
        ArchTest.Assertions.should_have_public_functions_matching(ms, "zzz*", graph: graph)
      end
    end
  end

  describe "should_not_have_public_functions_matching/2" do
    test "passes when no function matches the forbidden pattern" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert ArchTest.Assertions.should_not_have_public_functions_matching(ms, "zzz*",
               graph: graph
             ) == :ok
    end

    test "fails when a function matches the forbidden pattern" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)
      # ArchTest.Pattern has compile/1 -- pattern "compile*" should match it
      assert_raise ExUnit.AssertionError, ~r/should_not_have_public_functions_matching/, fn ->
        ArchTest.Assertions.should_not_have_public_functions_matching(ms, "compile*",
          graph: graph
        )
      end
    end

    test "violation message includes function name and arity" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert_raise ExUnit.AssertionError, ~r/compile\/1/, fn ->
        ArchTest.Assertions.should_not_have_public_functions_matching(ms, "compile*",
          graph: graph
        )
      end
    end
  end

  describe "should_have_attribute/2 with message: opt" do
    test "custom message appears in error" do
      graph = %{ArchTest.Violation => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Violation end)

      assert_raise ExUnit.AssertionError, ~r/custom note here/, fn ->
        ArchTest.Assertions.should_have_attribute(ms, :nonexistent_attr_xyz,
          graph: graph,
          message: "custom note here"
        )
      end
    end
  end

  describe "module attribute assertions with multiple modules" do
    test "should_have_attribute passes when all modules have the attribute" do
      # Both modules have :vsn (all compiled modules do)
      graph = %{ArchTest.Pattern => [], ArchTest.Rule => []}
      ms = ModuleSet.satisfying(fn mod -> mod in [ArchTest.Pattern, ArchTest.Rule] end)
      assert ArchTest.Assertions.should_have_attribute(ms, :vsn, graph: graph) == :ok
    end

    test "should_have_attribute fails when one module lacks the attribute" do
      # Implementing has :behaviour, ArchTest.Violation does not
      impl = FixtureApp.Behaviours.Implementing
      graph = %{impl => [], ArchTest.Violation => []}
      ms = ModuleSet.satisfying(fn mod -> mod in [impl, ArchTest.Violation] end)

      assert_raise ExUnit.AssertionError, ~r/should_have_attribute/, fn ->
        ArchTest.Assertions.should_have_attribute(ms, :behaviour, graph: graph)
      end
    end
  end

  describe "should_have_module_count/2" do
    test "passes with exactly constraint" do
      ms = ModuleSet.new("FixtureApp.Orders.*")
      count = ms |> ModuleSet.resolve(@graph) |> length()

      assert ArchTest.Assertions.should_have_module_count(ms, exactly: count, graph: @graph) ==
               :ok
    end

    test "fails when exactly constraint not met" do
      ms = ModuleSet.new("FixtureApp.Orders.*")

      assert_raise ExUnit.AssertionError, ~r/should_have_module_count/, fn ->
        ArchTest.Assertions.should_have_module_count(ms, exactly: 999, graph: @graph)
      end
    end

    test "passes with at_least constraint" do
      ms = ModuleSet.new("FixtureApp.**")
      assert ArchTest.Assertions.should_have_module_count(ms, at_least: 1, graph: @graph) == :ok
    end

    test "fails with at_least when subject is empty" do
      ms = ModuleSet.new("NoMatch.Namespace.**")

      assert_raise ExUnit.AssertionError, ~r/at_least/, fn ->
        ArchTest.Assertions.should_have_module_count(ms, at_least: 1, graph: @graph)
      end
    end

    test "passes with at_most constraint" do
      ms = ModuleSet.new("FixtureApp.Orders.*")
      count = ms |> ModuleSet.resolve(@graph) |> length()

      assert ArchTest.Assertions.should_have_module_count(ms, at_most: count, graph: @graph) ==
               :ok
    end

    test "fails with at_most when too many modules" do
      ms = ModuleSet.new("FixtureApp.**")

      assert_raise ExUnit.AssertionError, ~r/at_most/, fn ->
        ArchTest.Assertions.should_have_module_count(ms, at_most: 0, graph: @graph)
      end
    end

    test "passes with less_than constraint" do
      ms = ModuleSet.new("FixtureApp.Orders.*")

      assert ArchTest.Assertions.should_have_module_count(ms, less_than: 100, graph: @graph) ==
               :ok
    end

    test "fails with less_than when count is not less" do
      ms = ModuleSet.new("FixtureApp.**")

      assert_raise ExUnit.AssertionError, ~r/less_than/, fn ->
        ArchTest.Assertions.should_have_module_count(ms, less_than: 1, graph: @graph)
      end
    end

    test "passes with more_than constraint" do
      ms = ModuleSet.new("FixtureApp.**")
      assert ArchTest.Assertions.should_have_module_count(ms, more_than: 0, graph: @graph) == :ok
    end

    test "fails with more_than when count is not greater" do
      ms = ModuleSet.new("NoMatch.**")

      assert_raise ExUnit.AssertionError, ~r/more_than/, fn ->
        ArchTest.Assertions.should_have_module_count(ms, more_than: 0, graph: @graph)
      end
    end

    test "passes with at_least and at_most range" do
      ms = ModuleSet.new("FixtureApp.Orders.*")
      count = ms |> ModuleSet.resolve(@graph) |> length()

      assert ArchTest.Assertions.should_have_module_count(ms,
               at_least: 1,
               at_most: count,
               graph: @graph
             ) == :ok
    end

    test "error message contains actual count" do
      ms = ModuleSet.new("FixtureApp.Orders.*")

      assert_raise ExUnit.AssertionError, ~r/got \d+/, fn ->
        ArchTest.Assertions.should_have_module_count(ms, exactly: 999, graph: @graph)
      end
    end

    test "error message contains constraint description" do
      ms = ModuleSet.new("FixtureApp.Orders.*")

      assert_raise ExUnit.AssertionError, ~r/exactly: 999/, fn ->
        ArchTest.Assertions.should_have_module_count(ms, exactly: 999, graph: @graph)
      end
    end

    test "message: opt appears in error" do
      ms = ModuleSet.new("NoMatch.**")

      assert_raise ExUnit.AssertionError, ~r/too many modules/, fn ->
        ArchTest.Assertions.should_have_module_count(ms,
          at_least: 1,
          graph: @graph,
          message: "too many modules"
        )
      end
    end

    test "combined constraints fail when any is violated" do
      ms = ModuleSet.new("FixtureApp.**")

      assert_raise ExUnit.AssertionError, ~r/less_than/, fn ->
        ArchTest.Assertions.should_have_module_count(ms, at_least: 1, less_than: 2, graph: @graph)
      end
    end
  end

  # ------------------------------------------------------------------
  # message: opt tests — one per assertion function
  # ------------------------------------------------------------------

  describe "message: opt for should_not_depend_on" do
    test "custom message appears in AssertionError" do
      subject = ModuleSet.new("FixtureApp.Orders.**")
      object = ModuleSet.new("FixtureApp.Inventory.*")

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_not_depend_on(subject, object,
          graph: @graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_only_depend_on" do
    test "custom message appears in AssertionError" do
      subject = ModuleSet.new("FixtureApp.Orders.*")
      allowed = ModuleSet.new("FixtureApp.Accounts.*")

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_only_depend_on(subject, allowed,
          graph: @graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_not_be_called_by" do
    test "custom message appears in AssertionError" do
      object = ModuleSet.new("FixtureApp.Repo.*")
      callers = ModuleSet.new("FixtureApp.Web.*")

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_not_be_called_by(object, callers,
          graph: @graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_only_be_called_by" do
    test "custom message appears in AssertionError" do
      object = ModuleSet.new("FixtureApp.Repo.*")
      allowed = ModuleSet.new("FixtureApp.Orders.**")

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_only_be_called_by(object, allowed,
          graph: @graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_not_transitively_depend_on" do
    test "custom message appears in AssertionError" do
      subject = ModuleSet.new("FixtureApp.Orders.**")
      object = ModuleSet.new("FixtureApp.Inventory.*")

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_not_transitively_depend_on(subject, object,
          graph: @graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_not_exist" do
    test "custom message appears in AssertionError" do
      subject = ModuleSet.new("**.*Manager")

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_not_exist(subject, graph: @graph, message: "my custom message")
      end
    end
  end

  describe "message: opt for should_reside_under" do
    test "custom message appears in AssertionError" do
      subject = ModuleSet.new("FixtureApp.Inventory.*")

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_reside_under(subject, "FixtureApp.Inventory.Schemas.*",
          graph: @graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_have_name_matching" do
    test "custom message appears in AssertionError" do
      subject = ModuleSet.new("FixtureApp.Inventory.*")

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_have_name_matching(subject, "**.*Repo",
          graph: @graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_be_free_of_cycles" do
    test "custom message appears in AssertionError" do
      subject = ModuleSet.new("FixtureApp.Domain.**")

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_be_free_of_cycles(subject,
          graph: @graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_export" do
    test "custom message appears in AssertionError" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_export(ms, :nonexistent_function, 99,
          graph: graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_not_export" do
    test "custom message appears in AssertionError" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_not_export(ms, :compile, 1,
          graph: graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_have_public_functions_matching" do
    test "custom message appears in AssertionError" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_have_public_functions_matching(ms, "zzz*",
          graph: graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_not_have_public_functions_matching" do
    test "custom message appears in AssertionError" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_not_have_public_functions_matching(ms, "compile*",
          graph: graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_have_module_count" do
    test "custom message appears in AssertionError" do
      ms = ModuleSet.new("FixtureApp.Orders.*")

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_have_module_count(ms,
          exactly: 999,
          graph: @graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for satisfying" do
    test "custom message appears in AssertionError" do
      ms = ModuleSet.new("FixtureApp.Orders.*")

      check_fn = fn _graph, mod ->
        [ArchTest.Violation.naming(mod, "always fails")]
      end

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.satisfying(ms, check_fn, graph: @graph, message: "my custom message")
      end
    end
  end

  describe "message: opt for should_implement_behaviour" do
    test "custom message appears in AssertionError" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_implement_behaviour(ms, GenServer,
          graph: graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_not_implement_behaviour" do
    test "custom message appears in AssertionError" do
      mod = FixtureApp.Behaviours.Implementing
      beh = FixtureApp.Behaviours.MyBehaviour
      graph = %{mod => []}
      ms = ModuleSet.satisfying(fn m -> m == mod end)

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_not_implement_behaviour(ms, beh,
          graph: graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_implement_protocol" do
    test "custom message appears in AssertionError" do
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_implement_protocol(ms, Enumerable,
          graph: graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_not_implement_protocol" do
    test "custom message appears in AssertionError" do
      graph = %{List => []}
      ms = ModuleSet.satisfying(fn mod -> mod == List end)

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_not_implement_protocol(ms, Enumerable,
          graph: graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_have_attribute" do
    test "custom message appears in AssertionError" do
      graph = %{ArchTest.Violation => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Violation end)

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_have_attribute(ms, :nonexistent_attr_xyz,
          graph: graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_not_have_attribute" do
    test "custom message appears in AssertionError" do
      graph = %{ArchTest.Violation => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Violation end)

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_not_have_attribute(ms, :vsn,
          graph: graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_have_attribute_value" do
    test "custom message appears in AssertionError" do
      mod = FixtureApp.Behaviours.Implementing
      graph = %{mod => []}
      ms = ModuleSet.satisfying(fn m -> m == mod end)

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_have_attribute_value(ms, :behaviour, [GenServer],
          graph: graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_not_have_attribute_value" do
    test "custom message appears in AssertionError" do
      mod = FixtureApp.Behaviours.Implementing
      beh = FixtureApp.Behaviours.MyBehaviour
      graph = %{mod => []}
      ms = ModuleSet.satisfying(fn m -> m == mod end)

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_not_have_attribute_value(ms, :behaviour, [beh],
          graph: graph,
          message: "my custom message"
        )
      end
    end
  end

  describe "message: opt for should_use" do
    test "custom message appears in AssertionError" do
      graph = %{ArchTest.Violation => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Violation end)

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_use(ms, GenServer, graph: graph, message: "my custom message")
      end
    end
  end

  describe "message: opt for should_not_use" do
    test "custom message appears in AssertionError" do
      mod = FixtureApp.Behaviours.Implementing
      beh = FixtureApp.Behaviours.MyBehaviour
      graph = %{mod => []}
      ms = ModuleSet.satisfying(fn m -> m == mod end)

      assert_raise ExUnit.AssertionError, ~r/my custom message/, fn ->
        ArchTest.Assertions.should_not_use(ms, beh,
          graph: graph,
          message: "my custom message"
        )
      end
    end
  end

  # ------------------------------------------------------------------
  # should_be_free_of_cycles edge cases
  # ------------------------------------------------------------------

  describe "should_be_free_of_cycles edge cases" do
    @cycle3_graph %{
      Fake.CycleX => [Fake.CycleY],
      Fake.CycleY => [Fake.CycleZ],
      Fake.CycleZ => [Fake.CycleX]
    }

    test "detects a 3-node cycle (A -> B -> C -> A)" do
      ms = ModuleSet.new("Fake.Cycle*")

      assert_raise ExUnit.AssertionError, ~r/should_be_free_of_cycles/, fn ->
        ArchTest.Assertions.should_be_free_of_cycles(ms, graph: @cycle3_graph)
      end
    end

    test "detects multiple disjoint cycles in same subject" do
      graph = %{
        Fake.CycA1 => [Fake.CycA2],
        Fake.CycA2 => [Fake.CycA1],
        Fake.CycB1 => [Fake.CycB2],
        Fake.CycB2 => [Fake.CycB1]
      }

      ms = ModuleSet.new("Fake.**")

      assert_raise ExUnit.AssertionError, ~r/should_be_free_of_cycles/, fn ->
        ArchTest.Assertions.should_be_free_of_cycles(ms, graph: graph)
      end
    end

    test "empty subject passes with no violations" do
      ms = ModuleSet.new("NoMatch.Namespace.**")
      assert ArchTest.Assertions.should_be_free_of_cycles(ms, graph: @graph) == :ok
    end
  end

  # ------------------------------------------------------------------
  # should_have_module_count edge cases
  # ------------------------------------------------------------------

  describe "should_have_module_count edge cases" do
    test "exactly: 0 with empty subject passes" do
      ms = ModuleSet.new("NoMatch.Namespace.**")
      assert ArchTest.Assertions.should_have_module_count(ms, exactly: 0, graph: @graph) == :ok
    end

    test "invalid constraint key raises AssertionError with unknown constraint message" do
      ms = ModuleSet.new("FixtureApp.Orders.*")

      assert_raise ExUnit.AssertionError, ~r/unknown constraint :bogus/, fn ->
        ArchTest.Assertions.should_have_module_count(ms, bogus: 5, graph: @graph)
      end
    end
  end

  # ------------------------------------------------------------------
  # should_not_transitively_depend_on edge cases
  # ------------------------------------------------------------------

  describe "should_not_transitively_depend_on edge cases" do
    test "detects multiple forbidden targets via union" do
      # Orders.Checkout -> Inventory.Repo (transitive to Inventory)
      # Orders.OrderService -> Repo.OrderRepo (transitive to Repo)
      subject = ModuleSet.new("FixtureApp.Orders.**")

      object =
        ModuleSet.new("FixtureApp.Inventory.*")
        |> ModuleSet.union(ModuleSet.new("FixtureApp.Repo.*"))

      assert_raise ExUnit.AssertionError, ~r/should_not_transitively_depend_on/, fn ->
        ArchTest.Assertions.should_not_transitively_depend_on(subject, object, graph: @graph)
      end
    end
  end

  # ------------------------------------------------------------------
  # satisfying/2 edge cases
  # ------------------------------------------------------------------

  describe "satisfying/2 edge cases" do
    test "check_fn returns violations for some modules but not others" do
      ms = ModuleSet.new("FixtureApp.Orders.*")

      check_fn = fn _graph, mod ->
        # Only flag Checkout, not the others
        if mod == FixtureApp.Orders.Checkout do
          [ArchTest.Violation.naming(mod, "checkout is bad")]
        else
          []
        end
      end

      assert_raise ExUnit.AssertionError, ~r/satisfying/, fn ->
        ArchTest.Assertions.satisfying(ms, check_fn, graph: @graph)
      end
    end

    test "check_fn that returns empty list for all modules passes" do
      ms = ModuleSet.new("FixtureApp.Orders.*")

      check_fn = fn _graph, _mod -> [] end

      assert ArchTest.Assertions.satisfying(ms, check_fn, graph: @graph) == :ok
    end
  end

  # ------------------------------------------------------------------
  # should_only_be_called_by edge cases
  # ------------------------------------------------------------------

  describe "should_only_be_called_by edge cases" do
    test "multiple callers, only some in allowed set, produces violations for unauthorized ones" do
      # Accounts is called by Orders (allowed) but we need to ensure that
      # if another unauthorized module also calls it, that one is flagged.
      graph = %{
        Fake.ModA => [Fake.Protected],
        Fake.ModB => [Fake.Protected],
        Fake.ModC => [Fake.Protected],
        Fake.Protected => []
      }

      object = ModuleSet.new("Fake.Protected")
      # Only allow ModA
      allowed = ModuleSet.satisfying(fn mod -> mod == Fake.ModA end)

      assert_raise ExUnit.AssertionError, ~r/should_only_be_called_by/, fn ->
        ArchTest.Assertions.should_only_be_called_by(object, allowed, graph: graph)
      end
    end

    test "object modules calling each other are not flagged as unauthorized" do
      # Bug fix test: object modules should not be treated as unauthorized callers
      graph = %{
        Fake.RepoA => [Fake.RepoB],
        Fake.RepoB => [],
        Fake.Allowed => [Fake.RepoA]
      }

      object = ModuleSet.new("Fake.Repo*")
      allowed = ModuleSet.satisfying(fn mod -> mod == Fake.Allowed end)

      # RepoA calls RepoB, but since RepoA is in the object set, it should not be a violation
      assert ArchTest.Assertions.should_only_be_called_by(object, allowed, graph: graph) == :ok
    end
  end

  # ------------------------------------------------------------------
  # Helper functions that invoke assertion logic without xref
  # ------------------------------------------------------------------

  defp check_should_not_depend_on(subject, object, graph) do
    subject_mods = ModuleSet.resolve(subject, graph)
    object_mods = ModuleSet.resolve(object, graph) |> MapSet.new()

    for caller <- subject_mods,
        callee <- ArchTest.Collector.dependencies_of(graph, caller),
        MapSet.member?(object_mods, callee) do
      Violation.forbidden_dep(caller, callee, "forbidden")
    end
  end

  defp check_should_only_depend_on(subject, allowed, graph) do
    subject_mods = ModuleSet.resolve(subject, graph)
    allowed_mods = ModuleSet.resolve(allowed, graph) |> MapSet.new()

    for caller <- subject_mods,
        callee <- ArchTest.Collector.dependencies_of(graph, caller),
        Map.has_key?(graph, callee),
        not MapSet.member?(allowed_mods, callee) do
      Violation.forbidden_dep(caller, callee, "not in allowed set")
    end
  end

  defp check_should_not_be_called_by(object, callers, graph) do
    object_mods = ModuleSet.resolve(object, graph) |> MapSet.new()
    caller_mods = ModuleSet.resolve(callers, graph)

    for caller <- caller_mods,
        callee <- ArchTest.Collector.dependencies_of(graph, caller),
        MapSet.member?(object_mods, callee) do
      Violation.forbidden_dep(caller, callee, "forbidden caller")
    end
  end

  defp check_should_not_exist(subject, graph) do
    subject_mods = ModuleSet.resolve(subject, graph)
    Enum.map(subject_mods, fn mod -> Violation.existence(mod, "should not exist") end)
  end

  defp check_should_reside_under(subject, pattern, graph) do
    subject_mods = ModuleSet.resolve(subject, graph)

    for mod <- subject_mods,
        mod_str = ArchTest.Pattern.module_to_string(mod),
        not ArchTest.Pattern.matches?(pattern, mod_str) do
      Violation.naming(mod, "should reside under #{pattern}")
    end
  end

  defp check_should_be_free_of_cycles(subject, graph) do
    subject_mods = ModuleSet.resolve(subject, graph) |> MapSet.new()

    subgraph =
      graph
      |> Enum.filter(fn {mod, _} -> MapSet.member?(subject_mods, mod) end)
      |> Enum.map(fn {mod, deps} ->
        {mod, Enum.filter(deps, &MapSet.member?(subject_mods, &1))}
      end)
      |> Map.new()

    ArchTest.Collector.cycles(subgraph)
    |> Enum.map(fn cycle -> Violation.cycle(cycle, "cycle found") end)
  end

  defp check_should_have_name_matching(subject, pattern, graph) do
    subject_mods = ModuleSet.resolve(subject, graph)

    for mod <- subject_mods,
        mod_str = ArchTest.Pattern.module_to_string(mod),
        not ArchTest.Pattern.matches?(pattern, mod_str) do
      Violation.naming(mod, "should match pattern #{pattern}")
    end
  end

  defp check_should_not_transitively_depend_on(subject, object, graph) do
    subject_mods = ModuleSet.resolve(subject, graph)
    object_mods = ModuleSet.resolve(object, graph) |> MapSet.new()

    for caller <- subject_mods do
      transitive = ArchTest.Collector.transitive_dependencies_of(graph, caller)
      forbidden = Enum.filter(transitive, &MapSet.member?(object_mods, &1))
      Enum.map(forbidden, fn callee -> Violation.forbidden_dep(caller, callee, "transitive") end)
    end
    |> List.flatten()
  end
end
