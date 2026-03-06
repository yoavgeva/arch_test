defmodule ArchTest.ModuleSetTest do
  use ExUnit.Case, async: true

  alias ArchTest.ModuleSet

  # A small in-memory graph for testing resolution without xref
  @graph %{
    FixtureApp.Orders => [FixtureApp.Accounts],
    FixtureApp.Orders.Checkout => [FixtureApp.Inventory.Repo],
    FixtureApp.Orders.OrderService => [FixtureApp.Repo.OrderRepo],
    FixtureApp.Inventory => [],
    FixtureApp.Inventory.Repo => [],
    FixtureApp.Accounts => [],
    FixtureApp.Web.Controller => [FixtureApp.Repo.OrderRepo],
    FixtureApp.Repo.OrderRepo => [],
    FixtureApp.Domain.Order => [],
    FixtureApp.Domain.CycleA => [FixtureApp.Domain.CycleB],
    FixtureApp.Domain.CycleB => [FixtureApp.Domain.CycleA]
  }

  describe "new/1" do
    test "creates a ModuleSet from a single pattern" do
      ms = ModuleSet.new("FixtureApp.Orders.*")
      assert ms.include_patterns == ["FixtureApp.Orders.*"]
    end

    test "creates a ModuleSet from multiple patterns" do
      ms = ModuleSet.new(["FixtureApp.Orders.*", "FixtureApp.Inventory.*"])
      assert length(ms.include_patterns) == 2
    end
  end

  describe "resolve/2" do
    test "resolves direct children" do
      ms = ModuleSet.new("FixtureApp.Orders.*")
      result = ModuleSet.resolve(ms, @graph)
      assert FixtureApp.Orders.Checkout in result
      assert FixtureApp.Orders.OrderService in result
      refute FixtureApp.Orders in result
      refute FixtureApp.Inventory in result
    end

    test "resolves all descendants" do
      ms = ModuleSet.new("FixtureApp.**")
      result = ModuleSet.resolve(ms, @graph)
      assert length(result) == map_size(@graph)
    end

    test "resolves exact match" do
      ms = ModuleSet.new("FixtureApp.Orders")
      result = ModuleSet.resolve(ms, @graph)
      assert result == [FixtureApp.Orders]
    end

    test "all() resolves everything" do
      ms = ModuleSet.all()
      result = ModuleSet.resolve(ms, @graph)
      assert length(result) == map_size(@graph)
    end
  end

  describe "excluding/2" do
    test "excludes matching modules" do
      ms =
        ModuleSet.new("FixtureApp.Orders.*")
        |> ModuleSet.excluding("FixtureApp.Orders.Checkout")

      result = ModuleSet.resolve(ms, @graph)
      refute FixtureApp.Orders.Checkout in result
      assert FixtureApp.Orders.OrderService in result
    end
  end

  describe "union/2" do
    test "combines two sets" do
      a = ModuleSet.new("FixtureApp.Orders")
      b = ModuleSet.new("FixtureApp.Inventory")
      ms = ModuleSet.union(a, b)
      result = ModuleSet.resolve(ms, @graph)
      assert FixtureApp.Orders in result
      assert FixtureApp.Inventory in result
    end
  end

  describe "intersection/2" do
    test "returns modules matching both sets" do
      # All FixtureApp modules intersected with modules ending in Repo
      a = ModuleSet.new("FixtureApp.**")
      b = ModuleSet.new("**.*Repo")
      ms = ModuleSet.intersection(a, b)
      result = ModuleSet.resolve(ms, @graph)
      assert FixtureApp.Inventory.Repo in result
      assert FixtureApp.Repo.OrderRepo in result
      refute FixtureApp.Orders in result
    end
  end

  describe "satisfying/1" do
    test "filters by custom predicate" do
      ms = ModuleSet.satisfying(fn mod -> String.contains?(Atom.to_string(mod), "Cycle") end)
      result = ModuleSet.resolve(ms, @graph)
      assert FixtureApp.Domain.CycleA in result
      assert FixtureApp.Domain.CycleB in result
      refute FixtureApp.Orders in result
    end

    test "always-false predicate returns empty list" do
      ms = ModuleSet.satisfying(fn _mod -> false end)
      assert ModuleSet.resolve(ms, @graph) == []
    end

    test "always-true predicate returns all modules" do
      ms = ModuleSet.satisfying(fn _mod -> true end)
      result = ModuleSet.resolve(ms, @graph)
      assert length(result) == map_size(@graph)
    end
  end

  describe "union/2 correctness" do
    test "union includes modules from either set" do
      a = ModuleSet.new("FixtureApp.Orders")
      b = ModuleSet.new("FixtureApp.Accounts")
      ms = ModuleSet.union(a, b)
      result = ModuleSet.resolve(ms, @graph)
      assert FixtureApp.Orders in result
      assert FixtureApp.Accounts in result
      refute FixtureApp.Inventory in result
    end

    test "union respects exclusions from each set independently" do
      # Set A: Orders.* excluding Checkout
      a =
        ModuleSet.new("FixtureApp.Orders.*") |> ModuleSet.excluding("FixtureApp.Orders.Checkout")

      # Set B: Inventory.*
      b = ModuleSet.new("FixtureApp.Inventory.*")
      ms = ModuleSet.union(a, b)
      result = ModuleSet.resolve(ms, @graph)

      # Checkout is excluded from A, and B doesn't include it → should not appear
      refute FixtureApp.Orders.Checkout in result
      # OrderService is in A and not excluded → should appear
      assert FixtureApp.Orders.OrderService in result
      # Inventory.Repo is in B → should appear
      assert FixtureApp.Inventory.Repo in result
    end

    test "union with custom_filter preserves filters from both sets" do
      a = ModuleSet.satisfying(fn mod -> mod == FixtureApp.Orders end)
      b = ModuleSet.satisfying(fn mod -> mod == FixtureApp.Accounts end)
      ms = ModuleSet.union(a, b)
      result = ModuleSet.resolve(ms, @graph)
      assert FixtureApp.Orders in result
      assert FixtureApp.Accounts in result
      refute FixtureApp.Inventory in result
    end

    test "union of disjoint sets has no overlap exclusion effect" do
      # BUG 6 regression: A excludes X, B includes X — X should appear in union
      a =
        ModuleSet.new("FixtureApp.Orders.*") |> ModuleSet.excluding("FixtureApp.Orders.Checkout")

      b = ModuleSet.new("FixtureApp.Orders.Checkout")
      ms = ModuleSet.union(a, b)
      result = ModuleSet.resolve(ms, @graph)
      # Checkout is excluded from A but explicitly included in B → should appear
      assert FixtureApp.Orders.Checkout in result
    end
  end

  describe "intersection/2 correctness" do
    test "intersection returns only modules in both sets" do
      a = ModuleSet.new("FixtureApp.**")
      b = ModuleSet.new("**.*Repo")
      ms = ModuleSet.intersection(a, b)
      result = ModuleSet.resolve(ms, @graph)
      assert FixtureApp.Inventory.Repo in result
      assert FixtureApp.Repo.OrderRepo in result
      refute FixtureApp.Orders in result
      refute FixtureApp.Accounts in result
    end

    test "intersection with custom_filter" do
      a = ModuleSet.new("FixtureApp.**")
      b = ModuleSet.satisfying(fn mod -> String.contains?(Atom.to_string(mod), "Cycle") end)
      ms = ModuleSet.intersection(a, b)
      result = ModuleSet.resolve(ms, @graph)
      assert FixtureApp.Domain.CycleA in result
      assert FixtureApp.Domain.CycleB in result
      refute FixtureApp.Orders in result
    end

    test "intersection of disjoint sets is empty" do
      a = ModuleSet.new("FixtureApp.Orders.*")
      b = ModuleSet.new("FixtureApp.Accounts")
      ms = ModuleSet.intersection(a, b)
      result = ModuleSet.resolve(ms, @graph)
      assert result == []
    end
  end

  describe "edge cases" do
    test "resolve against empty graph returns empty list" do
      ms = ModuleSet.new("MyApp.**")
      assert ModuleSet.resolve(ms, %{}) == []
    end

    test "in_namespace/1 returns direct children" do
      ms = ModuleSet.in_namespace("FixtureApp.Orders")
      result = ModuleSet.resolve(ms, @graph)
      assert FixtureApp.Orders.Checkout in result
      assert FixtureApp.Orders.OrderService in result
      refute FixtureApp.Orders in result
    end

    test "excluding with list of patterns" do
      ms =
        ModuleSet.new("FixtureApp.Orders.*")
        |> ModuleSet.excluding(["FixtureApp.Orders.Checkout", "FixtureApp.Orders.OrderService"])

      result = ModuleSet.resolve(ms, @graph)
      assert result == []
    end

    test "excluding a non-matching pattern has no effect" do
      ms =
        ModuleSet.new("FixtureApp.Orders.*")
        |> ModuleSet.excluding("FixtureApp.Web.*")

      result = ModuleSet.resolve(ms, @graph)
      assert FixtureApp.Orders.Checkout in result
      assert FixtureApp.Orders.OrderService in result
    end
  end

  describe "excluding/2 — additional edge cases" do
    test "excluding the entire subject results in empty list" do
      ms =
        ModuleSet.new("FixtureApp.Orders.*")
        |> ModuleSet.excluding("FixtureApp.Orders.*")

      result = ModuleSet.resolve(ms, @graph)
      assert result == []
    end

    test "chained excludes: both patterns are excluded" do
      ms =
        ModuleSet.new("FixtureApp.Orders.*")
        |> ModuleSet.excluding("FixtureApp.Orders.Checkout")
        |> ModuleSet.excluding("FixtureApp.Orders.OrderService")

      result = ModuleSet.resolve(ms, @graph)
      assert result == []
    end

    test "excluding a pattern that matches nothing does not affect result" do
      ms =
        ModuleSet.new("FixtureApp.Orders.*")
        |> ModuleSet.excluding("NonExistent.Module.*")

      result = ModuleSet.resolve(ms, @graph)
      assert FixtureApp.Orders.Checkout in result
      assert FixtureApp.Orders.OrderService in result
    end
  end

  describe "union/2 — additional edge cases" do
    test "union of identical sets equals the original set" do
      a = ModuleSet.new("FixtureApp.Orders.*")
      ms = ModuleSet.union(a, a)
      result = ModuleSet.resolve(ms, @graph)

      original = ModuleSet.resolve(a, @graph)
      assert Enum.sort(result) == Enum.sort(original)
    end

    test "union where one set has custom_filter and other does not" do
      a = ModuleSet.new("FixtureApp.Orders")
      b = ModuleSet.satisfying(fn mod -> mod == FixtureApp.Inventory end)
      ms = ModuleSet.union(a, b)
      result = ModuleSet.resolve(ms, @graph)

      assert FixtureApp.Orders in result
      assert FixtureApp.Inventory in result
      refute FixtureApp.Accounts in result
    end
  end

  describe "intersection/2 — additional edge cases" do
    test "intersection of disjoint sets returns empty list" do
      a = ModuleSet.new("FixtureApp.Orders")
      b = ModuleSet.new("FixtureApp.Inventory")
      ms = ModuleSet.intersection(a, b)
      result = ModuleSet.resolve(ms, @graph)
      assert result == []
    end

    test "intersection of identical sets returns the same modules as original" do
      a = ModuleSet.new("FixtureApp.Orders.*")
      ms = ModuleSet.intersection(a, a)
      result = ModuleSet.resolve(ms, @graph)

      original = ModuleSet.resolve(a, @graph)
      assert Enum.sort(result) == Enum.sort(original)
    end
  end

  describe "satisfying/1 — additional edge cases" do
    test "filter fn that raises propagates the exception during resolve" do
      ms = ModuleSet.satisfying(fn _mod -> raise "boom" end)

      assert_raise RuntimeError, "boom", fn ->
        ModuleSet.resolve(ms, @graph)
      end
    end

    test "filter fn returning nil (falsy) excludes the module" do
      ms = ModuleSet.satisfying(fn _mod -> nil end)
      result = ModuleSet.resolve(ms, @graph)
      assert result == []
    end

    test "filter fn returning a truthy non-boolean value includes the module" do
      ms = ModuleSet.satisfying(fn _mod -> :yes end)
      result = ModuleSet.resolve(ms, @graph)
      assert length(result) == map_size(@graph)
    end
  end

  describe "resolve/2 — additional edge cases" do
    test "custom_filter receives module atoms" do
      received = :ets.new(:test_received, [:set, :public])

      ms =
        ModuleSet.satisfying(fn mod ->
          :ets.insert(received, {mod})
          true
        end)

      result = ModuleSet.resolve(ms, @graph)

      # Every module in the graph should have been passed to the filter
      all_mods = Map.keys(@graph)

      for mod <- all_mods do
        assert :ets.lookup(received, mod) == [{mod}],
               "Expected custom_filter to be called with #{inspect(mod)}"
      end

      assert length(result) == length(all_mods)
      :ets.delete(received)
    end

    test "works with a large graph (1000+ modules)" do
      # Build a graph with 1000 synthetic module atoms
      large_graph =
        for i <- 1..1000, into: %{} do
          mod = String.to_atom("Elixir.LargeApp.Module#{i}")
          deps = if i > 1, do: [String.to_atom("Elixir.LargeApp.Module#{i - 1}")], else: []
          {mod, deps}
        end

      ms = ModuleSet.new("LargeApp.**")
      result = ModuleSet.resolve(ms, large_graph)
      assert length(result) == 1000
    end
  end
end
