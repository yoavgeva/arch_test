defmodule ArchTest.MetricsTest do
  use ExUnit.Case, async: true

  alias ArchTest.Metrics

  # A small in-memory graph for testing without xref.
  # Layout:
  #   Web.Controller  → [App.Service]
  #   App.Service     → [Repo.OrderRepo]
  #   Repo.OrderRepo  → []
  #   Standalone      → []
  @graph %{
    :"Web.Controller" => [:"App.Service"],
    :"App.Service" => [:"Repo.OrderRepo"],
    :"Repo.OrderRepo" => [],
    :Standalone => []
  }

  defp opts, do: [graph: @graph]

  describe "coupling/2 with injected graph" do
    test "Ca=0, Ce=1 for a module depending on one external (Repo.OrderRepo)" do
      # App.Service is called by Web.Controller (Ca=1) and calls Repo.OrderRepo (Ce=1)
      metrics = Metrics.coupling(:"App.Service", opts())
      # Ca: Web.Controller depends on App.Service → Ca=1
      assert metrics.afferent == 1
      # Ce: App.Service depends on Repo.OrderRepo → Ce=1
      assert metrics.efferent == 1
      assert_in_delta metrics.instability, 0.5, 0.001
    end

    test "Ca=1, Ce=0 for a leaf module (Repo.OrderRepo)" do
      # Repo.OrderRepo is called by App.Service (Ca=1), depends on nothing (Ce=0)
      metrics = Metrics.coupling(:"Repo.OrderRepo", opts())
      assert metrics.afferent == 1
      assert metrics.efferent == 0
      assert_in_delta metrics.instability, 0.0, 0.001
    end

    test "Ca=0, Ce=0 for an isolated module" do
      metrics = Metrics.coupling(:Standalone, opts())
      assert metrics.afferent == 0
      assert metrics.efferent == 0
      assert_in_delta metrics.instability, 0.0, 0.001
    end

    test "instability=1.0 for module with only outward deps and no callers" do
      # Web.Controller depends on App.Service but nobody calls it
      metrics = Metrics.coupling(:"Web.Controller", opts())
      assert metrics.afferent == 0
      assert metrics.efferent == 1
      assert_in_delta metrics.instability, 1.0, 0.001
    end
  end

  describe "instability/2" do
    test "returns instability value directly" do
      i = Metrics.instability(:"Repo.OrderRepo", opts())
      assert_in_delta i, 0.0, 0.001
    end

    test "unstable module has instability close to 1.0" do
      i = Metrics.instability(:"Web.Controller", opts())
      assert_in_delta i, 1.0, 0.001
    end
  end

  describe "abstractness/2" do
    test "concrete module has abstractness 0.0" do
      a = Metrics.abstractness(:"Repo.OrderRepo", opts())
      assert_in_delta a, 0.0, 0.001
    end
  end

  describe "martin/2" do
    test "returns a map of module => metrics" do
      result = Metrics.martin("**", opts())
      assert is_map(result)
    end

    test "result keys are module atoms" do
      result = Metrics.martin("**", opts())
      keys = Map.keys(result)
      assert Enum.all?(keys, &is_atom/1)
    end

    test "each metric map has required fields" do
      result = Metrics.martin("**", opts())

      for {_mod, m} <- result do
        assert Map.has_key?(m, :afferent)
        assert Map.has_key?(m, :efferent)
        assert Map.has_key?(m, :instability)
        assert Map.has_key?(m, :abstractness)
        assert Map.has_key?(m, :distance)
      end
    end

    test "instability is in [0.0, 1.0] range" do
      result = Metrics.martin("**", opts())

      for {_mod, m} <- result do
        assert m.instability >= 0.0
        assert m.instability <= 1.0
      end
    end

    test "distance is |A + I - 1|" do
      result = Metrics.martin("**", opts())

      for {_mod, m} <- result do
        expected = abs(m.abstractness + m.instability - 1.0)
        assert_in_delta m.distance, expected, 0.001
      end
    end

    test "empty pattern returns empty map" do
      # A pattern that matches no modules
      result = Metrics.martin("NoSuchNamespace.**", opts())
      assert result == %{}
    end
  end

  describe "coupling/2 — aggregate package metrics" do
    test "binary pattern computes aggregate package metrics" do
      # All modules in graph as a package
      metrics = Metrics.coupling("**", opts())
      assert is_map(metrics)
      assert Map.has_key?(metrics, :afferent)
      assert Map.has_key?(metrics, :efferent)
    end
  end
end
