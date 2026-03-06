defmodule ArchTest do
  @moduledoc """
  ArchUnit-inspired architecture testing library for Elixir.

  Write ExUnit tests that enforce architectural rules — dependency direction,
  layer boundaries, bounded-context isolation, and naming conventions —
  using a fluent, pipe-based DSL.

  ## Quick start

      defmodule MyApp.ArchitectureTest do
        use ExUnit.Case
        use ArchTest

        test "service modules don't call repos directly" do
          modules_matching("**.*Service")
          |> should_not_depend_on(modules_matching("**.*Repo"))
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
  - `ArchTest.Collector` — BEAM dependency graph builder
  - `ArchTest.Pattern` — glob pattern matching
  """

  alias ArchTest.{Assertions, Layers, ModuleSet, Modulith}

  @doc false
  defmacro __using__(opts \\ []) do
    app = Keyword.get(opts, :app, :all)

    quote do
      import ArchTest

      # Stash the app option so DSL functions can pick it up.
      # Use this in tests via `arch_test_opts()` to forward app to assertions:
      #   should_not_depend_on(subject, object, arch_test_opts())
      @arch_test_app unquote(app)

      @doc false
      def arch_test_opts, do: [app: @arch_test_app]
    end
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
  defdelegate should_not_depend_on(subject, object), to: Assertions

  @doc """
  Asserts that modules in `subject` only depend on modules in `allowed`.
  """
  defdelegate should_only_depend_on(subject, allowed), to: Assertions

  @doc """
  Asserts that no module in `callers` calls any module in `object`.
  """
  defdelegate should_not_be_called_by(object, callers), to: Assertions

  @doc """
  Asserts only modules in `allowed_callers` may call modules in `object`.
  """
  defdelegate should_only_be_called_by(object, allowed_callers), to: Assertions

  @doc """
  Asserts no transitive dependency from `subject` to modules in `object`.
  """
  defdelegate should_not_transitively_depend_on(subject, object), to: Assertions

  @doc """
  Asserts that no module in `subject` exists.
  """
  defdelegate should_not_exist(subject), to: Assertions

  @doc """
  Asserts that all modules in `subject` reside under `namespace_pattern`.
  """
  defdelegate should_reside_under(subject, namespace_pattern), to: Assertions

  @doc """
  Asserts that all modules in `subject` have names matching `name_pattern`.
  """
  defdelegate should_have_name_matching(subject, name_pattern), to: Assertions

  @doc """
  Asserts no circular dependencies among modules in `subject`.
  """
  defdelegate should_be_free_of_cycles(subject), to: Assertions

  @doc """
  Asserts that the number of modules matching `subject` satisfies the given constraints.
  """
  defdelegate should_have_module_count(subject, constraints), to: Assertions

  @doc """
  Applies a custom check function `(graph, module -> [Violation.t()])` to
  each module in `subject`.
  """
  defdelegate satisfying(subject, check_fn), to: Assertions

  @doc """
  Asserts that all modules in `subject` implement the given behaviour.
  """
  defdelegate should_implement_behaviour(subject, behaviour), to: Assertions

  @doc """
  Asserts that no module in `subject` implements the given behaviour.
  """
  defdelegate should_not_implement_behaviour(subject, behaviour), to: Assertions

  @doc """
  Asserts that all modules in `subject` implement the given protocol.
  """
  defdelegate should_implement_protocol(subject, protocol), to: Assertions

  @doc """
  Asserts that no module in `subject` implements the given protocol.
  """
  defdelegate should_not_implement_protocol(subject, protocol), to: Assertions

  @doc """
  Asserts all modules in `subject` have the given module attribute.
  """
  defdelegate should_have_attribute(subject, attr_key), to: Assertions

  @doc """
  Asserts all modules in `subject` do NOT have the given module attribute.
  """
  defdelegate should_not_have_attribute(subject, attr_key), to: Assertions

  @doc """
  Asserts all modules in `subject` have the given attribute with the given value.
  """
  defdelegate should_have_attribute_value(subject, attr_key, attr_value), to: Assertions

  @doc """
  Asserts all modules in `subject` do NOT have the given attribute with the given value.
  """
  defdelegate should_not_have_attribute_value(subject, attr_key, attr_value), to: Assertions

  @doc """
  Asserts all modules in `subject` use the given module (via `use ModuleName`).
  """
  defdelegate should_use(subject, used_module), to: Assertions

  @doc """
  Asserts no module in `subject` uses the given module (via `use ModuleName`).
  """
  defdelegate should_not_use(subject, used_module), to: Assertions

  @doc """
  Asserts all modules in `subject` export the given function.
  """
  defdelegate should_export(subject, fun_name, arity), to: Assertions

  @doc """
  Asserts no module in `subject` exports the given function.
  """
  defdelegate should_not_export(subject, fun_name, arity), to: Assertions

  @doc """
  Asserts all modules in `subject` have at least one public function whose name
  matches the given glob pattern.
  """
  defdelegate should_have_public_functions_matching(subject, pattern), to: Assertions

  @doc """
  Asserts no module in `subject` has public functions whose names match the pattern.
  """
  defdelegate should_not_have_public_functions_matching(subject, pattern), to: Assertions

  # ------------------------------------------------------------------
  # Architecture pattern DSL
  # ------------------------------------------------------------------

  @doc """
  Defines an ordered list of architecture layers (top to bottom).

  ## Example

      define_layers(
        web:     "MyApp.Web.**",
        context: "MyApp.**",
        repo:    "MyApp.Repo.**"
      )
      |> enforce_direction()
  """
  @spec define_layers(keyword()) :: Layers.t()
  defdelegate define_layers(layer_defs), to: Layers

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
  @spec define_onion(keyword()) :: Layers.t()
  defdelegate define_onion(layer_defs), to: Layers

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
  @spec define_slices(keyword()) :: Modulith.t()
  defdelegate define_slices(slice_defs), to: Modulith

  @doc """
  Allows `from_slice` to call the public API of `to_slice`.
  """
  @spec allow_dependency(Modulith.t(), atom(), atom()) :: Modulith.t()
  defdelegate allow_dependency(modulith, from_slice, to_slice), to: Modulith

  @doc """
  Enforces bounded-context isolation (see `ArchTest.Modulith`).
  """
  @spec enforce_isolation(Modulith.t()) :: :ok
  defdelegate enforce_isolation(modulith), to: Modulith

  @doc """
  Asserts that slices have absolutely no cross-slice dependencies (strict isolation).
  """
  @spec should_not_depend_on_each_other(Modulith.t()) :: :ok
  defdelegate should_not_depend_on_each_other(modulith), to: Modulith

  @doc "Asserts every module under namespace_pattern belongs to a declared slice."
  defdelegate all_modules_covered_by(modulith, namespace_pattern), to: Modulith

  @doc "Asserts every module under namespace_pattern belongs to a declared slice."
  defdelegate all_modules_covered_by(modulith, namespace_pattern, opts), to: Modulith

  @doc """
  Enforces layer direction (each layer may only depend on layers below it).
  """
  @spec enforce_direction(Layers.t()) :: :ok
  defdelegate enforce_direction(layers), to: Layers

  @doc """
  Enforces onion architecture rules (dependencies point only inward).
  """
  @spec enforce_onion_rules(Layers.t()) :: :ok
  defdelegate enforce_onion_rules(layers), to: Layers

  # ------------------------------------------------------------------
  # Public helper used by Layers/Modulith (not part of user API)
  # ------------------------------------------------------------------

  @doc false
  def assert_no_violations_public(violations, rule_name) do
    Assertions.assert_no_violations_public(violations, rule_name)
  end
end
