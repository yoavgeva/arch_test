defmodule ArchTest.IntegrationTest do
  @moduledoc """
  Integration tests that exercise ArchTest against real compiled BEAM files
  from the fixture_app.

  The fixture_app is pre-compiled to:
    test/support/fixture_app/_build/dev/lib/fixture_app/ebin/

  These tests verify the full pipeline:
    FixtureApp source → BEAM files → :xref → dependency graph → assertions

  Every test runs against real BEAM file introspection, not mock graphs.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  @ebin Path.expand("../support/fixture_app/_build/dev/lib/fixture_app/ebin", __DIR__)

  # Build the real graph once and share it across helpers.
  # Each test calls graph() which returns a cached result.
  defp graph do
    ArchTest.Collector.build_graph_from_path(@ebin)
  end

  # ---------------------------------------------------------------------------
  # Collector — real BEAM introspection
  # ---------------------------------------------------------------------------

  describe "Collector.build_graph_from_path/1" do
    test "loads all 21 fixture modules" do
      g = graph()
      mods = ArchTest.Collector.all_modules(g)
      assert length(mods) == 21
    end

    test "every FixtureApp module is present as a key" do
      g = graph()
      mods = ArchTest.Collector.all_modules(g)

      expected = [
        FixtureApp,
        FixtureApp.Accounts,
        FixtureApp.Accounts.User,
        FixtureApp.Domain.CycleA,
        FixtureApp.Domain.CycleB,
        FixtureApp.Domain.Order,
        FixtureApp.Inventory,
        FixtureApp.Inventory.Item,
        FixtureApp.Inventory.Repo,
        FixtureApp.Orders,
        FixtureApp.Orders.Checkout,
        FixtureApp.Orders.OrderManager,
        FixtureApp.Orders.OrderService,
        FixtureApp.Repo.OrderRepo,
        FixtureApp.Web.Controller
      ]

      for mod <- expected do
        assert mod in mods, "Expected #{inspect(mod)} in graph keys"
      end
    end

    test "Checkout depends on Inventory.Repo" do
      g = graph()
      deps = ArchTest.Collector.dependencies_of(g, FixtureApp.Orders.Checkout)
      assert FixtureApp.Inventory.Repo in deps
    end

    test "OrderService depends on Repo.OrderRepo" do
      g = graph()
      deps = ArchTest.Collector.dependencies_of(g, FixtureApp.Orders.OrderService)
      assert FixtureApp.Repo.OrderRepo in deps
    end

    test "Web.Controller depends on Repo.OrderRepo" do
      g = graph()
      deps = ArchTest.Collector.dependencies_of(g, FixtureApp.Web.Controller)
      assert FixtureApp.Repo.OrderRepo in deps
    end

    test "Orders depends on Accounts" do
      g = graph()
      deps = ArchTest.Collector.dependencies_of(g, FixtureApp.Orders)
      assert FixtureApp.Accounts in deps
    end

    test "Inventory depends on Inventory.Item" do
      g = graph()
      deps = ArchTest.Collector.dependencies_of(g, FixtureApp.Inventory)
      assert FixtureApp.Inventory.Item in deps
    end

    test "CycleA depends on CycleB" do
      g = graph()

      assert FixtureApp.Domain.CycleB in ArchTest.Collector.dependencies_of(
               g,
               FixtureApp.Domain.CycleA
             )
    end

    test "CycleB depends on CycleA" do
      g = graph()

      assert FixtureApp.Domain.CycleA in ArchTest.Collector.dependencies_of(
               g,
               FixtureApp.Domain.CycleB
             )
    end

    test "pure modules have no FixtureApp deps" do
      g = graph()
      # Repo.OrderRepo depends on nothing within FixtureApp
      deps = ArchTest.Collector.dependencies_of(g, FixtureApp.Repo.OrderRepo)

      fixture_deps =
        Enum.filter(deps, fn m ->
          m |> Atom.to_string() |> String.starts_with?("Elixir.FixtureApp")
        end)

      assert fixture_deps == []
    end

    test "dependents_of finds Checkout as caller of Inventory.Repo" do
      g = graph()
      callers = ArchTest.Collector.dependents_of(g, FixtureApp.Inventory.Repo)
      assert FixtureApp.Orders.Checkout in callers
    end

    test "dependents_of finds Controller and OrderService as callers of OrderRepo" do
      g = graph()
      callers = ArchTest.Collector.dependents_of(g, FixtureApp.Repo.OrderRepo)
      assert FixtureApp.Web.Controller in callers
      assert FixtureApp.Orders.OrderService in callers
    end
  end

  # ---------------------------------------------------------------------------
  # Collector — transitive dependencies
  # ---------------------------------------------------------------------------

  describe "Collector.transitive_dependencies_of/2" do
    test "Checkout transitively reaches Inventory.Repo" do
      g = graph()
      transitive = ArchTest.Collector.transitive_dependencies_of(g, FixtureApp.Orders.Checkout)
      assert FixtureApp.Inventory.Repo in transitive
    end

    test "Orders transitively reaches Accounts" do
      g = graph()
      transitive = ArchTest.Collector.transitive_dependencies_of(g, FixtureApp.Orders)
      assert FixtureApp.Accounts in transitive
    end

    test "handles cycles without hanging" do
      g = graph()
      # CycleA → CycleB → CycleA is a cycle; must not loop forever
      transitive = ArchTest.Collector.transitive_dependencies_of(g, FixtureApp.Domain.CycleA)
      assert FixtureApp.Domain.CycleB in transitive
      # terminates (test timeout would catch infinite loop)
    end

    test "leaf modules have empty transitive deps within FixtureApp" do
      g = graph()
      transitive = ArchTest.Collector.transitive_dependencies_of(g, FixtureApp.Repo.OrderRepo)

      fixture_transitive =
        Enum.filter(transitive, fn m ->
          m |> Atom.to_string() |> String.starts_with?("Elixir.FixtureApp")
        end)

      assert fixture_transitive == []
    end
  end

  # ---------------------------------------------------------------------------
  # Collector — cycle detection
  # ---------------------------------------------------------------------------

  describe "Collector.cycles/1 on real graph" do
    test "detects the CycleA ↔ CycleB cycle" do
      g = graph()
      # Restrict to Domain namespace
      domain_graph =
        g
        |> Enum.filter(fn {m, _} ->
          m |> Atom.to_string() |> String.starts_with?("Elixir.FixtureApp.Domain")
        end)
        |> Enum.map(fn {m, deps} ->
          fixture_deps =
            Enum.filter(deps, fn d ->
              d |> Atom.to_string() |> String.starts_with?("Elixir.FixtureApp.Domain")
            end)

          {m, fixture_deps}
        end)
        |> Map.new()

      cycles = ArchTest.Collector.cycles(domain_graph)
      assert length(cycles) >= 1
      cycle_mods = List.flatten(cycles)
      assert FixtureApp.Domain.CycleA in cycle_mods
      assert FixtureApp.Domain.CycleB in cycle_mods
    end

    test "acyclic modules produce no cycles" do
      g = graph()

      accounts_graph =
        g
        |> Enum.filter(fn {m, _} ->
          m |> Atom.to_string() |> String.starts_with?("Elixir.FixtureApp.Accounts")
        end)
        |> Enum.map(fn {m, deps} ->
          fixture_deps =
            Enum.filter(deps, fn d ->
              d |> Atom.to_string() |> String.starts_with?("Elixir.FixtureApp.Accounts")
            end)

          {m, fixture_deps}
        end)
        |> Map.new()

      assert ArchTest.Collector.cycles(accounts_graph) == []
    end
  end

  # ---------------------------------------------------------------------------
  # ModuleSet resolution against real graph
  # ---------------------------------------------------------------------------

  describe "ModuleSet.resolve/2 against real graph" do
    test "direct children pattern" do
      g = graph()
      ms = ArchTest.ModuleSet.new("FixtureApp.Orders.*")
      result = ArchTest.ModuleSet.resolve(ms, g)
      assert FixtureApp.Orders.Checkout in result
      assert FixtureApp.Orders.OrderService in result
      assert FixtureApp.Orders.OrderManager in result
      refute FixtureApp.Orders in result
    end

    test "all descendants pattern" do
      g = graph()
      ms = ArchTest.ModuleSet.new("FixtureApp.**")
      result = ArchTest.ModuleSet.resolve(ms, g)
      # FixtureApp.** matches all descendants but NOT FixtureApp root itself
      # (** requires at least one dot-segment). 20 = 21 total - 1 root.
      assert length(result) == 20
    end

    test "ending pattern matches correctly" do
      g = graph()
      ms = ArchTest.ModuleSet.new("**.*Repo")
      result = ArchTest.ModuleSet.resolve(ms, g)
      assert FixtureApp.Inventory.Repo in result
      assert FixtureApp.Repo.OrderRepo in result
      refute FixtureApp.Orders in result
    end

    test "exact module name" do
      g = graph()
      ms = ArchTest.ModuleSet.new("FixtureApp.Orders")
      result = ArchTest.ModuleSet.resolve(ms, g)
      assert result == [FixtureApp.Orders]
    end

    test "excluding filters out modules" do
      g = graph()

      ms =
        ArchTest.ModuleSet.new("FixtureApp.Orders.*")
        |> ArchTest.ModuleSet.excluding("FixtureApp.Orders.OrderManager")

      result = ArchTest.ModuleSet.resolve(ms, g)
      refute FixtureApp.Orders.OrderManager in result
      assert FixtureApp.Orders.Checkout in result
    end

    test "union combines two sets" do
      g = graph()
      a = ArchTest.ModuleSet.new("FixtureApp.Orders")
      b = ArchTest.ModuleSet.new("FixtureApp.Inventory")
      result = ArchTest.ModuleSet.union(a, b) |> ArchTest.ModuleSet.resolve(g)
      assert FixtureApp.Orders in result
      assert FixtureApp.Inventory in result
      refute FixtureApp.Accounts in result
    end

    test "intersection keeps only matching both" do
      g = graph()
      a = ArchTest.ModuleSet.new("FixtureApp.**")
      b = ArchTest.ModuleSet.new("**.*Repo")
      result = ArchTest.ModuleSet.intersection(a, b) |> ArchTest.ModuleSet.resolve(g)
      assert FixtureApp.Inventory.Repo in result
      assert FixtureApp.Repo.OrderRepo in result
      refute FixtureApp.Orders in result
      refute FixtureApp.Accounts in result
    end

    test "satisfying with custom predicate" do
      g = graph()
      # Select modules that define a struct (have __struct__/0)
      ms =
        ArchTest.ModuleSet.satisfying(fn mod ->
          Code.ensure_loaded(mod)
          function_exported?(mod, :__struct__, 0)
        end)

      result = ArchTest.ModuleSet.resolve(ms, g)
      assert FixtureApp.Inventory.Item in result
      assert FixtureApp.Domain.Order in result
      assert FixtureApp.Accounts.User in result
    end
  end

  # ---------------------------------------------------------------------------
  # Assertions — PASSING cases (real graph, clean rules)
  # ---------------------------------------------------------------------------

  describe "assertions that PASS on the real graph" do
    test "Accounts modules have no deps on Orders" do
      g = graph()

      assert_passes(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Accounts.**")
        |> ArchTest.Assertions.should_not_depend_on(
          ArchTest.ModuleSet.new("FixtureApp.Orders.**"),
          graph: g
        )
      end)
    end

    test "Domain.Order has no deps on Web" do
      g = graph()

      assert_passes(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Domain.Order")
        |> ArchTest.Assertions.should_not_depend_on(
          ArchTest.ModuleSet.new("FixtureApp.Web.**"),
          graph: g
        )
      end)
    end

    test "Repo layer not called by Accounts" do
      g = graph()

      assert_passes(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Repo.*")
        |> ArchTest.Assertions.should_not_be_called_by(
          ArchTest.ModuleSet.new("FixtureApp.Accounts.**"),
          graph: g
        )
      end)
    end

    test "no Manager modules in Accounts context" do
      g = graph()

      assert_passes(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Accounts.**.*Manager")
        |> ArchTest.Assertions.should_not_exist(graph: g)
      end)
    end

    test "Accounts.User resides under FixtureApp.Accounts" do
      g = graph()

      assert_passes(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Accounts.*")
        |> ArchTest.Assertions.should_reside_under("FixtureApp.Accounts.*", graph: g)
      end)
    end

    test "Repo modules match **.*Repo naming" do
      g = graph()

      assert_passes(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Repo.*")
        |> ArchTest.Assertions.should_have_name_matching("**.*Repo", graph: g)
      end)
    end

    test "Accounts context is free of cycles" do
      g = graph()

      assert_passes(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Accounts.**")
        |> ArchTest.Assertions.should_be_free_of_cycles(graph: g)
      end)
    end

    test "Inventory context is free of cycles" do
      g = graph()

      assert_passes(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Inventory.**")
        |> ArchTest.Assertions.should_be_free_of_cycles(graph: g)
      end)
    end

    test "custom satisfying rule passes for OrderManager" do
      g = graph()

      assert_passes(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Orders.OrderManager")
        |> ArchTest.Assertions.satisfying(fn _graph, _mod -> [] end, graph: g)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Assertions — FAILING cases (intentional violations in fixture_app)
  # ---------------------------------------------------------------------------

  describe "assertions that FAIL on the real graph (catching intentional violations)" do
    test "detects Checkout → Inventory.Repo (forbidden dep)" do
      g = graph()

      assert_violation(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Orders.**")
        |> ArchTest.Assertions.should_not_depend_on(
          ArchTest.ModuleSet.new("FixtureApp.Inventory.*"),
          graph: g
        )
      end)
    end

    test "detects OrderService → Repo.OrderRepo (forbidden dep)" do
      g = graph()

      assert_violation(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Orders.**")
        |> ArchTest.Assertions.should_not_depend_on(
          ArchTest.ModuleSet.new("FixtureApp.Repo.*"),
          graph: g
        )
      end)
    end

    test "detects Web.Controller → Repo.OrderRepo (web calling repo directly)" do
      g = graph()

      assert_violation(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Web.**")
        |> ArchTest.Assertions.should_not_depend_on(
          ArchTest.ModuleSet.new("FixtureApp.Repo.*"),
          graph: g
        )
      end)
    end

    test "should_only_depend_on detects Checkout dep outside allowed set" do
      g = graph()

      assert_violation(fn ->
        # Checkout should only depend on Orders internals, but it calls InventoryRepo
        ArchTest.ModuleSet.new("FixtureApp.Orders.*")
        |> ArchTest.Assertions.should_only_depend_on(
          ArchTest.ModuleSet.new("FixtureApp.Orders.**"),
          graph: g
        )
      end)
    end

    test "should_not_be_called_by detects Repo.OrderRepo called by Web" do
      g = graph()

      assert_violation(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Repo.*")
        |> ArchTest.Assertions.should_not_be_called_by(
          ArchTest.ModuleSet.new("FixtureApp.Web.**"),
          graph: g
        )
      end)
    end

    test "should_not_be_called_by detects Repo.OrderRepo called by Orders.OrderService" do
      g = graph()

      assert_violation(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Repo.*")
        |> ArchTest.Assertions.should_not_be_called_by(
          ArchTest.ModuleSet.new("FixtureApp.Orders.**"),
          graph: g
        )
      end)
    end

    test "detects OrderManager (naming violation — *Manager exists)" do
      g = graph()

      assert_violation(fn ->
        ArchTest.ModuleSet.new("FixtureApp.**.*Manager")
        |> ArchTest.Assertions.should_not_exist(graph: g)
      end)
    end

    test "should_reside_under detects Inventory.Repo not in Schemas namespace" do
      g = graph()

      assert_violation(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Inventory.*")
        |> ArchTest.Assertions.should_reside_under("FixtureApp.Inventory.Schemas.*", graph: g)
      end)
    end

    test "should_have_name_matching detects Checkout doesn't end with Service" do
      g = graph()

      assert_violation(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Orders.*")
        |> ArchTest.Assertions.should_have_name_matching("**.*Service", graph: g)
      end)
    end

    test "should_be_free_of_cycles detects CycleA ↔ CycleB" do
      g = graph()

      assert_violation(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Domain.**")
        |> ArchTest.Assertions.should_be_free_of_cycles(graph: g)
      end)
    end

    test "should_not_transitively_depend_on detects Checkout → Inventory.Repo transitively" do
      g = graph()

      assert_violation(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Orders.Checkout")
        |> ArchTest.Assertions.should_not_transitively_depend_on(
          ArchTest.ModuleSet.new("FixtureApp.Inventory.*"),
          graph: g
        )
      end)
    end

    test "violation message contains caller and callee module names" do
      g = graph()

      error =
        assert_raise ExUnit.AssertionError, fn ->
          ArchTest.ModuleSet.new("FixtureApp.Orders.**")
          |> ArchTest.Assertions.should_not_depend_on(
            ArchTest.ModuleSet.new("FixtureApp.Inventory.*"),
            graph: g
          )
        end

      assert error.message =~ "FixtureApp.Orders.Checkout"
      assert error.message =~ "FixtureApp.Inventory.Repo"
    end

    test "violation message includes violation count" do
      g = graph()

      error =
        assert_raise ExUnit.AssertionError, fn ->
          ArchTest.ModuleSet.new("FixtureApp.**")
          |> ArchTest.Assertions.should_not_depend_on(
            ArchTest.ModuleSet.new("FixtureApp.Repo.*"),
            graph: g
          )
        end

      assert error.message =~ "violation"
    end
  end

  # ---------------------------------------------------------------------------
  # Modulith / Bounded Context — real graph
  # ---------------------------------------------------------------------------

  describe "Modulith enforcement on real graph" do
    test "enforce_isolation detects Checkout accessing Inventory internals" do
      g = graph()

      assert_violation(fn ->
        ArchTest.Modulith.define_slices(
          orders: "FixtureApp.Orders",
          inventory: "FixtureApp.Inventory",
          accounts: "FixtureApp.Accounts"
        )
        |> do_enforce_isolation(g)
      end)
    end

    test "allow_dependency(:orders, :accounts) permits Orders → Accounts public root" do
      g = graph()
      # Even with allow_dependency, Checkout → InventoryRepo is still a violation
      error =
        assert_raise ExUnit.AssertionError, fn ->
          ArchTest.Modulith.define_slices(
            orders: "FixtureApp.Orders",
            inventory: "FixtureApp.Inventory",
            accounts: "FixtureApp.Accounts"
          )
          |> ArchTest.Modulith.allow_dependency(:orders, :accounts)
          |> do_enforce_isolation(g)
        end

      # Orders → Accounts should NOT be in violations (it's allowed)
      refute error.message =~ "FixtureApp.Accounts\n"
      # But Checkout → InventoryRepo should still appear
      assert error.message =~ "FixtureApp.Inventory.Repo"
    end

    test "Accounts has no cross-context violations" do
      g = graph()

      assert_passes(fn ->
        ArchTest.Modulith.define_slices(
          orders: "FixtureApp.Orders",
          inventory: "FixtureApp.Inventory",
          accounts: "FixtureApp.Accounts"
        )
        |> ArchTest.Modulith.allow_dependency(:orders, :accounts)
        |> do_enforce_isolation_only_accounts(g)
      end)
    end

    test "slice cycle detection finds no cycles in acyclic slice graph" do
      g = graph()
      # Orders → Accounts, nothing back: no cycle
      assert_passes(fn ->
        ArchTest.Modulith.define_slices(
          orders: "FixtureApp.Orders",
          accounts: "FixtureApp.Accounts"
        )
        |> do_check_slice_cycles(g)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Layers — real graph
  # ---------------------------------------------------------------------------

  describe "Layer direction enforcement on real graph" do
    test "detects Repo.OrderRepo as having no deps on higher layers (repo is bottom)" do
      g = graph()

      assert_passes(fn ->
        # Repo has no deps on Web or Orders
        ArchTest.ModuleSet.new("FixtureApp.Repo.*")
        |> ArchTest.Assertions.should_not_depend_on(
          ArchTest.ModuleSet.new("FixtureApp.Web.**"),
          graph: g
        )
      end)
    end

    test "detects Web.Controller calling Repo directly (upward-skip violation)" do
      # In our layer model: context sits between web and repo.
      # Web should not skip context and call repo directly.
      # We verify this by checking Web doesn't call Repo.
      g = graph()

      assert_violation(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Web.**")
        |> ArchTest.Assertions.should_not_depend_on(
          ArchTest.ModuleSet.new("FixtureApp.Repo.*"),
          graph: g
        )
      end)
    end

    test "Domain.Order is free of any FixtureApp deps (pure domain)" do
      g = graph()

      assert_passes(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Domain.Order")
        |> ArchTest.Assertions.should_not_depend_on(
          ArchTest.ModuleSet.new("FixtureApp.**"),
          graph: g
        )
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Naming convention rules — real graph
  # ---------------------------------------------------------------------------

  describe "naming convention assertions on real graph" do
    test "OrderManager is found by **.*Manager pattern" do
      g = graph()
      ms = ArchTest.ModuleSet.new("FixtureApp.**.*Manager")
      result = ArchTest.ModuleSet.resolve(ms, g)
      assert FixtureApp.Orders.OrderManager in result
    end

    test "OrderService is found by **.*Service pattern" do
      g = graph()
      ms = ArchTest.ModuleSet.new("FixtureApp.**.*Service")
      result = ArchTest.ModuleSet.resolve(ms, g)
      assert FixtureApp.Orders.OrderService in result
    end

    test "all Repo-layer modules end with Repo" do
      g = graph()

      assert_passes(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Repo.*")
        |> ArchTest.Assertions.should_have_name_matching("**.*Repo", graph: g)
      end)
    end

    test "should_not_exist catches OrderManager" do
      g = graph()

      error =
        assert_raise ExUnit.AssertionError, fn ->
          ArchTest.ModuleSet.new("FixtureApp.**.*Manager")
          |> ArchTest.Assertions.should_not_exist(graph: g)
        end

      assert error.message =~ "OrderManager"
    end
  end

  # ---------------------------------------------------------------------------
  # Cycle detection — real graph
  # ---------------------------------------------------------------------------

  describe "cycle detection on real graph" do
    test "detects CycleA ↔ CycleB as a cycle" do
      g = graph()

      error =
        assert_raise ExUnit.AssertionError, fn ->
          ArchTest.ModuleSet.new("FixtureApp.Domain.**")
          |> ArchTest.Assertions.should_be_free_of_cycles(graph: g)
        end

      assert error.message =~ "CycleA" or error.message =~ "CycleB"
    end

    test "full FixtureApp has at least one cycle" do
      g = graph()

      assert_violation(fn ->
        ArchTest.ModuleSet.new("FixtureApp.**")
        |> ArchTest.Assertions.should_be_free_of_cycles(graph: g)
      end)
    end

    test "Order (non-cyclic) module in isolation is cycle-free" do
      g = graph()

      assert_passes(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Domain.Order")
        |> ArchTest.Assertions.should_be_free_of_cycles(graph: g)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Custom satisfying rules — real graph
  # ---------------------------------------------------------------------------

  describe "satisfying/2 custom rules on real graph" do
    test "custom rule that always passes returns :ok" do
      g = graph()

      assert_passes(fn ->
        ArchTest.ModuleSet.new("FixtureApp.**")
        |> ArchTest.Assertions.satisfying(fn _graph, _mod -> [] end, graph: g)
      end)
    end

    test "custom rule that always fails raises" do
      g = graph()

      assert_violation(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Orders")
        |> ArchTest.Assertions.satisfying(
          fn _graph, mod ->
            [%ArchTest.Violation{type: :custom, module: mod, message: "always fails"}]
          end,
          graph: g
        )
      end)
    end

    test "custom rule checking for struct modules" do
      g = graph()
      # All modules in Accounts.** should NOT define a struct if they're the root
      root_non_structs = [FixtureApp.Accounts]

      assert_passes(fn ->
        ArchTest.ModuleSet.new("FixtureApp.Accounts")
        |> ArchTest.Assertions.satisfying(
          fn _graph, mod ->
            if mod in root_non_structs and function_exported?(mod, :__struct__, 0) do
              [
                %ArchTest.Violation{
                  type: :custom,
                  module: mod,
                  message: "root should not be struct"
                }
              ]
            else
              []
            end
          end,
          graph: g
        )
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Metrics — real graph
  # ---------------------------------------------------------------------------

  describe "Metrics on real graph" do
    test "instability of Repo.OrderRepo is 0.0 (nobody inside fixture depends on it except callers outside)" do
      g = graph()
      # Repo.OrderRepo has no efferent coupling within FixtureApp
      # (it calls nobody in FixtureApp), so Ce=0 → instability=0
      metrics = ArchTest.Metrics.coupling(FixtureApp.Repo.OrderRepo, graph: g)
      assert metrics.efferent == 0
      assert metrics.instability == 0.0
    end

    test "Checkout has positive efferent coupling (calls InventoryRepo)" do
      g = graph()
      metrics = ArchTest.Metrics.coupling(FixtureApp.Orders.Checkout, graph: g)
      assert metrics.efferent > 0
    end

    test "instability is between 0 and 1" do
      g = graph()
      all_metrics = ArchTest.Metrics.martin("FixtureApp.**", graph: g)

      Enum.each(all_metrics, fn {_mod, m} ->
        assert m.instability >= 0.0
        assert m.instability <= 1.0
      end)
    end

    test "martin/1 returns metrics for all FixtureApp descendants (20 — root excluded by **)" do
      g = graph()
      all_metrics = ArchTest.Metrics.martin("FixtureApp.**", graph: g)
      # FixtureApp.** matches 20 modules (excludes FixtureApp root)
      assert map_size(all_metrics) == 20
    end

    test "distance is between 0 and 1" do
      g = graph()
      all_metrics = ArchTest.Metrics.martin("FixtureApp.**", graph: g)

      Enum.each(all_metrics, fn {_mod, m} ->
        assert m.distance >= 0.0
        assert m.distance <= 1.0
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Freeze — real graph
  # ---------------------------------------------------------------------------

  describe "Freeze with real violations" do
    @tag :tmp_dir
    test "freeze captures real violations and compares to empty baseline", %{tmp_dir: tmp_dir} do
      Application.put_env(:arch_test, :freeze_store, tmp_dir)

      on_exit(fn -> Application.delete_env(:arch_test, :freeze_store) end)

      g = graph()

      # First run with no baseline: all violations are "new" → test fails
      assert_violation(fn ->
        ArchTest.Freeze.freeze("checkout_violation", fn ->
          ArchTest.ModuleSet.new("FixtureApp.Orders.**")
          |> ArchTest.Assertions.should_not_depend_on(
            ArchTest.ModuleSet.new("FixtureApp.Inventory.*"),
            graph: g
          )
        end)
      end)
    end

    @tag :tmp_dir
    test "freeze passes when assertion has no violations", %{tmp_dir: tmp_dir} do
      Application.put_env(:arch_test, :freeze_store, tmp_dir)
      on_exit(fn -> Application.delete_env(:arch_test, :freeze_store) end)

      g = graph()

      # No violations → freeze passes immediately
      result =
        ArchTest.Freeze.freeze("no_violations_rule", fn ->
          ArchTest.ModuleSet.new("FixtureApp.Accounts.**")
          |> ArchTest.Assertions.should_not_depend_on(
            ArchTest.ModuleSet.new("FixtureApp.Orders.**"),
            graph: g
          )
        end)

      assert result == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Full DSL pipeline — use ArchTest macro
  # ---------------------------------------------------------------------------

  describe "full DSL via use ArchTest (macro pipeline)" do
    test "modules_matching resolves against real graph" do
      g = graph()
      ms = ArchTest.modules_matching("FixtureApp.Orders.*")
      result = ArchTest.ModuleSet.resolve(ms, g)
      assert length(result) == 3
      assert FixtureApp.Orders.Checkout in result
    end

    test "all_modules resolves all 21 fixture modules" do
      g = graph()
      ms = ArchTest.all_modules()
      result = ArchTest.ModuleSet.resolve(ms, g)
      # all_modules() uses "**" which matches single-segment names too
      assert length(result) == 21
    end

    test "modules_in resolves direct children" do
      g = graph()
      ms = ArchTest.modules_in("FixtureApp.Inventory")
      result = ArchTest.ModuleSet.resolve(ms, g)
      assert FixtureApp.Inventory.Repo in result
      assert FixtureApp.Inventory.Item in result
      refute FixtureApp.Inventory in result
    end

    test "excluding composes correctly" do
      g = graph()

      result =
        ArchTest.modules_matching("FixtureApp.Orders.*")
        |> ArchTest.excluding("FixtureApp.Orders.OrderManager")
        |> ArchTest.ModuleSet.resolve(g)

      refute FixtureApp.Orders.OrderManager in result
      assert FixtureApp.Orders.Checkout in result
    end

    test "union combines two sets" do
      g = graph()

      result =
        ArchTest.modules_matching("FixtureApp.Orders")
        |> ArchTest.union(ArchTest.modules_matching("FixtureApp.Accounts"))
        |> ArchTest.ModuleSet.resolve(g)

      assert FixtureApp.Orders in result
      assert FixtureApp.Accounts in result
      assert length(result) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Pattern matching edge cases verified against real module names
  # ---------------------------------------------------------------------------

  describe "Pattern matching edge cases on real module names" do
    test "** matches FixtureApp itself (single segment)" do
      assert ArchTest.Pattern.matches?("FixtureApp", "FixtureApp")
    end

    test "FixtureApp.** matches all descendants" do
      mods = [
        "FixtureApp.Orders",
        "FixtureApp.Orders.Checkout",
        "FixtureApp.Domain.CycleA"
      ]

      Enum.each(mods, fn m ->
        assert ArchTest.Pattern.matches?("FixtureApp.**", m),
               "Expected #{m} to match FixtureApp.**"
      end)
    end

    test "FixtureApp.** does not match FixtureApp itself" do
      refute ArchTest.Pattern.matches?("FixtureApp.**", "FixtureApp")
    end

    test "**.*Manager matches OrderManager" do
      assert ArchTest.Pattern.matches?("**.*Manager", "FixtureApp.Orders.OrderManager")
    end

    test "**.*Service matches OrderService but not OrderManager" do
      assert ArchTest.Pattern.matches?("**.*Service", "FixtureApp.Orders.OrderService")
      refute ArchTest.Pattern.matches?("**.*Service", "FixtureApp.Orders.OrderManager")
    end

    test "**.*Repo matches both Repo modules" do
      assert ArchTest.Pattern.matches?("**.*Repo", "FixtureApp.Inventory.Repo")
      assert ArchTest.Pattern.matches?("**.*Repo", "FixtureApp.Repo.OrderRepo")
    end

    test "FixtureApp.**.*Repo matches nested Repo modules" do
      assert ArchTest.Pattern.matches?("FixtureApp.**.*Repo", "FixtureApp.Inventory.Repo")
      assert ArchTest.Pattern.matches?("FixtureApp.**.*Repo", "FixtureApp.Repo.OrderRepo")
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp assert_passes(f) do
    result = f.()
    assert result == :ok
  end

  defp assert_violation(f) do
    assert_raise ExUnit.AssertionError, f
  end

  # Thin wrappers that avoid calling into xref (use pre-built graph)
  defp do_enforce_isolation(%ArchTest.Modulith{} = m, graph) do
    slice_info = build_slice_info(m.slices, graph)

    violations =
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
            ArchTest.Violation.forbidden_dep(
              caller,
              dep,
              "#{inspect(caller_slice)} must not access internals of #{inspect(dep_slice)}"
            )

          not allowed ->
            ArchTest.Violation.forbidden_dep(
              caller,
              dep,
              "cross-slice dep without allow_dependency"
            )

          true ->
            nil
        end
      end
      |> Enum.reject(&is_nil/1)

    ArchTest.Assertions.assert_no_violations_public(violations, "enforce_isolation")
  end

  defp do_enforce_isolation_only_accounts(%ArchTest.Modulith{} = m, graph) do
    slice_info = build_slice_info(m.slices, graph)

    violations =
      for caller <- slice_all_modules("FixtureApp.Accounts", graph),
          dep <- ArchTest.Collector.dependencies_of(graph, caller),
          {dep_slice, dep_root} = find_slice(dep, slice_info),
          dep_slice != nil,
          dep_slice != :accounts do
        is_root = dep == dep_root
        allowed = {:accounts, dep_slice} in m.allowed_deps

        cond do
          not is_root -> ArchTest.Violation.forbidden_dep(caller, dep, "internal access")
          not allowed -> ArchTest.Violation.forbidden_dep(caller, dep, "cross-slice")
          true -> nil
        end
      end
      |> Enum.reject(&is_nil/1)

    ArchTest.Assertions.assert_no_violations_public(violations, "enforce_isolation_accounts")
  end

  defp do_check_slice_cycles(%ArchTest.Modulith{} = m, graph) do
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
          |> Enum.reject(&is_nil/1)
          |> Enum.reject(&(&1 == slice_name))
          |> Enum.uniq()

        Map.put(acc, slice_name, dep_slices)
      end)

    cycles = ArchTest.Collector.cycles(slice_graph)

    violations =
      Enum.map(cycles, fn cycle ->
        ArchTest.Violation.cycle(cycle, "cycle between bounded contexts")
      end)

    ArchTest.Assertions.assert_no_violations_public(violations, "should_be_free_of_cycles")
  end

  defp slice_all_modules(root_namespace, graph) do
    children_pattern = "#{root_namespace}.**"

    Enum.filter(Map.keys(graph), fn mod ->
      mod_str =
        mod
        |> Atom.to_string()
        |> then(fn s ->
          if String.starts_with?(s, "Elixir."), do: String.slice(s, 7..-1//1), else: s
        end)

      ArchTest.Pattern.matches?(children_pattern, mod_str) or
        ArchTest.Pattern.matches?(root_namespace, mod_str)
    end)
  end

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
end
