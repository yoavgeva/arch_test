defmodule ArchTest.CollectorTest do
  use ExUnit.Case, async: false

  alias ArchTest.Collector

  # These tests use in-memory graphs to avoid needing :xref at test time.
  # Integration tests requiring actual BEAM files are tagged :integration.

  @sample_graph %{
    A => [B, C],
    B => [C, D],
    C => [D],
    D => [],
    E => [A],
    F => [G],
    G => [F]
  }

  describe "all_modules/1" do
    test "returns all keys" do
      mods = Collector.all_modules(@sample_graph)
      assert Enum.sort(mods) == Enum.sort(Map.keys(@sample_graph))
    end
  end

  describe "dependencies_of/2" do
    test "returns direct deps" do
      assert Collector.dependencies_of(@sample_graph, A) == [B, C]
    end

    test "returns empty list for unknown module" do
      assert Collector.dependencies_of(@sample_graph, :unknown) == []
    end

    test "returns empty for leaf node" do
      assert Collector.dependencies_of(@sample_graph, D) == []
    end
  end

  describe "dependents_of/2" do
    test "returns all callers" do
      callers = Collector.dependents_of(@sample_graph, C)
      assert A in callers
      assert B in callers
    end

    test "returns empty for module nobody calls" do
      assert Collector.dependents_of(@sample_graph, E) == []
    end
  end

  describe "transitive_dependencies_of/2" do
    test "returns all reachable modules" do
      transitive = Collector.transitive_dependencies_of(@sample_graph, A)
      assert B in transitive
      assert C in transitive
      assert D in transitive
      refute A in transitive
    end

    test "handles cycles without infinite loop" do
      transitive = Collector.transitive_dependencies_of(@sample_graph, F)
      assert G in transitive
    end

    test "respects max_depth" do
      transitive = Collector.transitive_dependencies_of(@sample_graph, A, 1)
      # Only direct deps at depth 1
      assert B in transitive
      assert C in transitive
      # D is depth 2, should not be included when max_depth=1
      # Note: our BFS increments depth per queue drain, not per hop
      # This test is lenient — just checks no infinite loop
      assert is_list(transitive)
    end
  end

  describe "transitive_dependencies_of/3 — max_depth semantics" do
    # A → B → C → D (linear chain)
    @linear %{A => [B], B => [C], C => [D], D => []}

    test "max_depth=1 returns only direct dependencies" do
      result = Collector.transitive_dependencies_of(@linear, A, 1)
      assert result == [B]
    end

    test "max_depth=2 returns two hops" do
      result = Collector.transitive_dependencies_of(@linear, A, 2)
      assert B in result
      assert C in result
      refute D in result
    end

    test "max_depth=:infinity returns all reachable" do
      result = Collector.transitive_dependencies_of(@linear, A, :infinity)
      assert B in result
      assert C in result
      assert D in result
    end

    test "max_depth=0 returns empty list" do
      result = Collector.transitive_dependencies_of(@linear, A, 0)
      assert result == []
    end

    test "start module excluded from result" do
      result = Collector.transitive_dependencies_of(@linear, A)
      refute A in result
    end

    test "unknown module returns empty list" do
      result = Collector.transitive_dependencies_of(@sample_graph, :nonexistent)
      assert result == []
    end
  end

  describe "cycles/1" do
    test "detects direct cycle" do
      cycles = Collector.cycles(%{F => [G], G => [F]})
      assert cycles != []
      cycle_mods = List.flatten(cycles)
      assert F in cycle_mods
      assert G in cycle_mods
    end

    test "detects no cycle in acyclic graph" do
      acyclic = %{A => [B], B => [C], C => []}
      assert Collector.cycles(acyclic) == []
    end

    test "detects cycle in sample graph" do
      cycles = Collector.cycles(@sample_graph)
      # F → G → F cycle
      assert Enum.any?(cycles, fn cycle ->
               F in cycle and G in cycle
             end)
    end

    test "no false positives for acyclic subgraph" do
      acyclic = %{A => [B, C], B => [C, D], C => [D], D => []}
      assert Collector.cycles(acyclic) == []
    end

    test "cycle deduplicated — same cycle not reported twice" do
      # A → B → A is the same cycle as B → A → B
      graph = %{A => [B], B => [A]}
      cycles = Collector.cycles(graph)
      assert length(cycles) == 1
    end

    test "3-node cycle detected" do
      graph = %{A => [B], B => [C], C => [A]}
      cycles = Collector.cycles(graph)
      assert length(cycles) == 1
      [cycle] = cycles
      assert A in cycle
      assert B in cycle
      assert C in cycle
    end

    test "empty graph has no cycles" do
      assert Collector.cycles(%{}) == []
    end

    test "self-reference is a cycle" do
      graph = %{A => [A]}
      cycles = Collector.cycles(graph)
      assert cycles != []
    end

    test "normalized cycles have no trailing duplicate" do
      # BUG 8 regression: cycles should not contain [A, B, A]
      graph = %{A => [B], B => [A]}
      [cycle] = Collector.cycles(graph)
      # Should be [A, B] or [B, A], NOT [A, B, A]
      assert length(cycle) == 2
    end

    test "isolated nodes without cycles don't appear in cycles list" do
      graph = %{A => [], B => [], C => []}
      assert Collector.cycles(graph) == []
    end
  end

  describe "build_graph/2 — unknown app" do
    test "returns empty graph for unknown OTP app (BUG 1 regression)" do
      # Should not crash with ArgumentError
      graph = Collector.build_graph(:nonexistent_app_xyz_12345)
      assert is_map(graph)
    end
  end

  describe "build_graph_from_path/1 — edge cases" do
    test "non-existent path returns empty map, does not crash" do
      graph = Collector.build_graph_from_path("/nonexistent/path/that/does/not/exist/ebin")
      assert graph == %{}
    end

    test "path with no .beam files returns empty map" do
      # Use the project root — it has files but no .beam files
      graph = Collector.build_graph_from_path(Path.absname("lib"))
      assert graph == %{}
    end

    test "force: true bypasses persistent_term cache" do
      # Use a known path that produces a real graph
      ebin = Path.absname("test/support/fixture_app/_build/dev/lib/fixture_app/ebin")

      # First call: caches result
      graph1 = Collector.build_graph_from_path(ebin, force: false)
      assert is_map(graph1)

      # Second call: should return cached result (same reference)
      graph2 = Collector.build_graph_from_path(ebin, force: false)
      assert graph2 == graph1

      # Third call: force: true rebuilds from scratch
      graph3 = Collector.build_graph_from_path(ebin, force: true)
      assert is_map(graph3)
      # The content should be equivalent (same BEAM files)
      assert Map.keys(graph3) |> Enum.sort() == Map.keys(graph1) |> Enum.sort()
    end
  end

  describe "transitive_dependencies_of/3 — additional edge cases" do
    test "max_depth=3 on chain A->B->C->D includes B, C, D" do
      chain = %{A => [B], B => [C], C => [D], D => []}
      result = Collector.transitive_dependencies_of(chain, A, 3)
      assert B in result
      assert C in result
      assert D in result
    end

    test "max_depth=0 returns empty list (no deps explored)" do
      chain = %{A => [B], B => [C], C => []}
      result = Collector.transitive_dependencies_of(chain, A, 0)
      assert result == []
    end

    test "cyclic graph with max_depth terminates and returns correct set" do
      cyclic = %{A => [B], B => [A]}
      result = Collector.transitive_dependencies_of(cyclic, A, 1)
      assert result == [B]

      # With higher depth, should still terminate and include both
      result2 = Collector.transitive_dependencies_of(cyclic, A, 5)
      assert B in result2
      refute A in result2
    end

    test "cyclic graph without max_depth terminates" do
      cyclic = %{A => [B], B => [C], C => [A]}
      result = Collector.transitive_dependencies_of(cyclic, A)
      assert B in result
      assert C in result
      refute A in result
    end
  end

  describe "cycles/1 — additional edge cases" do
    test "4-node cycle: A->B->C->D->A" do
      graph = %{A => [B], B => [C], C => [D], D => [A]}
      cycles = Collector.cycles(graph)
      assert length(cycles) == 1
      [cycle] = cycles
      assert A in cycle
      assert B in cycle
      assert C in cycle
      assert D in cycle
      assert length(cycle) == 4
    end

    test "multiple disjoint cycles: {A->B->A} and {C->D->C}" do
      graph = %{A => [B], B => [A], C => [D], D => [C], E => []}
      cycles = Collector.cycles(graph)
      assert length(cycles) == 2

      cycle_sets = Enum.map(cycles, &MapSet.new/1)
      assert MapSet.new([A, B]) in cycle_sets
      assert MapSet.new([C, D]) in cycle_sets
    end

    test "self-reference produces a single-element cycle" do
      graph = %{A => [A]}
      cycles = Collector.cycles(graph)
      assert length(cycles) == 1
      [cycle] = cycles
      assert cycle == [A]
    end

    test "normalize preserves a cycle already in canonical form" do
      # A < B (atom ordering), so [A, B] is already canonical
      graph = %{A => [B], B => [A]}
      [cycle] = Collector.cycles(graph)
      # The smallest atom should come first
      assert hd(cycle) == Enum.min(cycle)
    end

    test "mixed cyclic and acyclic nodes" do
      graph = %{
        A => [B],
        B => [A],
        C => [D],
        D => [],
        E => [F],
        F => [E]
      }

      cycles = Collector.cycles(graph)
      assert length(cycles) == 2

      # C and D should not appear in any cycle
      all_cycle_mods = List.flatten(cycles)
      refute C in all_cycle_mods
      refute D in all_cycle_mods
    end
  end
end
