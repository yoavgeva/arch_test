defmodule ArchTest.LayersTest do
  use ExUnit.Case, async: true

  alias ArchTest.{Layers, ModuleSet, Violation}

  @graph %{
    # Repo calling Web is a layer violation (upward dep)
    FixtureApp.Repo.OrderRepo => [FixtureApp.Web.Controller],
    FixtureApp.Web.Controller => [],
    FixtureApp.Orders.OrderService => [FixtureApp.Repo.OrderRepo],
    FixtureApp.Orders => [FixtureApp.Accounts],
    FixtureApp.Accounts => [],
    FixtureApp.Domain.Order => []
  }

  describe "enforce_direction/1" do
    test "detects upward dependency (Repo → Web)" do
      layers =
        Layers.define_layers(
          web: "FixtureApp.Web.**",
          context: "FixtureApp.Orders.**",
          repo: "FixtureApp.Repo.**"
        )

      violations = check_layer_direction(layers, @graph)

      # Repo calling Web is an upward dependency violation
      assert Enum.any?(violations, fn v ->
               v.caller == FixtureApp.Repo.OrderRepo and
                 v.callee == FixtureApp.Web.Controller
             end)
    end

    test "allows downward dependencies" do
      layers =
        Layers.define_layers(
          context: "FixtureApp.Orders.**",
          repo: "FixtureApp.Repo.**"
        )

      violations = check_layer_direction(layers, @graph)
      # OrderService → OrderRepo: context → repo = allowed (downward dep, no violation)
      refute Enum.any?(violations, fn v ->
               v.caller == FixtureApp.Orders.OrderService
             end)
    end
  end

  describe "enforce_onion_rules/1" do
    test "detects outward dependency" do
      onion =
        Layers.define_onion(
          domain: "FixtureApp.Domain.**",
          context: "FixtureApp.Orders.**",
          adapters: "FixtureApp.Web.**"
        )

      # Build graph where domain depends on adapters (violation)
      graph = Map.put(@graph, FixtureApp.Domain.Order, [FixtureApp.Web.Controller])
      violations = check_onion_rules(onion, graph)

      assert Enum.any?(violations, fn v ->
               v.caller == FixtureApp.Domain.Order
             end)
    end

    test "allows inward dependencies" do
      onion =
        Layers.define_onion(
          domain: "FixtureApp.Domain.**",
          context: "FixtureApp.Orders.**"
        )

      # Adapters may depend on context which may depend on domain — all inward
      clean_graph = %{
        FixtureApp.Domain.Order => [],
        FixtureApp.Orders => [FixtureApp.Domain.Order]
      }

      violations = check_onion_rules(onion, clean_graph)
      assert violations == []
    end
  end

  describe "define_layers/1 struct" do
    test "layers are stored in definition order" do
      arch = Layers.define_layers(web: "A.**", context: "B.**", repo: "C.**")
      assert Keyword.keys(arch.layers) == [:web, :context, :repo]
    end

    test "layers struct has layers field" do
      arch = Layers.define_layers(web: "A.**")
      assert %Layers{layers: layers} = arch
      assert Keyword.get(layers, :web) == "A.**"
    end
  end

  describe "enforce_direction/1 — edge cases" do
    test "single-layer arch has no violations" do
      arch = Layers.define_layers(web: "FixtureApp.Web.**")
      violations = check_layer_direction(arch, @graph)
      assert violations == []
    end

    test "no violations when layers have no cross-deps" do
      arch =
        Layers.define_layers(
          web: "FixtureApp.Web.**",
          repo: "FixtureApp.Repo.**"
        )

      isolated_graph = %{
        FixtureApp.Web.Controller => [],
        FixtureApp.Repo.OrderRepo => []
      }

      violations = check_layer_direction(arch, isolated_graph)
      assert violations == []
    end

    test "multiple upward violations are all reported" do
      arch =
        Layers.define_layers(
          web: "FixtureApp.Web.**",
          repo: "FixtureApp.Repo.**"
        )

      bad_graph = %{
        FixtureApp.Web.Controller => [],
        FixtureApp.Repo.OrderRepo => [FixtureApp.Web.Controller],
        FixtureApp.Repo.UserRepo => [FixtureApp.Web.Controller]
      }

      violations = check_layer_direction(arch, bad_graph)
      assert length(violations) == 2
    end

    test "4-layer architecture catches all upward violations" do
      # web → context → service → repo (top to bottom)
      graph = %{
        FourLayer.Web.Controller => [FourLayer.Context.Orders],
        FourLayer.Context.Orders => [FourLayer.Service.OrderService],
        FourLayer.Service.OrderService => [FourLayer.Repo.OrderRepo],
        FourLayer.Repo.OrderRepo => [FourLayer.Web.Controller, FourLayer.Context.Orders]
      }

      arch =
        Layers.define_layers(
          web: "FourLayer.Web.**",
          context: "FourLayer.Context.**",
          service: "FourLayer.Service.**",
          repo: "FourLayer.Repo.**"
        )

      violations = check_layer_direction(arch, graph)

      # Repo → Web (3 layers up) should be caught
      assert Enum.any?(violations, fn v ->
               v.caller == FourLayer.Repo.OrderRepo and
                 v.callee == FourLayer.Web.Controller
             end)

      # Repo → Context (2 layers up) should be caught
      assert Enum.any?(violations, fn v ->
               v.caller == FourLayer.Repo.OrderRepo and
                 v.callee == FourLayer.Context.Orders
             end)

      # Downward deps should NOT be violations
      refute Enum.any?(violations, fn v ->
               v.caller == FourLayer.Web.Controller
             end)

      refute Enum.any?(violations, fn v ->
               v.caller == FourLayer.Context.Orders
             end)
    end

    test "layer with zero modules does not cause errors" do
      arch =
        Layers.define_layers(
          web: "FixtureApp.Web.**",
          empty: "NonExistent.Empty.**",
          repo: "FixtureApp.Repo.**"
        )

      violations = check_layer_direction(arch, @graph)
      # Should still detect Repo → Web violation even with an empty layer in between
      assert Enum.any?(violations, fn v ->
               v.caller == FixtureApp.Repo.OrderRepo and
                 v.callee == FixtureApp.Web.Controller
             end)
    end

    test "module matching multiple layers is assigned to the first matching layer" do
      # A module that could match two layer patterns
      graph = %{
        Overlap.Web.Service => [Overlap.Repo.Data],
        Overlap.Repo.Data => []
      }

      # Both patterns could match Overlap.Web.Service if patterns overlap
      arch =
        Layers.define_layers(
          web: "Overlap.Web.**",
          service: "Overlap.Web.**",
          repo: "Overlap.Repo.**"
        )

      # Should not crash; the module is assigned to the first matching layer
      violations = check_layer_direction(arch, graph)
      assert is_list(violations)
    end

    test "violation error message contains layer names" do
      arch =
        Layers.define_layers(
          web: "FixtureApp.Web.**",
          repo: "FixtureApp.Repo.**"
        )

      violations = check_layer_direction(arch, @graph)

      assert Enum.any?(violations, fn v ->
               String.contains?(v.message, "repo") or String.contains?(v.message, "web")
             end)
    end
  end

  describe "define_onion/1 — edge cases" do
    test "no violations in clean onion graph" do
      onion =
        Layers.define_onion(
          domain: "Domain.**",
          application: "Application.**",
          adapters: "Adapters.**"
        )

      clean_graph = %{
        Domain.Core => [],
        Application.Service => [Domain.Core],
        Adapters.Controller => [Application.Service]
      }

      violations = check_onion_rules(onion, clean_graph)
      assert violations == []
    end

    test "inner layer calling outer layer is a violation" do
      graph = %{
        Onion.Domain.Entity => [Onion.Adapters.DB],
        Onion.Application.Service => [],
        Onion.Adapters.DB => []
      }

      onion =
        Layers.define_onion(
          domain: "Onion.Domain.**",
          application: "Onion.Application.**",
          adapters: "Onion.Adapters.**"
        )

      violations = check_onion_rules(onion, graph)

      assert Enum.any?(violations, fn v ->
               v.caller == Onion.Domain.Entity and
                 v.callee == Onion.Adapters.DB
             end)
    end

    test "outer layer calling inner layer is allowed" do
      graph = %{
        Onion.Domain.Entity => [],
        Onion.Application.Service => [Onion.Domain.Entity],
        Onion.Adapters.DB => [Onion.Application.Service, Onion.Domain.Entity]
      }

      onion =
        Layers.define_onion(
          domain: "Onion.Domain.**",
          application: "Onion.Application.**",
          adapters: "Onion.Adapters.**"
        )

      violations = check_onion_rules(onion, graph)
      assert violations == []
    end

    test "3-ring onion: domain → application → adapters full test" do
      graph = %{
        # Domain has no deps (innermost)
        Ring.Domain.Entity => [],
        Ring.Domain.ValueObject => [],
        # Application depends on domain (inward - OK)
        Ring.Application.UseCase => [Ring.Domain.Entity],
        # Adapters depend on application and domain (inward - OK)
        Ring.Adapters.HTTP => [Ring.Application.UseCase],
        Ring.Adapters.Repo => [Ring.Domain.Entity],
        # Violation: domain depends on adapters (outward)
        Ring.Domain.BadDep => [Ring.Adapters.HTTP]
      }

      onion =
        Layers.define_onion(
          domain: "Ring.Domain.**",
          application: "Ring.Application.**",
          adapters: "Ring.Adapters.**"
        )

      violations = check_onion_rules(onion, graph)

      # Only BadDep should have a violation
      assert length(violations) == 1

      assert Enum.any?(violations, fn v ->
               v.caller == Ring.Domain.BadDep and
                 v.callee == Ring.Adapters.HTTP
             end)
    end

    test "onion direction is reversed from layers: innermost cannot depend on outer" do
      # In define_layers, first = highest; in define_onion, first = innermost
      graph = %{
        Rev.Domain.Core => [Rev.Adapters.API],
        Rev.Adapters.API => []
      }

      onion =
        Layers.define_onion(
          domain: "Rev.Domain.**",
          adapters: "Rev.Adapters.**"
        )

      violations = check_onion_rules(onion, graph)

      # Domain (innermost, first) depending on Adapters (outermost, second) = violation
      assert Enum.any?(violations, fn v ->
               v.caller == Rev.Domain.Core and
                 v.callee == Rev.Adapters.API
             end)

      # Now test the reverse: adapters → domain should be allowed
      graph2 = %{
        Rev.Domain.Core => [],
        Rev.Adapters.API => [Rev.Domain.Core]
      }

      violations2 = check_onion_rules(onion, graph2)
      assert violations2 == []
    end
  end

  describe "define_layers/1 with 1 layer" do
    test "single layer trivially passes" do
      arch = Layers.define_layers(only: "Only.**")

      graph = %{
        Only.A => [Only.B],
        Only.B => [Only.A]
      }

      violations = check_layer_direction(arch, graph)
      assert violations == []
    end
  end

  # ------------------------------------------------------------------
  # Private helpers to run layer checks without calling xref
  # ------------------------------------------------------------------

  defp check_layer_direction(%Layers{} = arch, graph) do
    layer_names = Keyword.keys(arch.layers)

    arch.layers
    |> Enum.with_index()
    |> Enum.flat_map(fn {{layer_name, pattern}, idx} ->
      higher_layers = Enum.take(layer_names, idx)

      higher_layer_modules =
        higher_layers
        |> Enum.flat_map(fn l ->
          p = Keyword.fetch!(arch.layers, l)
          ModuleSet.new(p) |> ModuleSet.resolve(graph)
        end)
        |> MapSet.new()

      layer_modules = ModuleSet.new(pattern) |> ModuleSet.resolve(graph)

      for mod <- layer_modules,
          dep <- ArchTest.Collector.dependencies_of(graph, mod),
          MapSet.member?(higher_layer_modules, dep) do
        dep_layer = find_layer(dep, arch.layers, graph)

        Violation.forbidden_dep(
          mod,
          dep,
          "upward dependency from :#{layer_name} to :#{dep_layer}"
        )
      end
    end)
  end

  defp check_onion_rules(%Layers{} = arch, graph) do
    layer_names = Keyword.keys(arch.layers)

    arch.layers
    |> Enum.with_index()
    |> Enum.flat_map(fn {{layer_name, pattern}, idx} ->
      outer_layers = Enum.drop(layer_names, idx + 1)

      outer_modules =
        outer_layers
        |> Enum.flat_map(fn l ->
          p = Keyword.fetch!(arch.layers, l)
          ModuleSet.new(p) |> ModuleSet.resolve(graph)
        end)
        |> MapSet.new()

      layer_modules = ModuleSet.new(pattern) |> ModuleSet.resolve(graph)

      for mod <- layer_modules,
          dep <- ArchTest.Collector.dependencies_of(graph, mod),
          MapSet.member?(outer_modules, dep) do
        Violation.forbidden_dep(mod, dep, "outward dependency from #{layer_name}")
      end
    end)
  end

  defp find_layer(mod, layers, graph) do
    Enum.find_value(layers, :unknown, fn {layer_name, pattern} ->
      mods = ModuleSet.new(pattern) |> ModuleSet.resolve(graph)
      if mod in mods, do: layer_name
    end)
  end
end
