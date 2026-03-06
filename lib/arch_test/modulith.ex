defmodule ArchTest.Modulith do
  @moduledoc """
  Modulith / bounded context isolation enforcement.

  Define named slices (bounded contexts) and enforce that internals of one
  slice are not accessed by other slices. Only the public API module (the
  root context module) may be called cross-slice.

  ## Slice structure

  Given `define_slices(orders: "MyApp.Orders", ...)`:
  - **Public API**: `MyApp.Orders` (the exact root module)
  - **Internals**: `MyApp.Orders.*` and deeper (sub-modules)

  ## Example

      define_slices(
        orders:    "MyApp.Orders",
        inventory: "MyApp.Inventory",
        accounts:  "MyApp.Accounts"
      )
      |> allow_dependency(:orders, :accounts)
      |> enforce_isolation()
  """

  alias ArchTest.{Assertions, Collector, Violation}

  defstruct slices: [], allowed_deps: [], app: nil

  @type slice_name :: atom()
  @type t :: %__MODULE__{
          slices: [{slice_name(), String.t()}],
          allowed_deps: [{slice_name(), slice_name()}],
          app: atom() | nil
        }

  @doc """
  Defines named slices (bounded contexts).

  Accepts a keyword list of `slice_name: "RootNamespace"` pairs.
  """
  @spec define_slices(keyword()) :: t()
  def define_slices(slice_defs) when is_list(slice_defs) do
    %__MODULE__{slices: slice_defs}
  end

  @doc """
  Permits `from_slice` to call the public API (root module) of `to_slice`.

  Without this, cross-slice calls to internal sub-modules are always
  violations, and calls to other slices' public root modules are also
  violations by default.

  With `allow_dependency(:orders, :accounts)`, `MyApp.Orders.*` may call
  `MyApp.Accounts` (but not `MyApp.Accounts.Repo`, etc.).
  """
  @spec allow_dependency(t(), slice_name(), slice_name()) :: t()
  def allow_dependency(%__MODULE__{} = m, from_slice, to_slice) do
    %{m | allowed_deps: m.allowed_deps ++ [{from_slice, to_slice}]}
  end

  @doc """
  Sets the OTP application to introspect (default: `:all`).
  """
  @spec for_app(t(), atom()) :: t()
  def for_app(%__MODULE__{} = m, app), do: %{m | app: app}

  @doc """
  Enforces that slice internals are not accessed by other slices.

  Rules:
  1. Module A (in slice X) calling Module B (in slice Y's internals) is a
     violation, unless `allow_dependency(X, Y)` has been declared.
  2. Even with `allow_dependency(X, Y)`, only the public root module of Y
     may be called (not sub-modules).
  """
  @spec enforce_isolation(t()) :: :ok
  def enforce_isolation(%__MODULE__{} = m) do
    graph = Collector.build_graph(m.app || :all)
    slice_info = build_slice_info(m.slices, graph)

    violations =
      for {caller_slice, caller_pattern} <- m.slices,
          caller_mods = slice_all_modules(caller_pattern, graph),
          caller <- caller_mods,
          dep <- Collector.dependencies_of(graph, caller),
          {dep_slice, dep_root} = find_slice(dep, slice_info),
          dep_slice != nil,
          dep_slice != caller_slice do
        # Is the dependency on the public root or an internal?
        is_root = dep == dep_root
        allowed = {caller_slice, dep_slice} in m.allowed_deps

        cond do
          # Any access to internals is forbidden
          not is_root ->
            Violation.forbidden_dep(
              caller,
              dep,
              "accesses an internal module of the :#{dep_slice} context. " <>
                "Only the public API #{inspect(dep_root)} may be called from outside. " <>
                "Fix: either call #{inspect(dep_root)} instead, or move the logic to that module."
            )

          # Access to public root requires explicit allow_dependency
          not allowed ->
            Violation.forbidden_dep(
              caller,
              dep,
              "crosses into the :#{dep_slice} context without an explicit allow_dependency declaration. " <>
                "Fix: add `|> allow_dependency(:#{caller_slice}, :#{dep_slice})` to your slice definition, " <>
                "or remove the dependency."
            )

          true ->
            nil
        end
      end
      |> Enum.reject(&is_nil/1)

    slice_names = m.slices |> Keyword.keys() |> Enum.map_join(", ", &":#{&1}")

    allowed_str =
      if m.allowed_deps == [] do
        "none declared"
      else
        m.allowed_deps
        |> Enum.map_join(", ", fn {f, t} -> ":#{f} → :#{t}" end)
      end

    context =
      "\n  slices:       [#{slice_names}]" <>
        "\n  allowed deps: #{allowed_str}"

    Assertions.assert_no_violations_public(violations, "modulith — enforce_isolation", context)
  end

  @doc """
  Asserts that there are no circular dependencies between slices.

  Each slice is treated as a single node; a cycle exists when slice A
  depends on slice B which (transitively) depends on slice A.
  """
  @spec should_be_free_of_cycles(t()) :: :ok
  def should_be_free_of_cycles(%__MODULE__{} = m) do
    graph = Collector.build_graph(m.app || :all)
    slice_info = build_slice_info(m.slices, graph)

    # Build a slice-level dependency graph
    slice_graph =
      Enum.reduce(m.slices, %{}, fn {slice_name, pattern}, acc ->
        mods = slice_all_modules(pattern, graph)

        dep_slices =
          mods
          |> Enum.flat_map(&Collector.dependencies_of(graph, &1))
          |> Enum.map(fn dep ->
            {dep_slice, _root} = find_slice(dep, slice_info)
            dep_slice
          end)
          |> Enum.reject(&(is_nil(&1) or &1 == slice_name))
          |> Enum.uniq()

        Map.put(acc, slice_name, dep_slices)
      end)

    cycles = Collector.cycles(slice_graph)

    violations =
      Enum.map(cycles, fn cycle ->
        names = Enum.map_join(cycle, " → ", &inspect/1)

        Violation.cycle(
          cycle,
          "circular dependency between bounded contexts: #{names}. " <>
            "Fix: remove one of the cross-context dependencies, or introduce a shared abstraction " <>
            "that both contexts depend on instead."
        )
      end)

    Assertions.assert_no_violations_public(violations, "modulith — should_be_free_of_cycles")
  end

  @doc """
  Asserts that slices have absolutely no cross-slice dependencies.

  This is stricter than `enforce_isolation/1` — not even the public root module
  of another slice may be called. Use this for completely independent bounded contexts.

  ## Example

      define_slices(
        orders:    "MyApp.Orders",
        inventory: "MyApp.Inventory",
        accounts:  "MyApp.Accounts"
      )
      |> should_not_depend_on_each_other()
  """
  @spec should_not_depend_on_each_other(t()) :: :ok
  def should_not_depend_on_each_other(%__MODULE__{} = m) do
    graph = Collector.build_graph(m.app || :all)
    slice_info = build_slice_info(m.slices, graph)

    violations =
      for {slice_a, _pattern_a} <- m.slices,
          {slice_b, _pattern_b} <- m.slices,
          slice_a != slice_b do
        mods_a = slice_modules(slice_a, slice_info)
        mods_b = slice_modules(slice_b, slice_info) |> MapSet.new()

        for caller <- mods_a,
            dep <- Collector.dependencies_of(graph, caller),
            MapSet.member?(mods_b, dep) do
          Violation.forbidden_dep(
            caller,
            dep,
            "slice :#{slice_a} must not depend on slice :#{slice_b} at all (strict isolation). " <>
              "Even public API calls are forbidden. Remove this dependency."
          )
        end
      end
      |> List.flatten()
      |> Enum.uniq_by(fn v -> {v.caller, v.callee} end)

    slice_names = m.slices |> Keyword.keys() |> Enum.map_join(", ", &":#{&1}")
    context = "\n  slices: [#{slice_names}]"

    Assertions.assert_no_violations_public(
      violations,
      "modulith — should_not_depend_on_each_other",
      context
    )
  end

  @doc """
  Asserts that every module under `namespace_pattern` belongs to a declared slice.

  Any module that does not match any slice's namespace is a violation. This
  prevents new modules from silently escaping slice coverage.

  ## Options

  - `:except` — list of glob patterns to exclude from the check
  - `:graph` — pre-built dependency graph (useful for testing, avoids xref)

  ## Example

      define_slices(auth: "Vireale.Auth", feeds: "Vireale.Feeds")
      |> all_modules_covered_by("Vireale.**",
           except: ["Vireale.Application", "Vireale.Repo"])
  """
  @spec all_modules_covered_by(t(), String.t(), keyword()) :: :ok
  def all_modules_covered_by(%__MODULE__{} = m, namespace_pattern, opts \\ []) do
    graph =
      case Keyword.get(opts, :graph) do
        nil -> Collector.build_graph(m.app || :all)
        g when is_map(g) -> g
      end

    except_patterns = Keyword.get(opts, :except, [])

    candidates =
      graph
      |> Map.keys()
      |> Enum.filter(fn mod ->
        mod_str =
          mod
          |> Atom.to_string()
          |> strip_elixir_prefix()

        ArchTest.Pattern.matches?(namespace_pattern, mod_str)
      end)
      |> Enum.reject(fn mod ->
        mod_str =
          mod
          |> Atom.to_string()
          |> strip_elixir_prefix()

        Enum.any?(except_patterns, &ArchTest.Pattern.matches?(&1, mod_str))
      end)

    covered =
      m.slices
      |> Enum.flat_map(fn {_slice_name, root_namespace} ->
        slice_all_modules(root_namespace, graph)
      end)
      |> MapSet.new()

    slice_names = m.slices |> Keyword.keys() |> Enum.map_join(", ", &":#{&1}")

    violations =
      candidates
      |> Enum.reject(&MapSet.member?(covered, &1))
      |> Enum.map(fn mod ->
        %ArchTest.Violation{
          type: :custom,
          module: mod,
          message:
            "#{inspect(mod)} does not belong to any declared slice. " <>
              "Add it to an existing slice or declare a new one with " <>
              "`define_slices(..., new_slice: \"#{slice_root_hint(mod)}\")`."
        }
      end)

    context =
      "\n  rule:    all_modules_covered_by(\"#{namespace_pattern}\")" <>
        "\n  slices:  [#{slice_names}]"

    Assertions.assert_no_violations_public(
      violations,
      "modulith — all_modules_covered_by",
      context
    )
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  # Returns all modules belonging to a slice by name from the pre-built slice_info.
  defp slice_modules(slice_name, slice_info) do
    Enum.find_value(slice_info, [], fn {name, _root, all_mods} ->
      if name == slice_name, do: all_mods
    end)
  end

  # Returns [{slice_name, root_module, all_modules}]
  defp build_slice_info(slices, graph) do
    Enum.map(slices, fn {slice_name, root_namespace} ->
      root_mod = Module.concat([root_namespace])
      all_mods = slice_all_modules(root_namespace, graph)
      {slice_name, root_mod, all_mods}
    end)
  end

  defp slice_all_modules(root_namespace, graph) do
    # Include the root module itself and all sub-modules
    root_pattern = root_namespace
    children_pattern = "#{root_namespace}.**"

    all_keys = Map.keys(graph)

    root_mods =
      Enum.filter(all_keys, fn mod ->
        mod_str = to_string(mod)
        elixir_str = "Elixir.#{root_namespace}"
        mod_str == elixir_str or mod_str == root_namespace
      end)

    child_mods =
      Enum.filter(all_keys, fn mod ->
        mod_str =
          mod
          |> Atom.to_string()
          |> strip_elixir_prefix()

        ArchTest.Pattern.matches?(children_pattern, mod_str) or
          ArchTest.Pattern.matches?(root_pattern, mod_str)
      end)

    (root_mods ++ child_mods) |> Enum.uniq()
  end

  defp strip_elixir_prefix("Elixir." <> rest), do: rest
  defp strip_elixir_prefix(str), do: str

  # Suggests the top-level namespace for an uncovered module (first two segments).
  defp slice_root_hint(mod) do
    mod
    |> Atom.to_string()
    |> strip_elixir_prefix()
    |> String.split(".")
    |> Enum.take(2)
    |> Enum.join(".")
  end

  # Returns {slice_name, root_module} for the given module, or {nil, nil}
  defp find_slice(mod, slice_info) do
    Enum.find_value(slice_info, {nil, nil}, fn {slice_name, root_mod, all_mods} ->
      if mod in all_mods, do: {slice_name, root_mod}
    end)
  end
end
