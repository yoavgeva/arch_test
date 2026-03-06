defmodule ArchTest.ConventionsTest do
  use ExUnit.Case, async: false

  alias ArchTest.{Conventions, ModuleSet, Violation}

  # We test Conventions functions against the compiled fixture app.
  # The fixture app lives in test/support/fixture_app and is compiled
  # before tests via the mix alias.

  @ebin Path.expand("../../support/fixture_app/_build/dev/lib/fixture_app/ebin", __DIR__)

  # Directory where we write BEAM files for fixture modules compiled at
  # test time. These modules need BEAM files on disk because the
  # Conventions detectors use :beam_lib.chunks/2 to read abstract code,
  # which requires a file path from :code.which/1.
  @beam_dir Path.join(System.tmp_dir!(), "arch_test_conventions_fixtures")

  setup_all do
    graph =
      if File.dir?(@ebin) do
        ArchTest.Collector.build_graph_from_path(@ebin)
      else
        %{}
      end

    # Always start with a clean BEAM directory to avoid stale files
    # from previous runs (e.g. files compiled without debug_info).
    File.rm_rf!(@beam_dir)
    File.mkdir_p!(@beam_dir)
    :code.add_patha(String.to_charlist(@beam_dir))

    # `mix test` may run with debug_info: false and docs: false, but the
    # Conventions detectors need abstract code (for call scanning) and
    # doc chunks (for documentation checks). Enable both for the duration
    # of fixture compilation so BEAM files include the required data.
    prev_opts = Map.take(Code.compiler_options(), [:debug_info, :docs])
    Code.compiler_options(debug_info: true, docs: true)

    # Compile all fixture modules once. Each module is written as a BEAM
    # file so that :code.which/1 returns a real path and
    # :beam_lib.chunks/2 can extract abstract code.
    compile_fixture("""
    defmodule ConventionFixture.WithIoPuts do
      def run, do: IO.puts("hello")
    end
    """)

    compile_fixture("""
    defmodule ConventionFixture.WithIoInspect do
      def run(x), do: IO.inspect(x)
    end
    """)

    compile_fixture("""
    defmodule ConventionFixture.CleanModule do
      def run, do: :ok
    end
    """)

    compile_fixture("""
    defmodule ConventionFixture.WithProcessSleep do
      def run, do: Process.sleep(100)
    end
    """)

    compile_fixture("""
    defmodule ConventionFixture.WithApplicationGetEnv do
      def run, do: Application.get_env(:my_app, :key)
    end
    """)

    compile_fixture("""
    defmodule ConventionFixture.WithDbg do
      def run(x), do: dbg(x)
    end
    """)

    compile_fixture("""
    defmodule ConventionFixture.WithBareRaise do
      def run, do: raise "something went wrong"
    end
    """)

    compile_fixture("""
    defmodule ConventionFixture.WithTypedRaise do
      defmodule MyError do
        defexception [:message]
      end
      def run, do: raise MyError, message: "typed error"
    end
    """)

    compile_fixture("""
    defmodule ConventionFixture.UndocumentedModule do
      @moduledoc "Module with undocumented public functions"

      def undocumented_func, do: :ok
      def another_undoc, do: :ok
    end
    """)

    compile_fixture("""
    defmodule ConventionFixture.FullyDocumentedModule do
      @moduledoc "Module with all public functions documented"

      @doc "This function does something"
      def documented_func, do: :ok

      @doc "This one too"
      def also_documented, do: :ok
    end
    """)

    compile_fixture("""
    defmodule ConventionFixture.DocFalseModule do
      @moduledoc "Module with @doc false functions"

      @doc false
      def hidden_func, do: :ok

      @doc "Visible function"
      def visible_func, do: :ok
    end
    """)

    compile_fixture("""
    defmodule ConventionFixture.WithNestedIoPuts do
      def run(x) do
        case x do
          :a -> IO.puts("nested in case")
          :b -> :ok
        end
      end
    end
    """)

    compile_fixture("""
    defmodule ConventionFixture.WithPipedIoInspect do
      def run(x) do
        x
        |> Map.get(:key)
        |> IO.inspect(label: "debug")
      end
    end
    """)

    compile_fixture("""
    defmodule ConventionFixture.WithNestedSleep do
      def run(x) do
        if x > 0 do
          Process.sleep(x)
        end
      end
    end
    """)

    compile_fixture("""
    defmodule ConventionFixture.WithFetchEnv do
      def run, do: Application.fetch_env(:my_app, :key)
    end
    """)

    compile_fixture("""
    defmodule ConventionFixture.WithFetchEnvBang do
      def run, do: Application.fetch_env!(:my_app, :key)
    end
    """)

    # Restore previous compiler options
    Code.compiler_options(prev_opts)

    {:ok, graph: graph}
  end

  # Compiles Elixir source to a module, writes its BEAM file to the
  # temp directory, and loads it from disk so :code.which/1 returns
  # a valid path that :beam_lib can read.
  #
  # Handles nested defmodule (e.g. inner exception modules) by writing
  # BEAM files for all compiled modules and returning the outermost one.
  defp compile_fixture(source) do
    modules = Code.compile_string(source)

    Enum.each(modules, fn {mod, bytecode} ->
      beam_file = Path.join(@beam_dir, "#{mod}.beam")
      File.write!(beam_file, bytecode)
      :code.purge(mod)
      :code.load_file(mod)
    end)

    modules |> List.last() |> elem(0)
  end

  # Builds a minimal graph containing only the given module.
  defp graph_for(mod), do: %{mod => []}

  # Builds a ModuleSet matching exactly the given module.
  defp module_set_for(mod) do
    ModuleSet.satisfying(fn m -> m == mod end)
  end

  # ------------------------------------------------------------------
  # no_io_puts_in/2
  # ------------------------------------------------------------------

  describe "no_io_puts_in/2" do
    test "passes when no module uses IO.puts — empty set" do
      ms = ModuleSet.satisfying(fn _mod -> false end)
      assert Conventions.no_io_puts_in(ms, graph: %{}) == :ok
    end

    test "accepts opts keyword" do
      ms = ModuleSet.satisfying(fn _mod -> false end)
      assert Conventions.no_io_puts_in(ms, graph: %{}) == :ok
    end

    test "detects IO.puts call" do
      mod = ConventionFixture.WithIoPuts
      ms = module_set_for(mod)

      assert_raise ExUnit.AssertionError, ~r/no_io_puts_in/, fn ->
        Conventions.no_io_puts_in(ms, graph: graph_for(mod))
      end
    end

    test "detects IO.inspect call" do
      mod = ConventionFixture.WithIoInspect
      ms = module_set_for(mod)

      assert_raise ExUnit.AssertionError, ~r/no_io_puts_in/, fn ->
        Conventions.no_io_puts_in(ms, graph: graph_for(mod))
      end
    end

    test "passes for a clean module without IO calls" do
      mod = ConventionFixture.CleanModule
      ms = module_set_for(mod)
      assert Conventions.no_io_puts_in(ms, graph: graph_for(mod)) == :ok
    end

    test "detects IO.puts nested inside a case expression" do
      mod = ConventionFixture.WithNestedIoPuts
      ms = module_set_for(mod)

      assert_raise ExUnit.AssertionError, ~r/no_io_puts_in/, fn ->
        Conventions.no_io_puts_in(ms, graph: graph_for(mod))
      end
    end

    test "detects IO.inspect in a pipe chain" do
      mod = ConventionFixture.WithPipedIoInspect
      ms = module_set_for(mod)

      assert_raise ExUnit.AssertionError, ~r/no_io_puts_in/, fn ->
        Conventions.no_io_puts_in(ms, graph: graph_for(mod))
      end
    end

    test "violation message mentions debugging artifact" do
      mod = ConventionFixture.WithIoPuts
      ms = module_set_for(mod)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Conventions.no_io_puts_in(ms, graph: graph_for(mod))
        end

      assert error.message =~ "debugging artifact"
    end
  end

  # ------------------------------------------------------------------
  # no_process_sleep_in/2
  # ------------------------------------------------------------------

  describe "no_process_sleep_in/2" do
    test "passes for empty module set" do
      ms = ModuleSet.satisfying(fn _ -> false end)
      assert Conventions.no_process_sleep_in(ms, graph: %{}) == :ok
    end

    test "detects Process.sleep call" do
      mod = ConventionFixture.WithProcessSleep
      ms = module_set_for(mod)

      assert_raise ExUnit.AssertionError, ~r/no_process_sleep_in/, fn ->
        Conventions.no_process_sleep_in(ms, graph: graph_for(mod))
      end
    end

    test "passes for a clean module without Process.sleep" do
      mod = ConventionFixture.CleanModule
      ms = module_set_for(mod)
      assert Conventions.no_process_sleep_in(ms, graph: graph_for(mod)) == :ok
    end

    test "detects Process.sleep nested inside an if expression" do
      mod = ConventionFixture.WithNestedSleep
      ms = module_set_for(mod)

      assert_raise ExUnit.AssertionError, ~r/no_process_sleep_in/, fn ->
        Conventions.no_process_sleep_in(ms, graph: graph_for(mod))
      end
    end

    test "violation message mentions synchronization" do
      mod = ConventionFixture.WithProcessSleep
      ms = module_set_for(mod)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Conventions.no_process_sleep_in(ms, graph: graph_for(mod))
        end

      assert error.message =~ "synchronization"
    end
  end

  # ------------------------------------------------------------------
  # no_application_get_env_in/2
  # ------------------------------------------------------------------

  describe "no_application_get_env_in/2" do
    test "passes for modules without Application.get_env" do
      mod = ConventionFixture.CleanModule
      ms = module_set_for(mod)
      assert Conventions.no_application_get_env_in(ms, graph: graph_for(mod)) == :ok
    end

    test "detects Application.get_env call" do
      mod = ConventionFixture.WithApplicationGetEnv
      ms = module_set_for(mod)

      assert_raise ExUnit.AssertionError, ~r/no_application_get_env_in/, fn ->
        Conventions.no_application_get_env_in(ms, graph: graph_for(mod))
      end
    end

    test "detects Application.fetch_env call" do
      mod = ConventionFixture.WithFetchEnv
      ms = module_set_for(mod)

      assert_raise ExUnit.AssertionError, ~r/no_application_get_env_in/, fn ->
        Conventions.no_application_get_env_in(ms, graph: graph_for(mod))
      end
    end

    test "detects Application.fetch_env! call" do
      mod = ConventionFixture.WithFetchEnvBang
      ms = module_set_for(mod)

      assert_raise ExUnit.AssertionError, ~r/no_application_get_env_in/, fn ->
        Conventions.no_application_get_env_in(ms, graph: graph_for(mod))
      end
    end

    test "violation message mentions centralize" do
      mod = ConventionFixture.WithApplicationGetEnv
      ms = module_set_for(mod)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Conventions.no_application_get_env_in(ms, graph: graph_for(mod))
        end

      assert error.message =~ "centralize"
    end
  end

  # ------------------------------------------------------------------
  # no_dbg_in/2
  # ------------------------------------------------------------------

  describe "no_dbg_in/2" do
    test "passes when no module uses dbg" do
      mod = ConventionFixture.CleanModule
      ms = module_set_for(mod)
      assert Conventions.no_dbg_in(ms, graph: graph_for(mod)) == :ok
    end

    test "passes for empty module set" do
      ms = ModuleSet.satisfying(fn _ -> false end)
      assert Conventions.no_dbg_in(ms, graph: %{}) == :ok
    end

    test "detects dbg() call" do
      mod = ConventionFixture.WithDbg
      ms = module_set_for(mod)

      assert_raise ExUnit.AssertionError, ~r/no_dbg_in/, fn ->
        Conventions.no_dbg_in(ms, graph: graph_for(mod))
      end
    end

    test "violation message mentions debugging artifact" do
      mod = ConventionFixture.WithDbg
      ms = module_set_for(mod)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Conventions.no_dbg_in(ms, graph: graph_for(mod))
        end

      assert error.message =~ "debugging artifact"
    end
  end

  # ------------------------------------------------------------------
  # no_raise_string_in/2
  # ------------------------------------------------------------------

  describe "no_raise_string_in/2" do
    test "passes for empty module set" do
      ms = ModuleSet.satisfying(fn _ -> false end)
      assert Conventions.no_raise_string_in(ms, graph: %{}) == :ok
    end

    test "passes for modules that use typed exceptions" do
      mod = ConventionFixture.WithTypedRaise
      ms = module_set_for(mod)
      assert Conventions.no_raise_string_in(ms, graph: graph_for(mod)) == :ok
    end

    test "passes for clean module without raise" do
      mod = ConventionFixture.CleanModule
      ms = module_set_for(mod)
      assert Conventions.no_raise_string_in(ms, graph: graph_for(mod)) == :ok
    end

    test "detects raise with bare string" do
      mod = ConventionFixture.WithBareRaise
      ms = module_set_for(mod)

      assert_raise ExUnit.AssertionError, ~r/no_raise_string_in/, fn ->
        Conventions.no_raise_string_in(ms, graph: graph_for(mod))
      end
    end

    test "violation message mentions typed exceptions" do
      mod = ConventionFixture.WithBareRaise
      ms = module_set_for(mod)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Conventions.no_raise_string_in(ms, graph: graph_for(mod))
        end

      assert error.message =~ "defexception"
    end
  end

  # ------------------------------------------------------------------
  # all_public_functions_documented/2
  # ------------------------------------------------------------------

  describe "all_public_functions_documented/2" do
    test "passes for empty module set" do
      ms = ModuleSet.satisfying(fn _mod -> false end)
      assert Conventions.all_public_functions_documented(ms, graph: %{}) == :ok
    end

    test "passes for modules that are not loaded (no docs available)" do
      graph = %{:fake_nonexistent_module_xyz => []}
      ms = ModuleSet.new("fake_nonexistent_module_xyz")
      assert Conventions.all_public_functions_documented(ms, graph: graph) == :ok
    end

    test "passes for a fully documented module" do
      mod = ConventionFixture.FullyDocumentedModule
      ms = module_set_for(mod)
      assert Conventions.all_public_functions_documented(ms, graph: graph_for(mod)) == :ok
    end

    test "detects undocumented public functions" do
      mod = ConventionFixture.UndocumentedModule
      ms = module_set_for(mod)

      error =
        assert_raise ExUnit.AssertionError, ~r/all_public_functions_documented/, fn ->
          Conventions.all_public_functions_documented(ms, graph: graph_for(mod))
        end

      assert error.message =~ "undocumented_func"
      assert error.message =~ "another_undoc"
    end

    test "treats @doc false as undocumented" do
      mod = ConventionFixture.DocFalseModule
      ms = module_set_for(mod)

      error =
        assert_raise ExUnit.AssertionError, ~r/all_public_functions_documented/, fn ->
          Conventions.all_public_functions_documented(ms, graph: graph_for(mod))
        end

      # hidden_func has @doc false and should be flagged
      assert error.message =~ "hidden_func"
      # visible_func has @doc "..." and should NOT be flagged
      refute error.message =~ "visible_func"
    end

    test "checks loaded Elixir module for documentation" do
      # ArchTest.Pattern is a fully documented module (no defstruct), should pass
      graph = %{ArchTest.Pattern => []}
      ms = ModuleSet.satisfying(fn mod -> mod == ArchTest.Pattern end)
      assert Conventions.all_public_functions_documented(ms, graph: graph) == :ok
    end
  end

  # ------------------------------------------------------------------
  # no_plug_in/2
  # ------------------------------------------------------------------

  describe "no_plug_in/2" do
    test "passes when no module depends on Plug — empty graph" do
      ms = ModuleSet.all()
      assert Conventions.no_plug_in(ms, graph: %{}) == :ok
    end

    test "passes when modules don't depend on Plug/Phoenix" do
      graph = %{
        :"MyApp.Domain.Order" => [:"MyApp.Domain.Item"],
        :"MyApp.Domain.Item" => []
      }

      ms = ModuleSet.new("MyApp.Domain.**")
      assert Conventions.no_plug_in(ms, graph: graph) == :ok
    end

    test "fails when module depends on Plug.Conn" do
      graph = %{
        MyApp.Domain.BadModule => [Plug.Conn],
        Plug.Conn => []
      }

      ms = ModuleSet.satisfying(fn mod -> mod == MyApp.Domain.BadModule end)

      assert_raise ExUnit.AssertionError, ~r/no_plug_in/, fn ->
        Conventions.no_plug_in(ms, graph: graph)
      end
    end

    test "fails when module depends on Plug.Builder" do
      graph = %{
        MyApp.Domain.RouterUser => [Plug.Builder],
        Plug.Builder => []
      }

      ms = ModuleSet.satisfying(fn mod -> mod == MyApp.Domain.RouterUser end)

      assert_raise ExUnit.AssertionError, ~r/no_plug_in/, fn ->
        Conventions.no_plug_in(ms, graph: graph)
      end
    end

    test "fails when module depends on Plug.Router" do
      graph = %{
        MyApp.Domain.PlugRouter => [Plug.Router],
        Plug.Router => []
      }

      ms = ModuleSet.satisfying(fn mod -> mod == MyApp.Domain.PlugRouter end)

      assert_raise ExUnit.AssertionError, ~r/no_plug_in/, fn ->
        Conventions.no_plug_in(ms, graph: graph)
      end
    end

    test "fails when module depends on Phoenix.Controller" do
      graph = %{
        MyApp.Domain.PhoenixUser => [Phoenix.Controller],
        Phoenix.Controller => []
      }

      ms = ModuleSet.satisfying(fn mod -> mod == MyApp.Domain.PhoenixUser end)

      assert_raise ExUnit.AssertionError, ~r/no_plug_in/, fn ->
        Conventions.no_plug_in(ms, graph: graph)
      end
    end
  end

  # ------------------------------------------------------------------
  # assert_no_violations_public/2
  # ------------------------------------------------------------------

  describe "assert_no_violations_public/2" do
    test "passes when violations list is empty" do
      assert ArchTest.Assertions.assert_no_violations_public([], "test_rule") == :ok
    end

    test "raises AssertionError when violations present" do
      violations = [Violation.forbidden_dep(A, B, "test")]

      assert_raise ExUnit.AssertionError, ~r/test_rule/, fn ->
        ArchTest.Assertions.assert_no_violations_public(violations, "test_rule")
      end
    end

    test "error message includes violation count" do
      violations = [
        Violation.forbidden_dep(A, B, "v1"),
        Violation.forbidden_dep(B, C, "v2")
      ]

      assert_raise ExUnit.AssertionError, ~r/2 violation/, fn ->
        ArchTest.Assertions.assert_no_violations_public(violations, "test_rule")
      end
    end
  end

  # ------------------------------------------------------------------
  # Multiple violations in a single scan
  # ------------------------------------------------------------------

  describe "multiple modules in a single check" do
    test "no_io_puts_in detects violations across multiple modules" do
      mods = [ConventionFixture.WithIoPuts, ConventionFixture.WithIoInspect]

      graph =
        mods
        |> Enum.map(fn mod -> {mod, []} end)
        |> Map.new()

      ms = ModuleSet.satisfying(fn m -> m in mods end)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Conventions.no_io_puts_in(ms, graph: graph)
        end

      assert error.message =~ "2 violation"
    end

    test "mixed set of clean and violating modules only flags violators" do
      clean_mod = ConventionFixture.CleanModule
      bad_mod = ConventionFixture.WithProcessSleep

      graph = %{clean_mod => [], bad_mod => []}
      ms = ModuleSet.satisfying(fn m -> m in [clean_mod, bad_mod] end)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Conventions.no_process_sleep_in(ms, graph: graph)
        end

      assert error.message =~ "1 violation"
      assert error.message =~ "WithProcessSleep"
      refute error.message =~ "CleanModule"
    end
  end
end
