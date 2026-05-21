defmodule ArchTest.FixtureAppExamplesTest do
  @moduledoc """
  Executable examples against the real fixture Mix project.

  These tests intentionally read compiled BEAM files from
  test/support/fixture_app instead of synthetic graphs. They are here to keep
  the public examples honest.
  """

  use ExUnit.Case, async: false

  alias ArchTest.{Collector, Metrics, PlantUML, Rule, Violation}

  @moduletag :integration

  @fixture_root Path.expand("../support/fixture_app", __DIR__)
  @ebin Path.join(@fixture_root, "_build/dev/lib/fixture_app/ebin")
  @diagram Path.join(@fixture_root, "docs/components.puml")

  defp graph do
    Collector.build_graph_from_path(@ebin,
      force: true,
      include: ["FixtureApp.**"]
    )
  end

  defp slices do
    [
      accounts: "FixtureApp.Accounts",
      inventory: "FixtureApp.Inventory",
      orders: "FixtureApp.Orders",
      repo: "FixtureApp.Repo",
      web: "FixtureApp.Web"
    ]
  end

  test "PlantUML diagram documents real fixture slice dependencies" do
    assert PlantUML.enforce(@diagram, graph: graph(), slices: slices()) == :ok
  end

  test "define_slices_by discovers real fixture bounded contexts" do
    modulith =
      ArchTest.define_slices_by("FixtureApp.(*)",
        graph: graph(),
        except: [
          "FixtureApp",
          "FixtureApp.Behaviours.**",
          "FixtureApp.DebugHelpers",
          "FixtureApp.Domain.**"
        ]
      )

    assert modulith.slices[:accounts] == "FixtureApp.Accounts"
    assert modulith.slices[:inventory] == "FixtureApp.Inventory"
    assert modulith.slices[:orders] == "FixtureApp.Orders"
    assert modulith.slices[:repo] == "FixtureApp.Repo"
    assert modulith.slices[:web] == "FixtureApp.Web"
  end

  test "Collector.calls_from_path exposes real call file and line metadata" do
    calls =
      Collector.calls_from_path(@ebin,
        force: true,
        include: ["FixtureApp.**"]
      )

    checkout_call =
      Enum.find(calls, fn call ->
        call.caller_module == FixtureApp.Orders.Checkout and
          call.caller_function == :calculate_total and
          call.callee_module == FixtureApp.Inventory.Repo and
          call.callee_function == :get_stock
      end)

    assert checkout_call.kind == :remote_call
    assert checkout_call.line == 9

    assert Path.relative_to(checkout_call.file, @fixture_root) ==
             "lib/fixture_app/orders/checkout.ex"
  end

  test "ArchTest.Rule can ignore a known real fixture violation" do
    rule =
      Rule.new("web must not call repo directly", fn graph ->
        for dep <- Collector.dependencies_of(graph, FixtureApp.Web.Controller),
            dep == FixtureApp.Repo.OrderRepo do
          Violation.forbidden_dep(
            FixtureApp.Web.Controller,
            dep,
            "web should call a context instead of repo"
          )
        end
      end)

    assert_raise ExUnit.AssertionError, ~r/web must not call repo directly/, fn ->
      Rule.assert(rule, graph: graph())
    end

    assert rule
           |> Rule.ignore(caller: "FixtureApp.Web.Controller")
           |> Rule.assert(graph: graph()) == :ok
  end

  test "new metrics work against the real fixture dependency graph" do
    g = graph()

    assert Metrics.afferent("FixtureApp.Repo", graph: g) >= 2
    assert Metrics.efferent("FixtureApp.Orders", graph: g) >= 2
    assert Metrics.fan_in(FixtureApp.Repo.OrderRepo, graph: g) == 2
    assert Metrics.dependency_depth(FixtureApp.Web.Controller, graph: g) >= 1
  end
end
