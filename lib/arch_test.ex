defmodule ArchTest do
  @moduledoc """
  ArchUnit-inspired architecture testing library for Elixir.

  Write ExUnit tests that enforce architectural rules — dependency direction,
  layer boundaries, bounded-context isolation, and naming conventions —
  using a fluent, pipe-based DSL.

  ## Quick start

      defmodule MyApp.ArchitectureTest do
        use ExUnit.Case
        use ArchTest, app: :my_app

        test "service modules don't call repos directly" do
          modules_matching("MyApp.**.*Service")
          |> should_not_depend_on(modules_matching("MyApp.**.*Repo"))
        end

        test "no Manager modules exist" do
          modules_matching("MyApp.**.*Manager") |> should_not_exist()
        end
      end

  ## Options for `use ArchTest`

  - `:app` — OTP app atom to limit introspection (default: `:all`)
  - `:freeze` — `true` to auto-freeze all rules in the module (default: `false`)

  ## Module reference

  - `ArchTest.ModuleSet` — module selection and filtering DSL
  - `ArchTest.Assertions` — core assertion functions
  - `ArchTest.Layers` — layered architecture enforcement
  - `ArchTest.Modulith` — bounded-context / modulith isolation
  - `ArchTest.Freeze` — violation baseline / freezing
  - `ArchTest.Metrics` — coupling/instability metrics
  - `ArchTest.Conventions` — pre-built Elixir convention rules
  - `ArchTest.Effects` — N+1 queries, pure functional cores and GenServer init, through every call
  - `ArchTest.Processes` — one interface per process, GenServers with a reason to exist, supervision
  - `ArchTest.TestCode` — tests that use their subject, mock only I/O, don't sleep, and stay isolated
  - `ArchTest.Guardrails` — no silenced warnings, no stubs, nothing public only for tests
  - `ArchTest.Recommended` — the design rules worth holding any project to, as one test
  - `ArchTest.Collector` — BEAM dependency graph builder
  - `ArchTest.Pattern` — glob pattern matching
  """

  alias ArchTest.{Assertions, Layers, ModuleSet, Modulith}

  @doc false
  defmacro __using__(opts \\ []) do
    app = Keyword.get(opts, :app, :all)
    freeze = Keyword.get(opts, :freeze, false)
    excluded_imports = __using_import_excludes__()

    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
      import ArchTest, except: unquote(excluded_imports)

      # Stash the app option so DSL functions can pick it up.
      @arch_test_app unquote(app)
      @arch_test_freeze unquote(freeze)

      @doc false
      def arch_test_opts, do: [app: @arch_test_app]

      @doc false
      def arch_test_opts(opts) when is_list(opts), do: Keyword.merge(arch_test_opts(), opts)

      defp __arch_test_run__(rule_name, args, opts, assertion_fn) do
        opts = arch_test_opts(opts)

        if @arch_test_freeze do
          rule_id =
            Keyword.get_lazy(opts, :rule_id, fn ->
              ArchTest.Freeze.rule_id(__MODULE__, rule_name, [
                args,
                __arch_test_scope_opts__(opts)
              ])
            end)

          ArchTest.Freeze.freeze(rule_id, assertion_fn)
        else
          assertion_fn.()
        end
      end

      defp __arch_test_scope_opts__(opts) do
        Keyword.take(opts, [:app, :apps, :paths, :include, :exclude])
      end

      def modules_matching(pattern), do: ArchTest.modules_matching(pattern)
      def modules_in(namespace), do: ArchTest.modules_in(namespace)
      def all_modules, do: ArchTest.all_modules()
      def modules_satisfying(filter_fn), do: ArchTest.modules_satisfying(filter_fn)

      def should_not_depend_on(subject, object, opts \\ []) do
        __arch_test_run__("should_not_depend_on", [subject, object], opts, fn ->
          ArchTest.should_not_depend_on(subject, object, arch_test_opts(opts))
        end)
      end

      def should_only_depend_on(subject, allowed, opts \\ []) do
        __arch_test_run__("should_only_depend_on", [subject, allowed], opts, fn ->
          ArchTest.should_only_depend_on(subject, allowed, arch_test_opts(opts))
        end)
      end

      def should_not_be_called_by(object, callers, opts \\ []) do
        __arch_test_run__("should_not_be_called_by", [object, callers], opts, fn ->
          ArchTest.should_not_be_called_by(object, callers, arch_test_opts(opts))
        end)
      end

      def should_only_be_called_by(object, allowed_callers, opts \\ []) do
        __arch_test_run__("should_only_be_called_by", [object, allowed_callers], opts, fn ->
          ArchTest.should_only_be_called_by(object, allowed_callers, arch_test_opts(opts))
        end)
      end

      def should_not_transitively_depend_on(subject, object, opts \\ []) do
        __arch_test_run__("should_not_transitively_depend_on", [subject, object], opts, fn ->
          ArchTest.should_not_transitively_depend_on(subject, object, arch_test_opts(opts))
        end)
      end

      def should_not_exist(subject, opts \\ []) do
        __arch_test_run__("should_not_exist", [subject], opts, fn ->
          ArchTest.should_not_exist(subject, arch_test_opts(opts))
        end)
      end

      def should_reside_under(subject, namespace_pattern, opts \\ []) do
        __arch_test_run__("should_reside_under", [subject, namespace_pattern], opts, fn ->
          ArchTest.should_reside_under(subject, namespace_pattern, arch_test_opts(opts))
        end)
      end

      def should_have_name_matching(subject, name_pattern, opts \\ []) do
        __arch_test_run__("should_have_name_matching", [subject, name_pattern], opts, fn ->
          ArchTest.should_have_name_matching(subject, name_pattern, arch_test_opts(opts))
        end)
      end

      def should_be_free_of_cycles(subject, opts \\ []) do
        __arch_test_run__("should_be_free_of_cycles", [subject], opts, fn ->
          ArchTest.should_be_free_of_cycles(subject, arch_test_opts(opts))
        end)
      end

      def should_have_module_count(subject, constraints, opts \\ []) do
        run_opts =
          constraints
          |> Keyword.take([:app, :apps, :paths, :include, :exclude, :rule_id])
          |> Keyword.merge(opts)

        semantic_constraints =
          Keyword.drop(constraints, [
            :graph,
            :app,
            :apps,
            :paths,
            :include,
            :exclude,
            :force,
            :message,
            :rule_id,
            :allow_empty
          ])

        __arch_test_run__(
          "should_have_module_count",
          [subject, semantic_constraints],
          run_opts,
          fn ->
            constraints_with_default_scope = Keyword.merge(arch_test_opts(), constraints)
            ArchTest.should_have_module_count(subject, constraints_with_default_scope, opts)
          end
        )
      end

      def satisfying(subject, check_fn, opts \\ []) do
        __arch_test_run__("satisfying", [subject, check_fn], opts, fn ->
          ArchTest.satisfying(subject, check_fn, arch_test_opts(opts))
        end)
      end

      def should_implement_behaviour(subject, behaviour, opts \\ []) do
        __arch_test_run__("should_implement_behaviour", [subject, behaviour], opts, fn ->
          ArchTest.should_implement_behaviour(subject, behaviour, arch_test_opts(opts))
        end)
      end

      def should_not_implement_behaviour(subject, behaviour, opts \\ []) do
        __arch_test_run__("should_not_implement_behaviour", [subject, behaviour], opts, fn ->
          ArchTest.should_not_implement_behaviour(subject, behaviour, arch_test_opts(opts))
        end)
      end

      def should_implement_protocol(subject, protocol, opts \\ []) do
        __arch_test_run__("should_implement_protocol", [subject, protocol], opts, fn ->
          ArchTest.should_implement_protocol(subject, protocol, arch_test_opts(opts))
        end)
      end

      def should_not_implement_protocol(subject, protocol, opts \\ []) do
        __arch_test_run__("should_not_implement_protocol", [subject, protocol], opts, fn ->
          ArchTest.should_not_implement_protocol(subject, protocol, arch_test_opts(opts))
        end)
      end

      def should_have_attribute(subject, attr_key, opts \\ []) do
        __arch_test_run__("should_have_attribute", [subject, attr_key], opts, fn ->
          ArchTest.should_have_attribute(subject, attr_key, arch_test_opts(opts))
        end)
      end

      def should_not_have_attribute(subject, attr_key, opts \\ []) do
        __arch_test_run__("should_not_have_attribute", [subject, attr_key], opts, fn ->
          ArchTest.should_not_have_attribute(subject, attr_key, arch_test_opts(opts))
        end)
      end

      def should_have_attribute_value(subject, attr_key, attr_value, opts \\ []) do
        __arch_test_run__(
          "should_have_attribute_value",
          [subject, attr_key, attr_value],
          opts,
          fn ->
            ArchTest.should_have_attribute_value(
              subject,
              attr_key,
              attr_value,
              arch_test_opts(opts)
            )
          end
        )
      end

      def should_not_have_attribute_value(subject, attr_key, attr_value, opts \\ []) do
        __arch_test_run__(
          "should_not_have_attribute_value",
          [subject, attr_key, attr_value],
          opts,
          fn ->
            ArchTest.should_not_have_attribute_value(
              subject,
              attr_key,
              attr_value,
              arch_test_opts(opts)
            )
          end
        )
      end

      def should_use(subject, used_module, opts \\ []) do
        __arch_test_run__("should_use", [subject, used_module], opts, fn ->
          ArchTest.should_use(subject, used_module, arch_test_opts(opts))
        end)
      end

      def should_not_use(subject, used_module, opts \\ []) do
        __arch_test_run__("should_not_use", [subject, used_module], opts, fn ->
          ArchTest.should_not_use(subject, used_module, arch_test_opts(opts))
        end)
      end

      def should_export(subject, fun_name, arity, opts \\ []) do
        __arch_test_run__("should_export", [subject, fun_name, arity], opts, fn ->
          ArchTest.should_export(subject, fun_name, arity, arch_test_opts(opts))
        end)
      end

      def should_not_export(subject, fun_name, arity, opts \\ []) do
        __arch_test_run__("should_not_export", [subject, fun_name, arity], opts, fn ->
          ArchTest.should_not_export(subject, fun_name, arity, arch_test_opts(opts))
        end)
      end

      def should_have_public_functions_matching(subject, pattern, opts \\ []) do
        __arch_test_run__("should_have_public_functions_matching", [subject, pattern], opts, fn ->
          ArchTest.should_have_public_functions_matching(subject, pattern, arch_test_opts(opts))
        end)
      end

      def should_not_have_public_functions_matching(subject, pattern, opts \\ []) do
        __arch_test_run__(
          "should_not_have_public_functions_matching",
          [subject, pattern],
          opts,
          fn ->
            ArchTest.should_not_have_public_functions_matching(
              subject,
              pattern,
              arch_test_opts(opts)
            )
          end
        )
      end

      def define_layers(layer_defs), do: ArchTest.define_layers(layer_defs, arch_test_opts())

      def define_layers(layer_defs, opts),
        do: ArchTest.define_layers(layer_defs, arch_test_opts(opts))

      def define_onion(layer_defs), do: ArchTest.define_onion(layer_defs, arch_test_opts())

      def define_onion(layer_defs, opts),
        do: ArchTest.define_onion(layer_defs, arch_test_opts(opts))

      def define_slices(slice_defs), do: ArchTest.define_slices(slice_defs, arch_test_opts())

      def define_slices(slice_defs, opts),
        do: ArchTest.define_slices(slice_defs, arch_test_opts(opts))

      def define_slices_by(pattern, opts \\ []),
        do: ArchTest.define_slices_by(pattern, arch_test_opts(opts))

      def enforce_direction(layers, opts \\ []) do
        __arch_test_run__("enforce_direction", [layers], opts, fn ->
          ArchTest.enforce_direction(layers, arch_test_opts(opts))
        end)
      end

      def enforce_onion_rules(layers, opts \\ []) do
        __arch_test_run__("enforce_onion_rules", [layers], opts, fn ->
          ArchTest.enforce_onion_rules(layers, arch_test_opts(opts))
        end)
      end

      def allow_dependency(modulith, from_slice, to_slice),
        do: ArchTest.allow_dependency(modulith, from_slice, to_slice)

      def allow_layer_dependency(layers, from_layer, to_layer),
        do: ArchTest.allow_layer_dependency(layers, from_layer, to_layer)

      def enforce_isolation(modulith, opts \\ []) do
        __arch_test_run__("enforce_isolation", [modulith], opts, fn ->
          ArchTest.enforce_isolation(modulith, arch_test_opts(opts))
        end)
      end

      def should_not_depend_on_each_other(modulith, opts \\ []) do
        __arch_test_run__("should_not_depend_on_each_other", [modulith], opts, fn ->
          ArchTest.should_not_depend_on_each_other(modulith, arch_test_opts(opts))
        end)
      end

      def all_modules_covered_by(modulith, namespace_pattern, opts \\ []) do
        __arch_test_run__("all_modules_covered_by", [modulith, namespace_pattern], opts, fn ->
          ArchTest.all_modules_covered_by(modulith, namespace_pattern, arch_test_opts(opts))
        end)
      end
    end
  end

  @doc false
  def __using_import_excludes__ do
    [
      modules_matching: 1,
      modules_in: 1,
      all_modules: 0,
      modules_satisfying: 1,
      should_not_depend_on: 2,
      should_not_depend_on: 3,
      should_only_depend_on: 2,
      should_only_depend_on: 3,
      should_not_be_called_by: 2,
      should_not_be_called_by: 3,
      should_only_be_called_by: 2,
      should_only_be_called_by: 3,
      should_not_transitively_depend_on: 2,
      should_not_transitively_depend_on: 3,
      should_not_exist: 1,
      should_not_exist: 2,
      should_reside_under: 2,
      should_reside_under: 3,
      should_have_name_matching: 2,
      should_have_name_matching: 3,
      should_be_free_of_cycles: 1,
      should_be_free_of_cycles: 2,
      should_have_module_count: 2,
      should_have_module_count: 3,
      satisfying: 2,
      satisfying: 3,
      should_implement_behaviour: 2,
      should_implement_behaviour: 3,
      should_not_implement_behaviour: 2,
      should_not_implement_behaviour: 3,
      should_implement_protocol: 2,
      should_implement_protocol: 3,
      should_not_implement_protocol: 2,
      should_not_implement_protocol: 3,
      should_have_attribute: 2,
      should_have_attribute: 3,
      should_not_have_attribute: 2,
      should_not_have_attribute: 3,
      should_have_attribute_value: 3,
      should_have_attribute_value: 4,
      should_not_have_attribute_value: 3,
      should_not_have_attribute_value: 4,
      should_use: 2,
      should_use: 3,
      should_not_use: 2,
      should_not_use: 3,
      should_export: 3,
      should_export: 4,
      should_not_export: 3,
      should_not_export: 4,
      should_have_public_functions_matching: 2,
      should_have_public_functions_matching: 3,
      should_not_have_public_functions_matching: 2,
      should_not_have_public_functions_matching: 3,
      define_layers: 1,
      define_layers: 2,
      define_onion: 1,
      define_onion: 2,
      define_slices: 1,
      define_slices: 2,
      define_slices_by: 1,
      define_slices_by: 2,
      enforce_direction: 1,
      enforce_direction: 2,
      enforce_onion_rules: 1,
      enforce_onion_rules: 2,
      allow_dependency: 3,
      allow_layer_dependency: 3,
      enforce_isolation: 1,
      enforce_isolation: 2,
      should_not_depend_on_each_other: 1,
      should_not_depend_on_each_other: 2,
      all_modules_covered_by: 2,
      all_modules_covered_by: 3
    ]
  end

  # ------------------------------------------------------------------
  # Module selection DSL
  # ------------------------------------------------------------------

  @doc """
  Returns a `ModuleSet` for modules matching the given glob pattern.

  ## Pattern semantics

  | Pattern | Matches |
  |---------|---------|
  | `"MyApp.Orders.*"` | Direct children only |
  | `"MyApp.Orders.**"` | All descendants at any depth |
  | `"MyApp.Orders"` | Exact match only |
  | `"**.*Service"` | Last segment ends with `Service` |
  | `"**.*Service*"` | Last segment contains `Service` |

  ## Example

      modules_matching("**.*Controller")
      |> should_not_depend_on(modules_matching("**.*Repo"))
  """
  @spec modules_matching(String.t()) :: ModuleSet.t()
  def modules_matching(pattern), do: ModuleSet.new(pattern)

  @doc """
  Returns a `ModuleSet` for all direct children of `namespace`.

  Shorthand for `modules_matching("Namespace.*")`.

  ## Example

      modules_in("MyApp.Orders")
      # equivalent to modules_matching("MyApp.Orders.*")
  """
  @spec modules_in(String.t()) :: ModuleSet.t()
  def modules_in(namespace), do: ModuleSet.in_namespace(namespace)

  @doc """
  Returns a `ModuleSet` matching every module in the application.
  """
  @spec all_modules() :: ModuleSet.t()
  def all_modules, do: ModuleSet.all()

  @doc """
  Returns a `ModuleSet` matching modules that satisfy a custom predicate.

  ## Example

      modules_satisfying(fn mod ->
        function_exported?(mod, :__schema__, 1)
      end)
      |> should_reside_under("MyApp.**.Schemas")
  """
  @spec modules_satisfying((module() -> boolean())) :: ModuleSet.t()
  def modules_satisfying(filter_fn), do: ModuleSet.satisfying(filter_fn)

  # ------------------------------------------------------------------
  # ModuleSet composition (re-exported for convenience)
  # ------------------------------------------------------------------

  @doc """
  Excludes modules matching `pattern` from a `ModuleSet`.

  ## Example

      modules_matching("MyApp.**")
      |> excluding("MyApp.Test.*")
  """
  defdelegate excluding(module_set, pattern), to: ModuleSet

  @doc """
  Combines two `ModuleSet`s (union / OR).

  ## Example

      modules_matching("**.*Service")
      |> union(modules_matching("**.*View"))
  """
  defdelegate union(a, b), to: ModuleSet

  @doc """
  Returns modules present in both `ModuleSet`s (intersection / AND).
  """
  defdelegate intersection(a, b), to: ModuleSet

  # ------------------------------------------------------------------
  # Assertion functions (delegated to ArchTest.Assertions)
  # ------------------------------------------------------------------

  @doc """
  Asserts that no module in `subject` directly depends on modules in `object`.
  """
  defdelegate should_not_depend_on(subject, object, opts \\ []), to: Assertions

  @doc """
  Asserts that modules in `subject` only depend on modules in `allowed`.
  """
  defdelegate should_only_depend_on(subject, allowed, opts \\ []), to: Assertions

  @doc """
  Asserts that no module in `callers` calls any module in `object`.
  """
  defdelegate should_not_be_called_by(object, callers, opts \\ []), to: Assertions

  @doc """
  Asserts only modules in `allowed_callers` may call modules in `object`.
  """
  defdelegate should_only_be_called_by(object, allowed_callers, opts \\ []), to: Assertions

  @doc """
  Asserts no transitive dependency from `subject` to modules in `object`.
  """
  defdelegate should_not_transitively_depend_on(subject, object, opts \\ []), to: Assertions

  @doc """
  Asserts that no module in `subject` exists.
  """
  defdelegate should_not_exist(subject, opts \\ []), to: Assertions

  @doc """
  Asserts that all modules in `subject` reside under `namespace_pattern`.
  """
  defdelegate should_reside_under(subject, namespace_pattern, opts \\ []), to: Assertions

  @doc """
  Asserts that all modules in `subject` have names matching `name_pattern`.
  """
  defdelegate should_have_name_matching(subject, name_pattern, opts \\ []), to: Assertions

  @doc """
  Asserts no circular dependencies among modules in `subject`.

  Accepts either a `ModuleSet` or a `Modulith` slice definition.
  """
  @spec should_be_free_of_cycles(ModuleSet.t() | Modulith.t(), keyword()) :: :ok
  def should_be_free_of_cycles(subject, opts \\ [])

  def should_be_free_of_cycles(%ModuleSet{} = subject, opts) do
    Assertions.should_be_free_of_cycles(subject, opts)
  end

  def should_be_free_of_cycles(%Modulith{} = modulith, opts) do
    modulith
    |> maybe_modulith_for_app(opts)
    |> Modulith.should_be_free_of_cycles(opts)
  end

  @doc """
  Asserts that the number of modules matching `subject` satisfies the given constraints.
  """
  defdelegate should_have_module_count(subject, constraints, opts \\ []), to: Assertions

  @doc """
  Applies a custom check function `(graph, module -> [Violation.t()])` to
  each module in `subject`.
  """
  defdelegate satisfying(subject, check_fn, opts \\ []), to: Assertions

  @doc """
  Asserts that all modules in `subject` implement the given behaviour.
  """
  defdelegate should_implement_behaviour(subject, behaviour, opts \\ []), to: Assertions

  @doc """
  Asserts that no module in `subject` implements the given behaviour.
  """
  defdelegate should_not_implement_behaviour(subject, behaviour, opts \\ []), to: Assertions

  @doc """
  Asserts that all modules in `subject` implement the given protocol.
  """
  defdelegate should_implement_protocol(subject, protocol, opts \\ []), to: Assertions

  @doc """
  Asserts that no module in `subject` implements the given protocol.
  """
  defdelegate should_not_implement_protocol(subject, protocol, opts \\ []), to: Assertions

  @doc """
  Asserts all modules in `subject` have the given module attribute.
  """
  defdelegate should_have_attribute(subject, attr_key, opts \\ []), to: Assertions

  @doc """
  Asserts all modules in `subject` do NOT have the given module attribute.
  """
  defdelegate should_not_have_attribute(subject, attr_key, opts \\ []), to: Assertions

  @doc """
  Asserts all modules in `subject` have the given attribute with the given value.
  """
  defdelegate should_have_attribute_value(subject, attr_key, attr_value, opts \\ []),
    to: Assertions

  @doc """
  Asserts all modules in `subject` do NOT have the given attribute with the given value.
  """
  defdelegate should_not_have_attribute_value(subject, attr_key, attr_value, opts \\ []),
    to: Assertions

  @doc """
  Asserts all modules in `subject` use the given module (via `use ModuleName`).
  """
  defdelegate should_use(subject, used_module, opts \\ []), to: Assertions

  @doc """
  Asserts no module in `subject` uses the given module (via `use ModuleName`).
  """
  defdelegate should_not_use(subject, used_module, opts \\ []), to: Assertions

  @doc """
  Asserts all modules in `subject` export the given function.
  """
  defdelegate should_export(subject, fun_name, arity, opts \\ []), to: Assertions

  @doc """
  Asserts no module in `subject` exports the given function.
  """
  defdelegate should_not_export(subject, fun_name, arity, opts \\ []), to: Assertions

  @doc """
  Asserts all modules in `subject` have at least one public function whose name
  matches the given glob pattern.
  """
  defdelegate should_have_public_functions_matching(subject, pattern, opts \\ []), to: Assertions

  @doc """
  Asserts no module in `subject` has public functions whose names match the pattern.
  """
  defdelegate should_not_have_public_functions_matching(subject, pattern, opts \\ []),
    to: Assertions

  # ------------------------------------------------------------------
  # Architecture pattern DSL
  # ------------------------------------------------------------------

  @doc """
  Defines an ordered list of architecture layers (top to bottom).

  ## Example

      define_layers(
        web:     "MyApp.Web.**",
        context: "MyApp.Context.**",
        repo:    "MyApp.Repo.**"
      )
      |> enforce_direction()
  """
  @spec define_layers(keyword(), keyword()) :: Layers.t()
  def define_layers(layer_defs, opts \\ []) do
    layer_defs
    |> Layers.define_layers()
    |> maybe_layer_for_app(opts)
  end

  @doc """
  Defines an onion/hexagonal architecture (innermost layer first).

  ## Example

      define_onion(
        domain:      "MyApp.Domain.**",
        application: "MyApp.Application.**",
        adapters:    "MyApp.Adapters.**"
      )
      |> enforce_onion_rules()
  """
  @spec define_onion(keyword(), keyword()) :: Layers.t()
  def define_onion(layer_defs, opts \\ []) do
    layer_defs
    |> Layers.define_onion()
    |> maybe_layer_for_app(opts)
  end

  @doc """
  Defines bounded-context slices for a modulith architecture.

  ## Example

      define_slices(
        orders:    "MyApp.Orders",
        inventory: "MyApp.Inventory",
        accounts:  "MyApp.Accounts"
      )
      |> allow_dependency(:orders, :accounts)
      |> enforce_isolation()
  """
  @spec define_slices(keyword(), keyword()) :: Modulith.t()
  def define_slices(slice_defs, opts \\ []) do
    slice_defs
    |> Modulith.define_slices()
    |> maybe_modulith_for_app(opts)
  end

  @doc """
  Defines modulith slices by capturing one namespace segment from existing modules.

  Use `(*)` to mark the captured segment:

      define_slices_by("MyApp.(*)", app: :my_app)
  """
  @spec define_slices_by(String.t(), keyword()) :: Modulith.t()
  defdelegate define_slices_by(pattern, opts \\ []), to: Modulith

  @doc """
  Allows `from_slice` to call the public API of `to_slice`.
  """
  @spec allow_dependency(Modulith.t(), atom(), atom()) :: Modulith.t()
  defdelegate allow_dependency(modulith, from_slice, to_slice), to: Modulith

  @doc """
  Enforces bounded-context isolation (see `ArchTest.Modulith`).
  """
  @spec enforce_isolation(Modulith.t(), keyword()) :: :ok
  def enforce_isolation(modulith, opts \\ []) do
    modulith |> maybe_modulith_for_app(opts) |> Modulith.enforce_isolation(opts)
  end

  @doc """
  Asserts that slices have absolutely no cross-slice dependencies (strict isolation).
  """
  @spec should_not_depend_on_each_other(Modulith.t(), keyword()) :: :ok
  def should_not_depend_on_each_other(modulith, opts \\ []) do
    modulith |> maybe_modulith_for_app(opts) |> Modulith.should_not_depend_on_each_other(opts)
  end

  @doc "Asserts every module under namespace_pattern belongs to a declared slice."
  def all_modules_covered_by(modulith, namespace_pattern, opts \\ []) do
    modulith
    |> maybe_modulith_for_app(opts)
    |> Modulith.all_modules_covered_by(namespace_pattern, opts)
  end

  @doc """
  Enforces layer direction (each layer may only depend on layers below it).
  """
  @spec enforce_direction(Layers.t(), keyword()) :: :ok
  def enforce_direction(layers, opts \\ []) do
    layers |> maybe_layer_for_app(opts) |> Layers.enforce_direction(opts)
  end

  @doc """
  Enforces onion architecture rules (dependencies point only inward).
  """
  @spec enforce_onion_rules(Layers.t(), keyword()) :: :ok
  def enforce_onion_rules(layers, opts \\ []) do
    layers |> maybe_layer_for_app(opts) |> Layers.enforce_onion_rules(opts)
  end

  @doc "Adds a custom layer allowlist rule."
  defdelegate layer_may_only_depend_on(layers, layer, allowed_layers), to: Layers

  @doc "Adds a custom layer denylist rule."
  defdelegate layer_may_not_depend_on(layers, layer, forbidden_layers), to: Layers

  @doc "Allows a specific dependency from one layer to another."
  defdelegate allow_layer_dependency(layers, from_layer, to_layer), to: Layers

  defp maybe_layer_for_app(%Layers{} = layers, opts) do
    case Keyword.get(opts, :app) do
      nil -> layers
      :all -> layers
      app -> Layers.for_app(layers, app)
    end
  end

  defp maybe_modulith_for_app(%Modulith{} = modulith, opts) do
    case Keyword.get(opts, :app) do
      nil -> modulith
      :all -> modulith
      app -> Modulith.for_app(modulith, app)
    end
  end

  # ------------------------------------------------------------------
  # Public helper used by Layers/Modulith (not part of user API)
  # ------------------------------------------------------------------

  @doc false
  def assert_no_violations_public(violations, rule_name) do
    Assertions.assert_no_violations_public(violations, rule_name)
  end
end
