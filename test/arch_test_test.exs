defmodule ArchTestTest do
  use ExUnit.Case, async: true

  describe "use ArchTest" do
    test "exports DSL functions" do
      Code.ensure_loaded!(ArchTest)
      assert function_exported?(ArchTest, :modules_matching, 1)
      assert function_exported?(ArchTest, :modules_in, 1)
      assert function_exported?(ArchTest, :all_modules, 0)
      assert function_exported?(ArchTest, :modules_satisfying, 1)
    end
  end

  describe "modules_matching/1" do
    test "returns a ModuleSet" do
      result = ArchTest.modules_matching("MyApp.Orders.*")
      assert %ArchTest.ModuleSet{} = result
      assert result.include_patterns == ["MyApp.Orders.*"]
    end
  end

  describe "modules_in/1" do
    test "creates ModuleSet for direct children" do
      result = ArchTest.modules_in("MyApp.Orders")
      assert %ArchTest.ModuleSet{} = result
      assert result.include_patterns == ["MyApp.Orders.*"]
    end
  end

  describe "all_modules/0" do
    test "returns a ModuleSet matching everything" do
      result = ArchTest.all_modules()
      assert %ArchTest.ModuleSet{} = result
      assert result.include_patterns == ["**"]
    end
  end

  describe "define_layers/1" do
    test "returns a Layers struct" do
      result = ArchTest.define_layers(web: "MyApp.Web.**", context: "MyApp.**")
      assert %ArchTest.Layers{} = result
      assert Keyword.has_key?(result.layers, :web)
    end
  end

  describe "define_slices/1" do
    test "returns a Modulith struct" do
      result = ArchTest.define_slices(orders: "MyApp.Orders", accounts: "MyApp.Accounts")
      assert %ArchTest.Modulith{} = result
      assert Keyword.has_key?(result.slices, :orders)
    end
  end
end
