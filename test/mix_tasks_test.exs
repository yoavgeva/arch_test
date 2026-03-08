defmodule MixTasksTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp run_task(task_module, app_name \\ :my_app) do
    test_project(app_name: app_name)
    |> task_module.igniter()
  end

  defp content(igniter, path) do
    source = igniter.rewrite.sources[path]
    refute is_nil(source), "Expected #{inspect(path)} to exist in igniter plan"
    Rewrite.Source.get(source, :content)
  end

  # ---------------------------------------------------------------------------
  # arch_test.install
  # ---------------------------------------------------------------------------

  describe "Mix.Tasks.ArchTest.Install" do
    test "creates test/<app>_arch_test.exs" do
      run_task(Mix.Tasks.ArchTest.Install)
      |> assert_creates("test/my_app_arch_test.exs")
    end

    test "generated file uses correct module name" do
      c = run_task(Mix.Tasks.ArchTest.Install) |> content("test/my_app_arch_test.exs")

      assert c =~ "defmodule MyApp.ArchTest"
    end

    test "generated file uses ArchTest" do
      c = run_task(Mix.Tasks.ArchTest.Install) |> content("test/my_app_arch_test.exs")

      assert c =~ "use ArchTest"
    end

    test "generated file includes cycle check" do
      c = run_task(Mix.Tasks.ArchTest.Install) |> content("test/my_app_arch_test.exs")

      assert c =~ ~s(test "no circular dependencies")
      assert c =~ "all_modules() |> should_be_free_of_cycles()"
    end

    test "app name is reflected in module name for different apps" do
      c =
        run_task(Mix.Tasks.ArchTest.Install, :blog_engine)
        |> content("test/blog_engine_arch_test.exs")

      assert c =~ "defmodule BlogEngine.ArchTest"
    end
  end

  # ---------------------------------------------------------------------------
  # arch_test.gen.modulith
  # ---------------------------------------------------------------------------

  describe "Mix.Tasks.ArchTest.Gen.Modulith" do
    test "creates test/arch/modulith_arch_test.exs" do
      run_task(Mix.Tasks.ArchTest.Gen.Modulith)
      |> assert_creates("test/arch/modulith_arch_test.exs")
    end

    test "uses correct module name" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Modulith) |> content("test/arch/modulith_arch_test.exs")

      assert c =~ "defmodule MyApp.Modulith.ArchTest"
    end

    test "defines slices with app namespace" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Modulith) |> content("test/arch/modulith_arch_test.exs")

      assert c =~ "define_slices("
      assert c =~ ~s("MyApp.Orders")
      assert c =~ ~s("MyApp.Accounts")
    end

    test "includes both isolation and cycle tests" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Modulith) |> content("test/arch/modulith_arch_test.exs")

      assert c =~ "allow_dependency(:orders, :accounts)"
      assert c =~ "enforce_isolation()"
      assert c =~ "should_be_free_of_cycles()"
    end
  end

  # ---------------------------------------------------------------------------
  # arch_test.gen.layers
  # ---------------------------------------------------------------------------

  describe "Mix.Tasks.ArchTest.Gen.Layers" do
    test "creates test/arch/layers_arch_test.exs" do
      run_task(Mix.Tasks.ArchTest.Gen.Layers)
      |> assert_creates("test/arch/layers_arch_test.exs")
    end

    test "uses correct module name" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Layers) |> content("test/arch/layers_arch_test.exs")

      assert c =~ "defmodule MyApp.Layers.ArchTest"
    end

    test "defines web/context/repo layers with app namespace" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Layers) |> content("test/arch/layers_arch_test.exs")

      assert c =~ "define_layers("
      assert c =~ ~s("MyApp.Web.**")
      assert c =~ ~s("MyApp.**")
      assert c =~ ~s("MyApp.Repo.**")
    end

    test "enforces layer direction" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Layers) |> content("test/arch/layers_arch_test.exs")

      assert c =~ "enforce_direction()"
    end
  end

  # ---------------------------------------------------------------------------
  # arch_test.gen.freeze
  # ---------------------------------------------------------------------------

  describe "Mix.Tasks.ArchTest.Gen.Freeze" do
    test "creates test/arch/freeze_arch_test.exs" do
      run_task(Mix.Tasks.ArchTest.Gen.Freeze)
      |> assert_creates("test/arch/freeze_arch_test.exs")
    end

    test "uses correct module name" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Freeze) |> content("test/arch/freeze_arch_test.exs")

      assert c =~ "defmodule MyApp.Freeze.ArchTest"
    end

    test "wraps assertion in ArchTest.Freeze.freeze" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Freeze) |> content("test/arch/freeze_arch_test.exs")

      assert c =~ ~s(ArchTest.Freeze.freeze("all_deps", fn ->)
      assert c =~ "should_be_free_of_cycles()"
    end

    test "includes update instructions comment" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Freeze) |> content("test/arch/freeze_arch_test.exs")

      assert c =~ "ARCH_TEST_UPDATE_FREEZE=true"
    end
  end

  # ---------------------------------------------------------------------------
  # arch_test.gen.onion
  # ---------------------------------------------------------------------------

  describe "Mix.Tasks.ArchTest.Gen.Onion" do
    test "creates test/arch/onion_arch_test.exs" do
      run_task(Mix.Tasks.ArchTest.Gen.Onion)
      |> assert_creates("test/arch/onion_arch_test.exs")
    end

    test "uses correct module name" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Onion) |> content("test/arch/onion_arch_test.exs")

      assert c =~ "defmodule MyApp.Onion.ArchTest"
    end

    test "defines all four onion rings" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Onion) |> content("test/arch/onion_arch_test.exs")

      assert c =~ "define_onion("
      assert c =~ ~s("MyApp.Domain.**")
      assert c =~ ~s("MyApp.Application.**")
      assert c =~ ~s("MyApp.Adapters.**")
      assert c =~ ~s("MyApp.Web.**")
    end

    test "enforces inward dependency direction" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Onion) |> content("test/arch/onion_arch_test.exs")

      assert c =~ "enforce_onion_rules()"
    end
  end

  # ---------------------------------------------------------------------------
  # arch_test.gen.naming
  # ---------------------------------------------------------------------------

  describe "Mix.Tasks.ArchTest.Gen.Naming" do
    test "creates test/arch/naming_arch_test.exs" do
      run_task(Mix.Tasks.ArchTest.Gen.Naming)
      |> assert_creates("test/arch/naming_arch_test.exs")
    end

    test "uses correct module name" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Naming) |> content("test/arch/naming_arch_test.exs")

      assert c =~ "defmodule MyApp.Naming.ArchTest"
    end

    test "bans Manager and God modules" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Naming) |> content("test/arch/naming_arch_test.exs")

      assert c =~ ~s[modules_matching("MyApp.**.*Manager")]
      assert c =~ ~s[modules_matching("MyApp.**.*God")]
      assert c =~ "should_not_exist()"
    end

    test "enforces schema placement" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Naming) |> content("test/arch/naming_arch_test.exs")

      assert c =~ "function_exported?(m, :__schema__, 1)"
      assert c =~ "should_reside_under("
      assert c =~ ~s("MyApp.**.Schemas")
    end
  end

  # ---------------------------------------------------------------------------
  # arch_test.gen.conventions
  # ---------------------------------------------------------------------------

  describe "Mix.Tasks.ArchTest.Gen.Conventions" do
    test "creates test/arch/conventions_arch_test.exs" do
      run_task(Mix.Tasks.ArchTest.Gen.Conventions)
      |> assert_creates("test/arch/conventions_arch_test.exs")
    end

    test "uses correct module name and imports Conventions" do
      c =
        run_task(Mix.Tasks.ArchTest.Gen.Conventions)
        |> content("test/arch/conventions_arch_test.exs")

      assert c =~ "defmodule MyApp.Conventions.ArchTest"
      assert c =~ "use ArchTest.Conventions"
    end

    test "includes IO.puts, dbg, and raise checks" do
      c =
        run_task(Mix.Tasks.ArchTest.Gen.Conventions)
        |> content("test/arch/conventions_arch_test.exs")

      assert c =~ "no_io_puts_in("
      assert c =~ "no_dbg_in("
      assert c =~ "no_raise_string_in("
    end

    test "scopes checks to app namespace" do
      c =
        run_task(Mix.Tasks.ArchTest.Gen.Conventions)
        |> content("test/arch/conventions_arch_test.exs")

      assert c =~ ~s("MyApp.**")
    end
  end

  # ---------------------------------------------------------------------------
  # arch_test.gen.phoenix
  # ---------------------------------------------------------------------------

  describe "Mix.Tasks.ArchTest.Gen.Phoenix" do
    test "creates test/arch/phoenix_arch_test.exs" do
      run_task(Mix.Tasks.ArchTest.Gen.Phoenix)
      |> assert_creates("test/arch/phoenix_arch_test.exs")
    end

    test "uses correct module name and imports both ArchTest and Conventions" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Phoenix) |> content("test/arch/phoenix_arch_test.exs")

      assert c =~ "defmodule MyApp.Phoenix.ArchTest"
      assert c =~ "use ArchTest"
      assert c =~ "use ArchTest.Conventions"
    end

    test "enforces layer direction" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Phoenix) |> content("test/arch/phoenix_arch_test.exs")

      assert c =~ "define_layers("
      assert c =~ "enforce_direction()"
    end

    test "prevents contexts from depending on web layer" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Phoenix) |> content("test/arch/phoenix_arch_test.exs")

      assert c =~ "should_not_depend_on("
    end

    test "includes cycle detection" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Phoenix) |> content("test/arch/phoenix_arch_test.exs")

      assert c =~ "should_be_free_of_cycles()"
    end

    test "includes naming and code convention checks" do
      c = run_task(Mix.Tasks.ArchTest.Gen.Phoenix) |> content("test/arch/phoenix_arch_test.exs")

      assert c =~ ~s[modules_matching("MyApp.**.*Manager")]
      assert c =~ "no_io_puts_in("
      assert c =~ "no_dbg_in("
    end
  end
end
