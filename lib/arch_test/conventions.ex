defmodule ArchTest.Conventions do
  @moduledoc """
  Pre-built assertion helpers for common Elixir coding conventions.

  Import this module (via `use ArchTest.Conventions`) to access pre-built
  rules that go beyond dependency checking.

  ## Usage

      defmodule MyApp.ConventionTest do
        use ExUnit.Case
        use ArchTest
        use ArchTest.Conventions

        test "no IO.puts in production code" do
          assert no_io_puts_in(modules_matching("MyApp.**"))
        end

        test "domain modules don't use Plug" do
          assert no_plug_in(modules_matching("MyApp.Domain.**"))
        end
      end
  """

  alias ArchTest.{Assertions, Collector, ModuleSet, Violation}

  defmacro __using__(_opts) do
    quote do
      import ArchTest.Conventions
    end
  end

  @doc """
  Asserts that no module in `subject` has `IO.puts` or `IO.inspect` calls.

  These are debugging artifacts that should not appear in production modules.
  """
  @spec no_io_puts_in(ModuleSet.t(), keyword()) :: :ok
  def no_io_puts_in(%ModuleSet{} = subject, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)

    violations =
      for mod <- subject_mods,
          uses_io_debug?(mod) do
        %Violation{
          type: :custom,
          module: mod,
          message: "module contains IO.puts or IO.inspect calls (debugging artifact)"
        }
      end

    Assertions.assert_no_violations_public(violations, "no_io_puts_in")
  end

  @doc """
  Asserts that no module in `subject` directly uses `Plug`.

  Useful to keep domain/application modules free from web framework coupling.
  """
  @spec no_plug_in(ModuleSet.t(), keyword()) :: :ok
  def no_plug_in(%ModuleSet{} = subject, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)

    plug_modules =
      graph
      |> Map.keys()
      |> Enum.filter(fn mod ->
        str = Atom.to_string(mod)
        String.starts_with?(str, "Elixir.Plug") or str == "Elixir.Phoenix.Controller"
      end)
      |> MapSet.new()

    violations =
      for mod <- subject_mods,
          dep <- Collector.dependencies_of(graph, mod),
          MapSet.member?(plug_modules, dep) do
        Violation.forbidden_dep(mod, dep, "domain module must not depend on Plug/Phoenix")
      end

    Assertions.assert_no_violations_public(violations, "no_plug_in")
  end

  @doc """
  Asserts that all public functions in `subject` modules have documentation.

  A public function is considered documented if its module has a `@moduledoc`
  and none of its functions are missing `@doc` (i.e., `@doc false` or missing
  docs are both treated as undocumented).

  This check inspects `:beam_lib` chunk data.
  """
  @spec all_public_functions_documented(ModuleSet.t(), keyword()) :: :ok
  def all_public_functions_documented(%ModuleSet{} = subject, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)

    violations =
      Enum.flat_map(subject_mods, fn mod ->
        undoc = undocumented_public_functions(mod)

        Enum.map(undoc, fn {fun, arity} ->
          %Violation{
            type: :custom,
            module: mod,
            message: "#{inspect(mod)}.#{fun}/#{arity} is a public function without @doc"
          }
        end)
      end)

    Assertions.assert_no_violations_public(violations, "all_public_functions_documented")
  end

  @doc """
  Asserts that no module in `subject` calls `Process.sleep/1`.

  `Process.sleep` in production code is a code smell — it indicates polling,
  artificial delays, or race condition workarounds. Use proper synchronization
  mechanisms instead.
  """
  @spec no_process_sleep_in(ModuleSet.t(), keyword()) :: :ok
  def no_process_sleep_in(%ModuleSet{} = subject, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)

    violations =
      for mod <- subject_mods,
          uses_process_sleep?(mod) do
        %Violation{
          type: :custom,
          module: mod,
          message: "module calls Process.sleep/1 — use proper synchronization instead"
        }
      end

    Assertions.assert_no_violations_public(violations, "no_process_sleep_in")
  end

  @doc """
  Asserts that no module in `subject` calls `Application.get_env/2,3` directly.

  Direct `Application.get_env` calls scattered across the codebase make
  configuration harder to find and test. Centralize config access in a
  dedicated config module.
  """
  @spec no_application_get_env_in(ModuleSet.t(), keyword()) :: :ok
  def no_application_get_env_in(%ModuleSet{} = subject, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)

    violations =
      for mod <- subject_mods,
          uses_application_get_env?(mod) do
        %Violation{
          type: :custom,
          module: mod,
          message:
            "module calls Application.get_env directly — centralize config access in a dedicated module"
        }
      end

    Assertions.assert_no_violations_public(violations, "no_application_get_env_in")
  end

  @doc """
  Asserts that no module in `subject` calls `dbg/0,1,2` (Elixir 1.14+ debug macro).

  `dbg` calls are debugging artifacts that must not appear in production code.
  """
  @spec no_dbg_in(ModuleSet.t(), keyword()) :: :ok
  def no_dbg_in(%ModuleSet{} = subject, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)

    violations =
      for mod <- subject_mods,
          uses_dbg?(mod) do
        %Violation{
          type: :custom,
          module: mod,
          message: "module contains dbg/0,1,2 calls (debugging artifact)"
        }
      end

    Assertions.assert_no_violations_public(violations, "no_dbg_in")
  end

  @doc """
  Asserts that no module in `subject` raises a bare string (i.e., `raise "message"`).

  Bare string raises produce `RuntimeError` with no structured data. Use typed
  errors (`defexception`) or `raise MyError, key: value` instead for better
  error handling and pattern matching.
  """
  @spec no_raise_string_in(ModuleSet.t(), keyword()) :: :ok
  def no_raise_string_in(%ModuleSet{} = subject, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)

    violations =
      for mod <- subject_mods,
          uses_bare_raise?(mod) do
        %Violation{
          type: :custom,
          module: mod,
          message:
            "module uses `raise \"string\"` — use typed exceptions with defexception instead"
        }
      end

    Assertions.assert_no_violations_public(violations, "no_raise_string_in")
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp get_graph(opts) do
    case Keyword.get(opts, :graph) do
      nil -> Collector.build_graph(Keyword.get(opts, :app, :all))
      graph -> graph
    end
  end

  defp uses_io_debug?(mod) do
    scan_abstract_code(mod, &contains_io_call?/1)
  end

  defp uses_process_sleep?(mod) do
    scan_abstract_code(mod, &contains_process_sleep?/1)
  end

  defp uses_application_get_env?(mod) do
    scan_abstract_code(mod, &contains_application_get_env?/1)
  end

  defp uses_dbg?(mod) do
    scan_abstract_code(mod, &contains_dbg_call?/1)
  end

  defp uses_bare_raise?(mod) do
    scan_abstract_code(mod, &contains_bare_raise?/1)
  end

  # Shared scanner — extracts the beam_lib boilerplate used by all
  # abstract-code-based detectors. Returns true if the checker function
  # returns true for any form in the module's abstract code.
  #
  # Supports both BEAM formats:
  # - Legacy: :abstract_code chunk (Erlang/OTP pre-24, older Elixir)
  # - Modern: :debug_info chunk with :elixir_erl backend (Elixir 1.14+)
  defp scan_abstract_code(mod, checker) do
    beam_path = :code.which(mod)

    if is_list(beam_path) and beam_path != [] do
      forms = get_abstract_forms(beam_path, mod)
      Enum.any?(forms, checker)
    else
      false
    end
  end

  defp get_abstract_forms(beam_path, mod) do
    # Try legacy :abstract_code chunk first
    case :beam_lib.chunks(beam_path, [:abstract_code]) do
      {:ok, {_, [{:abstract_code, {_, forms}}]}} ->
        forms

      _ ->
        # Fall back to modern :debug_info chunk (Elixir 1.14+ default)
        case :beam_lib.chunks(beam_path, [:debug_info]) do
          {:ok, {_, [{:debug_info, {:debug_info_v1, backend, data}}]}} ->
            case backend.debug_info(:erlang_v1, mod, data, []) do
              {:ok, forms} -> forms
              _ -> []
            end

          _ ->
            []
        end
    end
  end

  # ------------------------------------------------------------------
  # IO.puts / IO.inspect / IO.write call detector
  # ------------------------------------------------------------------

  defp contains_io_call?({:call, _, {:remote, _, {:atom, _, :io}, {:atom, _, fun}}, _args})
       when fun in [:format, :write, :fwrite, :nl] do
    true
  end

  defp contains_io_call?({:call, _, {:remote, _, {:atom, _, :"Elixir.IO"}, {:atom, _, fun}}, _})
       when fun in [:puts, :inspect, :write] do
    true
  end

  defp contains_io_call?({:call, _, {:remote, _, {:atom, _, :elixir}, {:atom, _, :inspect}}, _}) do
    true
  end

  defp contains_io_call?(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.any?(&contains_io_call?/1)
  end

  defp contains_io_call?(list) when is_list(list) do
    Enum.any?(list, &contains_io_call?/1)
  end

  defp contains_io_call?(_), do: false

  # ------------------------------------------------------------------
  # Process.sleep/1 call detector
  # ------------------------------------------------------------------

  defp contains_process_sleep?(
         {:call, _, {:remote, _, {:atom, _, :"Elixir.Process"}, {:atom, _, :sleep}}, _}
       ) do
    true
  end

  defp contains_process_sleep?(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.any?(&contains_process_sleep?/1)
  end

  defp contains_process_sleep?(list) when is_list(list) do
    Enum.any?(list, &contains_process_sleep?/1)
  end

  defp contains_process_sleep?(_), do: false

  # ------------------------------------------------------------------
  # Application.get_env / fetch_env / fetch_env! call detector
  # ------------------------------------------------------------------

  defp contains_application_get_env?(
         {:call, _, {:remote, _, {:atom, _, :"Elixir.Application"}, {:atom, _, fun}}, _}
       )
       when fun in [:get_env, :fetch_env, :fetch_env!] do
    true
  end

  defp contains_application_get_env?(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.any?(&contains_application_get_env?/1)
  end

  defp contains_application_get_env?(list) when is_list(list) do
    Enum.any?(list, &contains_application_get_env?/1)
  end

  defp contains_application_get_env?(_), do: false

  # ------------------------------------------------------------------
  # dbg/0,1,2 call detector
  # Elixir compiles dbg to Macro.__dbg__/3 (Elixir 1.14+) or
  # Macro.dbg / Kernel.dbg calls depending on the version and context.
  # ------------------------------------------------------------------

  defp contains_dbg_call?(
         {:call, _, {:remote, _, {:atom, _, :"Elixir.Macro"}, {:atom, _, :dbg}}, _}
       ) do
    true
  end

  # Elixir 1.14+ compiles dbg() to Macro.__dbg__/3
  defp contains_dbg_call?(
         {:call, _, {:remote, _, {:atom, _, :"Elixir.Macro"}, {:atom, _, :__dbg__}}, _}
       ) do
    true
  end

  defp contains_dbg_call?(
         {:call, _, {:remote, _, {:atom, _, :"Elixir.Kernel"}, {:atom, _, :dbg}}, _}
       ) do
    true
  end

  defp contains_dbg_call?(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.any?(&contains_dbg_call?/1)
  end

  defp contains_dbg_call?(list) when is_list(list) do
    Enum.any?(list, &contains_dbg_call?/1)
  end

  defp contains_dbg_call?(_), do: false

  # ------------------------------------------------------------------
  # Bare raise/1 with string literal detector
  #
  # In BEAM abstract code, `raise "msg"` compiles to an :erlang.error
  # call with a RuntimeError struct. We detect both the Kernel.raise/1
  # pattern and the :erlang.error({RuntimeError, ...}) pattern.
  #
  # NOTE: The exact abstract code representation may vary across Elixir
  # versions. This detector avoids false positives by returning false
  # when the pattern is not recognized.
  # ------------------------------------------------------------------

  defp contains_bare_raise?(
         {:call, _, {:remote, _, {:atom, _, :"Elixir.Kernel"}, {:atom, _, :raise}},
          [{:bin, _, _}]}
       ) do
    true
  end

  # Match :erlang.error({%RuntimeError{...}}) pattern
  defp contains_bare_raise?(
         {:call, _, {:remote, _, {:atom, _, :erlang}, {:atom, _, :error}}, [arg | _]}
       ) do
    contains_runtime_error_tuple?(arg)
  end

  defp contains_bare_raise?(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.any?(&contains_bare_raise?/1)
  end

  defp contains_bare_raise?(list) when is_list(list) do
    Enum.any?(list, &contains_bare_raise?/1)
  end

  defp contains_bare_raise?(_), do: false

  defp contains_runtime_error_tuple?({:tuple, _, [{:atom, _, :"Elixir.RuntimeError"} | _]}),
    do: true

  defp contains_runtime_error_tuple?(
         {:map, _,
          [{:map_field_assoc, _, {:atom, _, :__struct__}, {:atom, _, :"Elixir.RuntimeError"}} | _]}
       ),
       do: true

  # Elixir 1.15+ compiles `raise "msg"` to :erlang.error(RuntimeError.exception("msg"), ...)
  # The first arg is a call to RuntimeError.exception/1 with a binary argument.
  defp contains_runtime_error_tuple?(
         {:call, _, {:remote, _, {:atom, _, :"Elixir.RuntimeError"}, {:atom, _, :exception}},
          [{:bin, _, _}]}
       ),
       do: true

  defp contains_runtime_error_tuple?(_), do: false

  defp undocumented_public_functions(mod) do
    try do
      docs = Code.fetch_docs(mod)

      case docs do
        {:docs_v1, _, _, _, _, _, fn_docs} ->
          fn_docs
          |> Enum.filter(fn
            {{:function, _fun, _arity}, _, _, doc, _meta} ->
              doc == :none or doc == :hidden or doc == %{}

            _ ->
              false
          end)
          |> Enum.map(fn {{:function, fun, arity}, _, _, _, _} -> {fun, arity} end)

        _ ->
          []
      end
    rescue
      _ -> []
    end
  end
end
