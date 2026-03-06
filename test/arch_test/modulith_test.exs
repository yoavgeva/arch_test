defmodule ArchTest.ModulithTest do
  use ExUnit.Case, async: true

  alias ArchTest.{Modulith, Violation}

  # Graph with cross-context violations
  @graph %{
    # Orders public API calls Accounts public API (allowed)
    FixtureApp.Orders => [FixtureApp.Accounts],
    # Orders.Checkout calls Inventory internal (violation)
    FixtureApp.Orders.Checkout => [FixtureApp.Inventory.Repo],
    FixtureApp.Orders.OrderService => [FixtureApp.Repo.OrderRepo],
    FixtureApp.Orders.OrderManager => [],
    FixtureApp.Inventory => [],
    FixtureApp.Inventory.Repo => [],
    FixtureApp.Inventory.Item => [],
    FixtureApp.Accounts => [],
    FixtureApp.Accounts.User => [],
    FixtureApp.Repo.OrderRepo => []
  }

  describe "enforce_isolation/1" do
    test "detects access to slice internals" do
      modulith =
        Modulith.define_slices(
          orders: "FixtureApp.Orders",
          inventory: "FixtureApp.Inventory",
          accounts: "FixtureApp.Accounts"
        )

      violations = check_isolation(modulith, @graph)

      # Checkout → InventoryRepo is a violation (internal access)
      assert Enum.any?(violations, fn v ->
               v.caller == FixtureApp.Orders.Checkout and
                 v.callee == FixtureApp.Inventory.Repo
             end)
    end

    test "access to public root without allow_dependency is a violation" do
      modulith =
        Modulith.define_slices(
          orders: "FixtureApp.Orders",
          inventory: "FixtureApp.Inventory",
          accounts: "FixtureApp.Accounts"
        )

      violations = check_isolation(modulith, @graph)

      # Orders → Accounts (public root) is a violation without allow_dependency
      assert Enum.any?(violations, fn v ->
               v.caller == FixtureApp.Orders and
                 v.callee == FixtureApp.Accounts
             end)
    end

    test "allow_dependency permits public root access" do
      modulith =
        Modulith.define_slices(
          orders: "FixtureApp.Orders",
          inventory: "FixtureApp.Inventory",
          accounts: "FixtureApp.Accounts"
        )
        |> Modulith.allow_dependency(:orders, :accounts)

      violations = check_isolation(modulith, @graph)

      # Orders → Accounts (public root) should now be allowed
      refute Enum.any?(violations, fn v ->
               v.caller == FixtureApp.Orders and
                 v.callee == FixtureApp.Accounts
             end)

      # But Checkout → InventoryRepo (internal) is still a violation
      assert Enum.any?(violations, fn v ->
               v.callee == FixtureApp.Inventory.Repo
             end)
    end
  end

  describe "should_be_free_of_cycles/1" do
    test "detects cycles between slices" do
      # Graph where orders depends on inventory and inventory depends on orders
      cyclic_graph =
        Map.merge(@graph, %{
          FixtureApp.Inventory => [FixtureApp.Orders]
        })

      modulith =
        Modulith.define_slices(
          orders: "FixtureApp.Orders",
          inventory: "FixtureApp.Inventory"
        )

      cycles = check_slice_cycles(modulith, cyclic_graph)
      assert cycles != []
    end

    test "passes with no slice cycles" do
      modulith =
        Modulith.define_slices(
          orders: "FixtureApp.Orders",
          accounts: "FixtureApp.Accounts"
        )

      cycles = check_slice_cycles(modulith, @graph)
      # Orders → Accounts but not back: no cycle
      assert cycles == []
    end
  end

  describe "should_not_depend_on_each_other/1" do
    test "passes when slices are completely isolated" do
      # Graph where no slice depends on any other slice
      isolated_graph = %{
        FixtureApp.Orders => [],
        FixtureApp.Orders.Checkout => [],
        FixtureApp.Inventory => [],
        FixtureApp.Inventory.Repo => [],
        FixtureApp.Accounts => []
      }

      modulith =
        Modulith.define_slices(
          orders: "FixtureApp.Orders",
          inventory: "FixtureApp.Inventory",
          accounts: "FixtureApp.Accounts"
        )

      violations = check_should_not_depend_on_each_other(modulith, isolated_graph)
      assert violations == []
    end

    test "detects cross-slice dependency even to public root" do
      # Orders → Accounts (public root) should still be a violation
      modulith =
        Modulith.define_slices(
          orders: "FixtureApp.Orders",
          inventory: "FixtureApp.Inventory",
          accounts: "FixtureApp.Accounts"
        )

      violations = check_should_not_depend_on_each_other(modulith, @graph)

      # Orders → Accounts is a cross-slice dep (public root but still forbidden)
      assert Enum.any?(violations, fn v ->
               v.caller == FixtureApp.Orders and
                 v.callee == FixtureApp.Accounts
             end)
    end

    test "detects cross-slice dependency to internals" do
      modulith =
        Modulith.define_slices(
          orders: "FixtureApp.Orders",
          inventory: "FixtureApp.Inventory",
          accounts: "FixtureApp.Accounts"
        )

      violations = check_should_not_depend_on_each_other(modulith, @graph)

      # Checkout → Inventory.Repo is a cross-slice dep (internal)
      assert Enum.any?(violations, fn v ->
               v.caller == FixtureApp.Orders.Checkout and
                 v.callee == FixtureApp.Inventory.Repo
             end)
    end

    test "allow_dependency has no effect — still reports violations" do
      # should_not_depend_on_each_other ignores allow_dependency
      modulith =
        Modulith.define_slices(
          orders: "FixtureApp.Orders",
          accounts: "FixtureApp.Accounts"
        )
        |> Modulith.allow_dependency(:orders, :accounts)

      violations = check_should_not_depend_on_each_other(modulith, @graph)

      # Orders → Accounts is still a violation under strict isolation
      assert Enum.any?(violations, fn v ->
               v.caller == FixtureApp.Orders and
                 v.callee == FixtureApp.Accounts
             end)
    end

    test "does not flag intra-slice dependencies" do
      # Graph where Orders.Checkout depends on Orders (same slice)
      intra_slice_graph = %{
        FixtureApp.Orders => [],
        FixtureApp.Orders.Checkout => [FixtureApp.Orders],
        FixtureApp.Accounts => []
      }

      modulith =
        Modulith.define_slices(
          orders: "FixtureApp.Orders",
          accounts: "FixtureApp.Accounts"
        )

      violations = check_should_not_depend_on_each_other(modulith, intra_slice_graph)
      assert violations == []
    end

    test "deduplicates violations by caller-callee pair" do
      modulith =
        Modulith.define_slices(
          orders: "FixtureApp.Orders",
          accounts: "FixtureApp.Accounts"
        )

      violations = check_should_not_depend_on_each_other(modulith, @graph)

      # Each {caller, callee} pair should appear at most once
      pairs = Enum.map(violations, fn v -> {v.caller, v.callee} end)
      assert pairs == Enum.uniq(pairs)
    end
  end

  describe "all_modules_covered_by/2,3" do
    @covered_graph %{
      FixtureApp.Orders => [],
      FixtureApp.Orders.Checkout => [],
      FixtureApp.Inventory => [],
      FixtureApp.Inventory.Item => [],
      FixtureApp.Application => []
    }

    test "passes when all modules belong to a slice" do
      modulith =
        Modulith.define_slices(
          orders: "FixtureApp.Orders",
          inventory: "FixtureApp.Inventory"
        )

      assert :ok =
               Modulith.all_modules_covered_by(modulith, "FixtureApp.**",
                 except: ["FixtureApp.Application"],
                 graph: @covered_graph
               )
    end

    test "fails when a module belongs to no slice" do
      graph = Map.put(@covered_graph, FixtureApp.Orphan.Thing, [])

      modulith =
        Modulith.define_slices(
          orders: "FixtureApp.Orders",
          inventory: "FixtureApp.Inventory"
        )

      assert_raise ExUnit.AssertionError, ~r/FixtureApp.Orphan.Thing/, fn ->
        Modulith.all_modules_covered_by(modulith, "FixtureApp.**",
          except: ["FixtureApp.Application"],
          graph: graph
        )
      end
    end

    test ":except option excludes modules from the check" do
      # FixtureApp.Application would otherwise be uncovered
      modulith =
        Modulith.define_slices(
          orders: "FixtureApp.Orders",
          inventory: "FixtureApp.Inventory"
        )

      assert :ok =
               Modulith.all_modules_covered_by(modulith, "FixtureApp.**",
                 except: ["FixtureApp.Application"],
                 graph: @covered_graph
               )

      # Without the :except it should fail
      assert_raise ExUnit.AssertionError, ~r/FixtureApp.Application/, fn ->
        Modulith.all_modules_covered_by(modulith, "FixtureApp.**", graph: @covered_graph)
      end
    end

    test "violation message contains 'does not belong to any declared slice'" do
      graph = Map.put(@covered_graph, FixtureApp.Unknown.Module, [])

      modulith =
        Modulith.define_slices(
          orders: "FixtureApp.Orders",
          inventory: "FixtureApp.Inventory"
        )

      assert_raise ExUnit.AssertionError,
                   ~r/does not belong to any declared slice/,
                   fn ->
                     Modulith.all_modules_covered_by(modulith, "FixtureApp.**",
                       except: ["FixtureApp.Application"],
                       graph: graph
                     )
                   end
    end
  end

  # ------------------------------------------------------------------
  # Private helpers to test modulith logic without xref
  # ------------------------------------------------------------------

  defp slice_all_modules(root_namespace, graph) do
    children_pattern = "#{root_namespace}.**"

    Enum.filter(Map.keys(graph), fn mod ->
      mod_str =
        mod
        |> Atom.to_string()
        |> strip_elixir_prefix()

      ArchTest.Pattern.matches?(children_pattern, mod_str) or
        ArchTest.Pattern.matches?(root_namespace, mod_str)
    end)
  end

  defp strip_elixir_prefix("Elixir." <> rest), do: rest
  defp strip_elixir_prefix(str), do: str

  defp build_slice_info(slices, graph) do
    Enum.map(slices, fn {slice_name, root_namespace} ->
      root_mod = Module.concat([root_namespace])
      all_mods = slice_all_modules(root_namespace, graph)
      {slice_name, root_mod, all_mods}
    end)
  end

  defp find_slice(mod, slice_info) do
    Enum.find_value(slice_info, {nil, nil}, fn {slice_name, root_mod, all_mods} ->
      if mod in all_mods, do: {slice_name, root_mod}
    end)
  end

  defp check_isolation(%Modulith{} = m, graph) do
    slice_info = build_slice_info(m.slices, graph)

    for {caller_slice, caller_pattern} <- m.slices,
        caller_mods = slice_all_modules(caller_pattern, graph),
        caller <- caller_mods,
        dep <- ArchTest.Collector.dependencies_of(graph, caller),
        {dep_slice, dep_root} = find_slice(dep, slice_info),
        dep_slice != nil,
        dep_slice != caller_slice do
      is_root = dep == dep_root
      allowed = {caller_slice, dep_slice} in m.allowed_deps

      cond do
        not is_root ->
          Violation.forbidden_dep(caller, dep, "internal access to #{dep_slice}")

        not allowed ->
          Violation.forbidden_dep(caller, dep, "cross-slice dep without allow_dependency")

        true ->
          nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  defp check_slice_cycles(%Modulith{} = m, graph) do
    slice_info = build_slice_info(m.slices, graph)

    slice_graph =
      Enum.reduce(m.slices, %{}, fn {slice_name, pattern}, acc ->
        mods = slice_all_modules(pattern, graph)

        dep_slices =
          mods
          |> Enum.flat_map(&ArchTest.Collector.dependencies_of(graph, &1))
          |> Enum.map(fn dep ->
            {dep_slice, _root} = find_slice(dep, slice_info)
            dep_slice
          end)
          |> Enum.reject(&(is_nil(&1) or &1 == slice_name))
          |> Enum.uniq()

        Map.put(acc, slice_name, dep_slices)
      end)

    ArchTest.Collector.cycles(slice_graph)
  end

  defp check_should_not_depend_on_each_other(%Modulith{} = m, graph) do
    slice_info = build_slice_info(m.slices, graph)

    for {slice_a, _pattern_a} <- m.slices,
        {slice_b, _pattern_b} <- m.slices,
        slice_a != slice_b do
      mods_a = slice_modules(slice_a, slice_info)
      mods_b = slice_modules(slice_b, slice_info) |> MapSet.new()

      for caller <- mods_a,
          dep <- ArchTest.Collector.dependencies_of(graph, caller),
          MapSet.member?(mods_b, dep) do
        Violation.forbidden_dep(
          caller,
          dep,
          "slice :#{slice_a} must not depend on slice :#{slice_b} at all (strict isolation). " <>
            "Even public API calls are forbidden. Remove this dependency."
        )
      end
    end
    |> List.flatten()
    |> Enum.uniq_by(fn v -> {v.caller, v.callee} end)
  end

  defp slice_modules(slice_name, slice_info) do
    Enum.find_value(slice_info, [], fn {name, _root, all_mods} ->
      if name == slice_name, do: all_mods
    end)
  end
end
