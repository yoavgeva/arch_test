defmodule ArchTest.PatternTest do
  use ExUnit.Case, async: true

  alias ArchTest.Pattern

  describe "compile/1 + match?/2" do
    test "exact match" do
      assert Pattern.matches?("MyApp.Orders", "MyApp.Orders")
      refute Pattern.matches?("MyApp.Orders", "MyApp.Orders.Order")
      refute Pattern.matches?("MyApp.Orders", "MyApp.OrdersExtra")
    end

    test "single star — direct children only" do
      assert Pattern.matches?("MyApp.Orders.*", "MyApp.Orders.Order")
      assert Pattern.matches?("MyApp.Orders.*", "MyApp.Orders.Repo")
      refute Pattern.matches?("MyApp.Orders.*", "MyApp.Orders.Schemas.Order")
      refute Pattern.matches?("MyApp.Orders.*", "MyApp.Orders")
    end

    test "double star — all descendants" do
      assert Pattern.matches?("MyApp.Orders.**", "MyApp.Orders.Order")
      assert Pattern.matches?("MyApp.Orders.**", "MyApp.Orders.Schemas.Order")
      assert Pattern.matches?("MyApp.Orders.**", "MyApp.Orders.A.B.C")
      refute Pattern.matches?("MyApp.Orders.**", "MyApp.Orders")
      refute Pattern.matches?("MyApp.Orders.**", "MyApp.Web.Controller")
    end

    test "double star at start — any prefix" do
      assert Pattern.matches?("**.*Service", "MyApp.Orders.OrderService")
      assert Pattern.matches?("**.*Service", "OrderService")
      refute Pattern.matches?("**.*Service", "MyApp.Orders.OrderServiceHelper")
      refute Pattern.matches?("**.*Service", "MyApp.Orders.Repo")
    end

    test "double star with wildcard segment — contains match" do
      assert Pattern.matches?("**.*Service*", "MyApp.Orders.OrderService")
      assert Pattern.matches?("**.*Service*", "MyApp.Orders.OrderServiceHelper")
      refute Pattern.matches?("**.*Service*", "MyApp.Orders.Repo")
    end

    test "double star in middle" do
      assert Pattern.matches?("MyApp.**.*Repo", "MyApp.Orders.OrderRepo")
      assert Pattern.matches?("MyApp.**.*Repo", "MyApp.Orders.Schemas.OrderRepo")
      assert Pattern.matches?("MyApp.**.*Repo", "MyApp.Repo")
      refute Pattern.matches?("MyApp.**.*Repo", "MyApp.Orders.OrderService")
    end

    test "solo double star matches everything" do
      assert Pattern.matches?("**", "MyApp")
      assert Pattern.matches?("**", "MyApp.Orders")
      assert Pattern.matches?("**", "MyApp.Orders.Order")
    end

    test "star in segment — partial match" do
      assert Pattern.matches?("MyApp.*Controller", "MyApp.OrderController")
      assert Pattern.matches?("MyApp.*Controller", "MyApp.Controller")
      refute Pattern.matches?("MyApp.*Controller", "MyApp.Order.Controller")
    end

    test "module atoms work" do
      assert Pattern.matches?("MyApp.Orders.*", MyApp.Orders.Order)
      refute Pattern.matches?("MyApp.Orders.*", MyApp.Orders.Schemas.Order)
    end
  end

  describe "filter/2" do
    test "filters a list of modules" do
      modules = ["MyApp.Orders.Order", "MyApp.Orders.Repo", "MyApp.Web.Controller"]
      result = Pattern.filter(modules, "MyApp.Orders.*")
      assert result == ["MyApp.Orders.Order", "MyApp.Orders.Repo"]
    end

    test "returns empty list when nothing matches" do
      modules = ["MyApp.Web.Controller", "MyApp.Web.Router"]
      result = Pattern.filter(modules, "MyApp.Orders.*")
      assert result == []
    end

    test "filter with ** returns all" do
      modules = ["A", "A.B", "A.B.C"]
      assert Pattern.filter(modules, "**") == modules
    end
  end

  describe "module_to_string/1" do
    test "strips Elixir. prefix" do
      assert Pattern.module_to_string(Elixir.MyApp.Orders) == "MyApp.Orders"
    end

    test "keeps non-Elixir atoms as-is" do
      assert Pattern.module_to_string(:logger) == "logger"
    end
  end

  describe "edge cases" do
    test "consecutive ** collapses to single **" do
      # MyApp.**.** should behave same as MyApp.**
      assert Pattern.matches?("MyApp.**.**", "MyApp.A.B.C")
      assert Pattern.matches?("MyApp.**.**", "MyApp.A")
      refute Pattern.matches?("MyApp.**.**", "MyApp")
    end

    test "pattern with no wildcards is exact match" do
      assert Pattern.matches?("A.B.C", "A.B.C")
      refute Pattern.matches?("A.B.C", "A.B")
      refute Pattern.matches?("A.B.C", "A.B.C.D")
    end

    test "** at start matches single-segment modules" do
      assert Pattern.matches?("**.*Repo", "OrderRepo")
    end

    test "* does not match dots" do
      refute Pattern.matches?("MyApp.*", "MyApp.A.B")
      assert Pattern.matches?("MyApp.*", "MyApp.AB")
    end

    test "star in middle of segment" do
      assert Pattern.matches?("My*App.Orders", "MyBigApp.Orders")
      refute Pattern.matches?("My*App.Orders", "My.App.Orders")
    end

    test "compile/1 returns a Regex" do
      assert %Regex{} = Pattern.compile("MyApp.**")
    end

    test "compiled regex can be reused with matches?/2" do
      regex = Pattern.compile("MyApp.Orders.*")
      assert Pattern.matches?(regex, "MyApp.Orders.Checkout")
      refute Pattern.matches?(regex, "MyApp.Orders.Sub.Checkout")
    end

    test "module atom in filter" do
      result = Pattern.filter([MyApp.Orders.Checkout, MyApp.Web.Controller], "MyApp.Orders.*")
      assert result == [MyApp.Orders.Checkout]
    end

    test "** with trailing segment after middle **" do
      assert Pattern.matches?("MyApp.**.*Service", "MyApp.Orders.OrderService")
      assert Pattern.matches?("MyApp.**.*Service", "MyApp.X.Y.Z.FooService")
      refute Pattern.matches?("MyApp.**.*Service", "MyApp.Orders.OrderRepo")
    end
  end

  describe "additional edge cases" do
    test "** matches a module with many segments" do
      deep = "A.B.C.D.E.F.G.H.I.J"
      assert Pattern.matches?("**", deep)
    end

    test "empty string pattern matches only empty string" do
      # An empty pattern compiles to ^$, which only matches ""
      refute Pattern.matches?("", "MyApp.Orders")
      assert Pattern.matches?("", "")
    end

    test "pattern with trailing dot does not match valid module names" do
      refute Pattern.matches?("MyApp.", "MyApp.Orders")
      refute Pattern.matches?("MyApp.", "MyApp")
      refute Pattern.matches?("MyApp.", "MyApp.")
    end

    test "module name with numbers: MyApp.V2.Schema matched by pattern" do
      assert Pattern.matches?("MyApp.**.*Schema", "MyApp.V2.Schema")
      assert Pattern.matches?("MyApp.V2.*", "MyApp.V2.Schema")
      assert Pattern.matches?("MyApp.V2.Schema", "MyApp.V2.Schema")
    end

    test "module_to_string/1 strips Elixir. prefix for all atom formats" do
      # Standard Elixir module atom
      assert Pattern.module_to_string(MyApp.Orders.Order) == "MyApp.Orders.Order"

      # Explicit Elixir. prefix
      assert Pattern.module_to_string(Elixir.MyApp) == "MyApp"

      # Single-segment Elixir module
      assert Pattern.module_to_string(Kernel) == "Kernel"
    end

    test "module_to_string/1 handles Erlang atoms without Elixir. prefix" do
      # Erlang modules do not have the Elixir. prefix
      assert Pattern.module_to_string(:erlang) == "erlang"
      assert Pattern.module_to_string(:ets) == "ets"
      assert Pattern.module_to_string(:crypto) == "crypto"
    end

    test "Erlang module atoms do not match Elixir-style patterns" do
      # :erlang should not match patterns expecting dot-separated Elixir modules
      refute Pattern.matches?("MyApp.*", :erlang)
      refute Pattern.matches?("**.*Service", :erlang)
      # But it should match ** since ** matches any non-empty string
      assert Pattern.matches?("**", :erlang)
    end

    test "filter with atom modules preserves module type in output" do
      mods = [MyApp.Orders.Checkout, MyApp.Web.Controller, :erlang]
      result = Pattern.filter(mods, "MyApp.Orders.*")
      assert result == [MyApp.Orders.Checkout]
    end

    test "single-segment exact match" do
      assert Pattern.matches?("Kernel", "Kernel")
      refute Pattern.matches?("Kernel", "KernelExtra")
      refute Pattern.matches?("Kernel", "My.Kernel")
    end

    test "** at start with exact segment" do
      assert Pattern.matches?("**.Order", "MyApp.Orders.Order")
      assert Pattern.matches?("**.Order", "Order")
      refute Pattern.matches?("**.Order", "MyApp.Orders.OrderExtra")
    end
  end
end
