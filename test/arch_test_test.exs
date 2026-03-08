defmodule ArchTestTest do
  use ExUnit.Case, async: true

  @version Mix.Project.config()[:version]

  describe "docs version consistency" do
    test "README installation snippet matches mix.exs version" do
      readme = File.read!(Path.expand("../README.md", __DIR__))

      assert readme =~ ~s({:arch_test, "~> #{minor_version(@version)}"),
             "README dep snippet is out of sync with mix.exs version #{@version}"
    end

    test "getting-started guide matches mix.exs version" do
      guide = File.read!(Path.expand("../guides/getting-started.md", __DIR__))

      assert guide =~ ~s({:arch_test, "~> #{minor_version(@version)}"),
             "guides/getting-started.md dep snippet is out of sync with mix.exs version #{@version}"
    end
  end

  defp minor_version(version) do
    [major, minor | _] = String.split(version, ".")
    "#{major}.#{minor}"
  end

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
