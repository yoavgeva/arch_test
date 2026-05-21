defmodule ArchTest.AdvancedFeaturesTest do
  use ExUnit.Case, async: false

  alias ArchTest.{Metrics, Modulith, PlantUML, Rule, Violation}

  @graph %{
    MyApp.Orders => [MyApp.Accounts],
    MyApp.Orders.Checkout => [MyApp.Inventory.Repo],
    MyApp.Inventory => [],
    MyApp.Inventory.Repo => [],
    MyApp.Accounts => []
  }

  test "rules are reusable, ignorable, assertable, and freezable" do
    rule =
      Rule.new("orders must not call inventory internals", fn graph ->
        for dep <- ArchTest.Collector.dependencies_of(graph, MyApp.Orders.Checkout),
            dep == MyApp.Inventory.Repo do
          Violation.forbidden_dep(MyApp.Orders.Checkout, dep, "internal inventory access")
        end
      end)
      |> Rule.ignore(callee: "MyApp.Inventory.Repo")

    assert Rule.assert(rule, graph: @graph) == :ok
  end

  test "define_slices_by captures slice roots from module names" do
    modulith = Modulith.define_slices_by("MyApp.(*)", graph: @graph, except: ["MyApp.Accounts"])

    assert %Modulith{} = modulith
    assert modulith.slices[:orders] == "MyApp.Orders"
    assert modulith.slices[:inventory] == "MyApp.Inventory"
    refute Keyword.has_key?(modulith.slices, :accounts)
  end

  test "define_slices_by captures roots even when only descendants exist" do
    graph = %{
      MyApp.Orders.Checkout => [],
      MyApp.Inventory.Repo => []
    }

    modulith = Modulith.define_slices_by("MyApp.(*)", graph: graph)

    assert modulith.slices[:orders] == "MyApp.Orders"
    assert modulith.slices[:inventory] == "MyApp.Inventory"
  end

  test "define_slices_by captures concrete roots when wildcard segments precede capture" do
    graph = %{
      Umbrella.Sales.Orders.Checkout => [],
      Umbrella.Sales.Inventory.Repo => []
    }

    modulith = Modulith.define_slices_by("Umbrella.*.(*)", graph: graph)

    assert modulith.slices[:orders] == "Umbrella.Sales.Orders"
    assert modulith.slices[:inventory] == "Umbrella.Sales.Inventory"
  end

  test "public DSL accepts modulith cycles in documented pipeline shape" do
    graph = %{
      MyApp.Orders.Checkout => [MyApp.Inventory.Repo],
      MyApp.Inventory.Repo => [MyApp.Orders.Checkout]
    }

    assert_raise ExUnit.AssertionError, ~r/circular dependency between bounded contexts/, fn ->
      ArchTest.define_slices(orders: "MyApp.Orders", inventory: "MyApp.Inventory")
      |> ArchTest.should_be_free_of_cycles(graph: graph)
    end
  end

  test "public modulith isolation accepts graph option" do
    assert_raise ExUnit.AssertionError, ~r/internal module/, fn ->
      ArchTest.define_slices(orders: "MyApp.Orders", inventory: "MyApp.Inventory")
      |> ArchTest.enforce_isolation(graph: @graph)
    end
  end

  test "public strict modulith isolation accepts graph option" do
    assert_raise ExUnit.AssertionError, ~r/strict isolation/, fn ->
      ArchTest.define_slices(orders: "MyApp.Orders", accounts: "MyApp.Accounts")
      |> ArchTest.should_not_depend_on_each_other(graph: @graph)
    end
  end

  @tag :tmp_dir
  test "PlantUML enforcement rejects dependencies absent from the diagram", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "components.puml")

    File.write!(file, """
    @startuml
    [Orders] --> [Accounts]
    @enduml
    """)

    assert_raise ExUnit.AssertionError, ~r/plantuml/, fn ->
      PlantUML.enforce(file,
        slices: [orders: "MyApp.Orders", inventory: "MyApp.Inventory", accounts: "MyApp.Accounts"],
        graph: @graph
      )
    end
  end

  @tag :tmp_dir
  test "PlantUML enforcement passes when actual slice deps are present in the diagram", %{
    tmp_dir: tmp_dir
  } do
    file = Path.join(tmp_dir, "components.puml")

    File.write!(file, """
    @startuml
    [Orders] --> [Accounts]
    [Orders] --> [Inventory]
    @enduml
    """)

    assert PlantUML.enforce(file,
             slices: [
               orders: "MyApp.Orders",
               inventory: "MyApp.Inventory",
               accounts: "MyApp.Accounts"
             ],
             graph: @graph
           ) == :ok
  end

  @tag :tmp_dir
  test "PlantUML parser ignores commented-out edges", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "components.puml")

    File.write!(file, """
    @startuml
    ' [Orders] --> [Inventory]
    [Orders] --> [Accounts]
    @enduml
    """)

    assert_raise ExUnit.AssertionError, ~r/plantuml/, fn ->
      PlantUML.enforce(file,
        slices: [orders: "MyApp.Orders", inventory: "MyApp.Inventory", accounts: "MyApp.Accounts"],
        graph: @graph
      )
    end
  end

  @tag :tmp_dir
  test "PlantUML parser ignores block-commented edges", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "components.puml")

    File.write!(file, """
    @startuml
    /'
    [Orders] --> [Inventory]
    '/
    [Orders] --> [Accounts]
    @enduml
    """)

    assert_raise ExUnit.AssertionError, ~r/plantuml/, fn ->
      PlantUML.enforce(file,
        slices: [orders: "MyApp.Orders", inventory: "MyApp.Inventory", accounts: "MyApp.Accounts"],
        graph: @graph
      )
    end
  end

  test "metrics exposes fan-in, fan-out, and dependency depth" do
    assert Metrics.fan_out(MyApp.Orders, graph: @graph) == 1
    assert Metrics.fan_in(MyApp.Accounts, graph: @graph) == 1
    assert Metrics.dependency_depth(MyApp.Orders.Checkout, graph: @graph) == 1
  end

  test "metrics exposes afferent and efferent aliases" do
    assert Metrics.afferent(MyApp.Accounts, graph: @graph) == 1
    assert Metrics.efferent(MyApp.Orders.Checkout, graph: @graph) == 1
  end
end
