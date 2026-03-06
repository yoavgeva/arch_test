defmodule ArchTest.Assertions do
  @moduledoc """
  Core assertion functions for architecture rules.

  All assertion functions accept a `ModuleSet` as their first argument
  (supporting pipe-based DSL usage) and evaluate against the current
  dependency graph from `ArchTest.Collector`.

  Violations cause an `ExUnit.AssertionError` with a detailed message
  listing all offending dependencies, grouped by module and annotated
  with the patterns that were checked.
  """

  alias ArchTest.{Collector, ModuleSet, Pattern, Violation}

  @doc """
  Asserts that no module in `subject` directly depends on any module in `object`.

  ## Example

      modules_matching("**.*Controller")
      |> should_not_depend_on(modules_matching("**.*Repo"))
  """
  @spec should_not_depend_on(ModuleSet.t(), ModuleSet.t(), keyword()) :: :ok
  def should_not_depend_on(%ModuleSet{} = subject, %ModuleSet{} = object, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    object_mods = ModuleSet.resolve(object, graph) |> MapSet.new()

    warn_if_empty(subject_mods, subject, "should_not_depend_on")

    violations =
      for caller <- subject_mods,
          callee <- Collector.dependencies_of(graph, caller),
          MapSet.member?(object_mods, callee) do
        Violation.forbidden_dep(
          caller,
          callee,
          "direct dependency is forbidden by the rule: " <>
            format_patterns(subject) <> " must not depend on " <> format_patterns(object)
        )
      end

    assert_no_violations(violations, "should_not_depend_on", subject, object, Keyword.get(opts, :message))
  end

  @doc """
  Asserts that every module in `subject` only depends on modules in `allowed`.

  Any dependency outside `allowed` is a violation.

  ## Example

      modules_matching("**.*Controller")
      |> should_only_depend_on(
           modules_matching("**.*Service")
           |> union(modules_matching("**.*View"))
         )
  """
  @spec should_only_depend_on(ModuleSet.t(), ModuleSet.t(), keyword()) :: :ok
  def should_only_depend_on(%ModuleSet{} = subject, %ModuleSet{} = allowed, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    allowed_mods = ModuleSet.resolve(allowed, graph) |> MapSet.new()

    warn_if_empty(subject_mods, subject, "should_only_depend_on")

    violations =
      for caller <- subject_mods,
          callee <- Collector.dependencies_of(graph, caller),
          # only check app-internal modules (not stdlib/OTP)
          Map.has_key?(graph, callee),
          not MapSet.member?(allowed_mods, callee) do
        Violation.forbidden_dep(
          caller,
          callee,
          "dependency is not in the allowed set. " <>
            format_patterns(subject) <> " may only depend on " <> format_patterns(allowed) <>
            ". Add an allow or move the dependency."
        )
      end

    assert_no_violations(violations, "should_only_depend_on", subject, allowed, Keyword.get(opts, :message))
  end

  @doc """
  Asserts that no module in `object` is called by any module in `callers`.

  This is the reverse direction of `should_not_depend_on`.

  ## Example

      modules_matching("MyApp.Repo.*")
      |> should_not_be_called_by(modules_matching("MyApp.Web.*"))
  """
  @spec should_not_be_called_by(ModuleSet.t(), ModuleSet.t(), keyword()) :: :ok
  def should_not_be_called_by(%ModuleSet{} = object, %ModuleSet{} = callers, opts \\ []) do
    graph = get_graph(opts)
    object_mods = ModuleSet.resolve(object, graph) |> MapSet.new()
    caller_mods = ModuleSet.resolve(callers, graph)

    warn_if_empty(MapSet.to_list(object_mods), object, "should_not_be_called_by")

    violations =
      for caller <- caller_mods,
          callee <- Collector.dependencies_of(graph, caller),
          MapSet.member?(object_mods, callee) do
        Violation.forbidden_dep(
          caller,
          callee,
          format_patterns(object) <> " must not be called by " <> format_patterns(callers)
        )
      end

    assert_no_violations(violations, "should_not_be_called_by", callers, object, Keyword.get(opts, :message))
  end

  @doc """
  Asserts that only modules in `allowed_callers` may call modules in `object`.

  Any module outside `allowed_callers` that calls a module in `object` is a violation.
  This is the whitelist form of `should_not_be_called_by/3`.

  ## Example

      # Only Services and Controllers may call Repo modules
      modules_matching("**.*Repo")
      |> should_only_be_called_by(
           modules_matching("**.*Service")
           |> union(modules_matching("**.*Controller"))
         )

      # The Accounts module may only be called by the Orders context
      modules_matching("MyApp.Accounts")
      |> should_only_be_called_by(modules_matching("MyApp.Orders.**"),
           message: "Use the Orders public API to access Accounts — see ADR-012")
  """
  @spec should_only_be_called_by(ModuleSet.t(), ModuleSet.t(), keyword()) :: :ok
  def should_only_be_called_by(%ModuleSet{} = object, %ModuleSet{} = allowed_callers, opts \\ []) do
    graph = get_graph(opts)
    object_mods = ModuleSet.resolve(object, graph) |> MapSet.new()
    allowed_mods = ModuleSet.resolve(allowed_callers, graph) |> MapSet.new()

    violations =
      for {caller, deps} <- graph,
          not MapSet.member?(allowed_mods, caller),
          not MapSet.member?(object_mods, caller),
          dep <- deps,
          MapSet.member?(object_mods, dep) do
        Violation.forbidden_dep(
          caller,
          dep,
          "#{inspect(dep)} may only be called by #{format_patterns(allowed_callers)} " <>
            "but is also called by #{inspect(caller)}. " <>
            "Move this call or add the caller to the allowed set."
        )
      end

    assert_no_violations(violations, "should_only_be_called_by", allowed_callers, object, Keyword.get(opts, :message))
  end

  @doc """
  Asserts that none of the modules in `subject` transitively depend on
  any module in `object`.

  ## Example

      modules_matching("MyApp.Orders.*")
      |> should_not_transitively_depend_on(modules_matching("MyApp.Billing.*"))
  """
  @spec should_not_transitively_depend_on(ModuleSet.t(), ModuleSet.t(), keyword()) :: :ok
  def should_not_transitively_depend_on(%ModuleSet{} = subject, %ModuleSet{} = object,
        opts \\ []
      ) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    object_mods = ModuleSet.resolve(object, graph) |> MapSet.new()

    warn_if_empty(subject_mods, subject, "should_not_transitively_depend_on")

    violations =
      for caller <- subject_mods do
        transitive = Collector.transitive_dependencies_of(graph, caller)
        forbidden = Enum.filter(transitive, &MapSet.member?(object_mods, &1))

        Enum.map(forbidden, fn callee ->
          path = find_shortest_path(graph, caller, callee)

          Violation.transitive_dep(
            caller,
            callee,
            path,
            "transitive dependency is forbidden: " <>
              format_patterns(subject) <> " must not reach " <> format_patterns(object)
          )
        end)
      end
      |> List.flatten()

    assert_no_violations(violations, "should_not_transitively_depend_on", subject, object, Keyword.get(opts, :message))
  end

  @doc """
  Asserts that none of the modules matched by `subject` exist in the codebase.

  Used to ban naming conventions (e.g., no `*Manager` modules).

  ## Example

      modules_matching("**.*Manager") |> should_not_exist()
  """
  @spec should_not_exist(ModuleSet.t(), keyword()) :: :ok
  def should_not_exist(%ModuleSet{} = subject, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)

    violations =
      Enum.map(subject_mods, fn mod ->
        Violation.existence(
          mod,
          "this module matches the forbidden pattern " <> format_patterns(subject) <>
            " and must be renamed or removed"
        )
      end)

    assert_no_violations(violations, "should_not_exist", subject, nil, Keyword.get(opts, :message))
  end

  @doc """
  Asserts that all modules in `subject` reside under the given namespace pattern.

  ## Example

      modules_matching("**.*Schema") |> should_reside_under("MyApp.**.Schemas")
  """
  @spec should_reside_under(ModuleSet.t(), String.t(), keyword()) :: :ok
  def should_reside_under(%ModuleSet{} = subject, namespace_pattern, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)

    warn_if_empty(subject_mods, subject, "should_reside_under")

    violations =
      for mod <- subject_mods,
          mod_str = Pattern.module_to_string(mod),
          not Pattern.matches?(namespace_pattern, mod_str) do
        Violation.naming(
          mod,
          "module must reside under \"#{namespace_pattern}\" " <>
            "but is at #{mod_str}. Move it or update the namespace rule."
        )
      end

    assert_no_violations(violations, "should_reside_under", subject, nil, Keyword.get(opts, :message))
  end

  @doc """
  Asserts that all modules in `subject` have names matching `name_pattern`.

  ## Example

      modules_matching("MyApp.Repo.**") |> should_have_name_matching("**.*Repo")
  """
  @spec should_have_name_matching(ModuleSet.t(), String.t(), keyword()) :: :ok
  def should_have_name_matching(%ModuleSet{} = subject, name_pattern, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)

    warn_if_empty(subject_mods, subject, "should_have_name_matching")

    violations =
      for mod <- subject_mods,
          mod_str = Pattern.module_to_string(mod),
          not Pattern.matches?(name_pattern, mod_str) do
        Violation.naming(
          mod,
          "module name does not match required pattern \"#{name_pattern}\". " <>
            "Rename it so the last segment conforms to the convention."
        )
      end

    assert_no_violations(violations, "should_have_name_matching", subject, nil, Keyword.get(opts, :message))
  end

  @doc """
  Asserts that there are no circular dependencies among modules in `subject`.

  ## Example

      modules_matching("MyApp.Orders.**") |> should_be_free_of_cycles()
  """
  @spec should_be_free_of_cycles(ModuleSet.t(), keyword()) :: :ok
  def should_be_free_of_cycles(%ModuleSet{} = subject, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph) |> MapSet.new()

    warn_if_empty(MapSet.to_list(subject_mods), subject, "should_be_free_of_cycles")

    # Build a subgraph restricted to subject modules
    subgraph =
      graph
      |> Enum.filter(fn {mod, _} -> MapSet.member?(subject_mods, mod) end)
      |> Enum.map(fn {mod, deps} ->
        {mod, Enum.filter(deps, &MapSet.member?(subject_mods, &1))}
      end)
      |> Map.new()

    cycles = Collector.cycles(subgraph)

    violations =
      Enum.map(cycles, fn cycle ->
        Violation.cycle(
          cycle,
          "break this cycle by extracting shared logic into a separate module " <>
            "that neither participant depends on, or by inverting one dependency."
        )
      end)

    assert_no_violations(violations, "should_be_free_of_cycles", subject, nil, Keyword.get(opts, :message))
  end

  @doc """
  Asserts all modules in `subject` export the given function.

  ## Example

      modules_matching("**.*Handler")
      |> should_export(:handle, 2)

      modules_matching("MyApp.**.*")
      |> should_export(:child_spec, 1)
  """
  @spec should_export(ModuleSet.t(), atom(), non_neg_integer(), keyword()) :: :ok
  def should_export(%ModuleSet{} = subject, fun_name, arity, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    warn_if_empty(subject_mods, subject, "should_export")

    violations =
      for mod <- subject_mods,
          fns = get_public_functions(mod),
          not ({fun_name, arity} in fns) do
        Violation.naming(
          mod,
          "module does not export #{fun_name}/#{arity}. " <>
            "Add a public `def #{fun_name}/#{arity}` or check the function signature."
        )
      end

    assert_no_violations(violations, "should_export", subject, nil, Keyword.get(opts, :message))
  end

  @doc """
  Asserts no module in `subject` exports the given function.

  ## Example

      modules_matching("MyApp.Domain.**")
      |> should_not_export(:__struct__, 0)

      modules_matching("**.*Controller")
      |> should_not_export(:handle_info, 2)
  """
  @spec should_not_export(ModuleSet.t(), atom(), non_neg_integer(), keyword()) :: :ok
  def should_not_export(%ModuleSet{} = subject, fun_name, arity, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    warn_if_empty(subject_mods, subject, "should_not_export")

    violations =
      for mod <- subject_mods,
          fns = get_public_functions(mod),
          {fun_name, arity} in fns do
        Violation.naming(
          mod,
          "module exports #{fun_name}/#{arity} but should not. " <>
            "Make it private or remove it."
        )
      end

    assert_no_violations(violations, "should_not_export", subject, nil, Keyword.get(opts, :message))
  end

  @doc """
  Asserts all modules in `subject` have at least one public function whose name
  matches the given glob pattern.

  Pattern is matched against the function name only (not arity).

  ## Example

      modules_matching("**.*Repo")
      |> should_have_public_functions_matching("get*")
  """
  @spec should_have_public_functions_matching(ModuleSet.t(), String.t(), keyword()) :: :ok
  def should_have_public_functions_matching(%ModuleSet{} = subject, pattern, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    warn_if_empty(subject_mods, subject, "should_have_public_functions_matching")

    violations =
      for mod <- subject_mods,
          fns = get_public_functions(mod),
          not Enum.any?(fns, fn {name, _arity} ->
            Pattern.matches?(pattern, Atom.to_string(name))
          end) do
        top5 = fns |> Enum.take(5) |> Enum.map_join(", ", fn {n, a} -> "#{n}/#{a}" end)

        Violation.naming(
          mod,
          "module has no public function matching pattern \"#{pattern}\". " <>
            "Sample exports: [#{top5}]"
        )
      end

    assert_no_violations(
      violations,
      "should_have_public_functions_matching",
      subject,
      nil,
      Keyword.get(opts, :message)
    )
  end

  @doc """
  Asserts no module in `subject` has public functions whose names match the pattern.

  Pattern is matched against the function name only.

  ## Example

      modules_matching("MyApp.Domain.**")
      |> should_not_have_public_functions_matching("_*")
  """
  @spec should_not_have_public_functions_matching(ModuleSet.t(), String.t(), keyword()) :: :ok
  def should_not_have_public_functions_matching(%ModuleSet{} = subject, pattern, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    warn_if_empty(subject_mods, subject, "should_not_have_public_functions_matching")

    violations =
      for mod <- subject_mods,
          fns = get_public_functions(mod),
          {name, arity} <- fns,
          Pattern.matches?(pattern, Atom.to_string(name)) do
        Violation.naming(
          mod,
          "module exports #{name}/#{arity} which matches forbidden pattern \"#{pattern}\". " <>
            "Make it private or rename it."
        )
      end

    assert_no_violations(
      violations,
      "should_not_have_public_functions_matching",
      subject,
      nil,
      Keyword.get(opts, :message)
    )
  end

  @doc """
  Asserts that the number of modules matching `subject` satisfies the given constraints.

  Supported constraint keys: `:exactly`, `:at_least`, `:at_most`, `:less_than`, `:more_than`.
  Multiple constraints can be combined.

  Useful to enforce complexity budgets on bounded contexts, or to ensure
  a pattern is not accidentally empty (which would make rules trivially pass).

  ## Options

  In addition to constraint keys, the following options are supported:

  - `:graph` — a pre-built dependency graph map (useful for testing)
  - `:app` — OTP app atom for graph resolution (default: `:all`)
  - `:message` — custom hint appended to the error message on failure

  ## Examples

      # Context must not grow beyond 20 modules
      modules_matching("MyApp.Orders.**")
      |> should_have_module_count(less_than: 20)

      # Pattern must match at least 1 module (catches typos)
      modules_matching("MyApp.Orders.**")
      |> should_have_module_count(at_least: 1)

      # Range constraint
      modules_matching("MyApp.Orders.**")
      |> should_have_module_count(at_least: 2, at_most: 15)
  """
  @spec should_have_module_count(ModuleSet.t(), keyword()) :: :ok
  def should_have_module_count(%ModuleSet{} = subject, constraints) when is_list(constraints) do
    opts_keys = [:graph, :app, :message]
    count_constraints = Keyword.drop(constraints, opts_keys)
    opts = Keyword.take(constraints, opts_keys)

    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    count = length(subject_mods)

    failures =
      count_constraints
      |> Enum.flat_map(fn
        {:exactly, n}   -> if count == n, do: [], else: ["exactly #{n} (got #{count})"]
        {:at_least, n}  -> if count >= n, do: [], else: ["at_least #{n} (got #{count})"]
        {:at_most, n}   -> if count <= n, do: [], else: ["at_most #{n} (got #{count})"]
        {:less_than, n} -> if count < n,  do: [], else: ["less_than #{n} (got #{count})"]
        {:more_than, n} -> if count > n,  do: [], else: ["more_than #{n} (got #{count})"]
        {other, _}      -> ["unknown constraint :#{other}"]
      end)

    if failures == [] do
      :ok
    else
      user_hint = case Keyword.get(opts, :message) do
        nil -> ""
        msg -> "\n  note:    #{msg}"
      end

      constraint_str = count_constraints |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{v}" end)

      raise ExUnit.AssertionError,
        message:
          "ArchTest — should_have_module_count — constraint violated\n" <>
          "  rule:    should_have_module_count\n" <>
          "  subject: #{format_patterns(subject)}\n" <>
          "  constraints: #{constraint_str}\n" <>
          "  actual:  #{count} module(s)\n" <>
          "  failed:  #{Enum.join(failures, ", ")}" <>
          user_hint
    end
  end

  @doc """
  Applies a custom check function to all modules in `subject`.

  The function receives `(graph, module)` and must return a list of
  `ArchTest.Violation` structs (empty list = no violation).

  ## Example

      modules_matching("MyApp.**")
      |> satisfying(fn graph, mod ->
        # custom check logic
        []
      end)
  """
  @spec satisfying(ModuleSet.t(), (Collector.graph(), module() -> [Violation.t()]), keyword()) ::
          :ok
  def satisfying(%ModuleSet{} = subject, check_fn, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)

    warn_if_empty(subject_mods, subject, "satisfying")

    violations =
      subject_mods
      |> Enum.flat_map(fn mod -> check_fn.(graph, mod) end)

    assert_no_violations(violations, "satisfying", subject, nil, Keyword.get(opts, :message))
  end

  @doc """
  Asserts that all modules in `subject` implement the given behaviour.

  A module implements a behaviour if it declares `@behaviour BehaviourModule`,
  which appears in `mod.__info__(:attributes)` as `behaviour: [BehaviourModule]`.

  ## Example

      modules_matching("**.*Handler")
      |> should_implement_behaviour(MyApp.Handler)

      modules_matching("**.*Server")
      |> should_implement_behaviour(GenServer)
  """
  @spec should_implement_behaviour(ModuleSet.t(), module(), keyword()) :: :ok
  def should_implement_behaviour(%ModuleSet{} = subject, behaviour, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    warn_if_empty(subject_mods, subject, "should_implement_behaviour")

    violations =
      for mod <- subject_mods,
          not implements_behaviour?(mod, behaviour) do
        Violation.naming(
          mod,
          "module does not implement behaviour #{inspect(behaviour)}. " <>
            "Add `@behaviour #{inspect(behaviour)}` to the module."
        )
      end

    assert_no_violations(violations, "should_implement_behaviour", subject, nil, Keyword.get(opts, :message))
  end

  @doc """
  Asserts that no module in `subject` implements the given behaviour.

  This is the inverse of `should_implement_behaviour/3` — a violation is
  raised for every module that DOES implement the behaviour.

  ## Example

      modules_matching("**.*Worker")
      |> should_not_implement_behaviour(GenServer)
  """
  @spec should_not_implement_behaviour(ModuleSet.t(), module(), keyword()) :: :ok
  def should_not_implement_behaviour(%ModuleSet{} = subject, behaviour, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    warn_if_empty(subject_mods, subject, "should_not_implement_behaviour")

    violations =
      for mod <- subject_mods,
          implements_behaviour?(mod, behaviour) do
        Violation.naming(
          mod,
          "module implements behaviour #{inspect(behaviour)} but should not. " <>
            "Remove `@behaviour #{inspect(behaviour)}` from the module."
        )
      end

    assert_no_violations(violations, "should_not_implement_behaviour", subject, nil, Keyword.get(opts, :message))
  end

  @doc """
  Asserts that all modules in `subject` implement the given protocol.

  A module `Mod` implements protocol `P` if the module `P.Mod` is loadable
  (i.e. a `defimpl P, for: Mod` block exists somewhere in the codebase).

  ## Example

      modules_matching("**.*Entity")
      |> should_implement_protocol(String.Chars)
  """
  @spec should_implement_protocol(ModuleSet.t(), module(), keyword()) :: :ok
  def should_implement_protocol(%ModuleSet{} = subject, protocol, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    warn_if_empty(subject_mods, subject, "should_implement_protocol")

    violations =
      for mod <- subject_mods,
          not implements_protocol?(mod, protocol) do
        Violation.naming(
          mod,
          "module does not implement protocol #{inspect(protocol)}. " <>
            "Add a `defimpl #{inspect(protocol)}, for: #{inspect(mod)}` block."
        )
      end

    assert_no_violations(violations, "should_implement_protocol", subject, nil, Keyword.get(opts, :message))
  end

  @doc """
  Asserts that no module in `subject` implements the given protocol.

  This is the inverse of `should_implement_protocol/3` — a violation is
  raised for every module that DOES implement the protocol.

  ## Example

      modules_matching("**.*Internal")
      |> should_not_implement_protocol(Jason.Encoder)
  """
  @spec should_not_implement_protocol(ModuleSet.t(), module(), keyword()) :: :ok
  def should_not_implement_protocol(%ModuleSet{} = subject, protocol, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    warn_if_empty(subject_mods, subject, "should_not_implement_protocol")

    violations =
      for mod <- subject_mods,
          implements_protocol?(mod, protocol) do
        Violation.naming(
          mod,
          "module implements protocol #{inspect(protocol)} but should not. " <>
            "Remove the `defimpl #{inspect(protocol)}, for: #{inspect(mod)}` block."
        )
      end

    assert_no_violations(violations, "should_not_implement_protocol", subject, nil, Keyword.get(opts, :message))
  end

  @doc """
  Asserts all modules in `subject` have the given module attribute.

  Checks `mod.__info__(:attributes)` for the presence of the key.

  ## Example

      # All plug modules must declare their behaviour
      modules_matching("MyApp.Plugs.**")
      |> should_have_attribute(:behaviour)
  """
  @spec should_have_attribute(ModuleSet.t(), atom(), keyword()) :: :ok
  def should_have_attribute(%ModuleSet{} = subject, attr_key, opts \\ []) when is_atom(attr_key) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    warn_if_empty(subject_mods, subject, "should_have_attribute")

    violations =
      for mod <- subject_mods,
          attrs = get_module_attributes(mod),
          not Keyword.has_key?(attrs, attr_key) do
        present = attrs |> Keyword.keys() |> Enum.uniq() |> Enum.map(&inspect/1) |> Enum.join(", ")
        Violation.naming(mod, "module does not have attribute :#{attr_key}. Present attributes: [#{present}]")
      end

    assert_no_violations(violations, "should_have_attribute", subject, nil, Keyword.get(opts, :message))
  end

  @doc """
  Asserts all modules in `subject` do NOT have the given module attribute.

  A violation is raised for every module that DOES have the attribute key.

  ## Example

      modules_matching("MyApp.Web.**")
      |> should_not_have_attribute(:deprecated)
  """
  @spec should_not_have_attribute(ModuleSet.t(), atom(), keyword()) :: :ok
  def should_not_have_attribute(%ModuleSet{} = subject, attr_key, opts \\ []) when is_atom(attr_key) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    warn_if_empty(subject_mods, subject, "should_not_have_attribute")

    violations =
      for mod <- subject_mods,
          attrs = get_module_attributes(mod),
          Keyword.has_key?(attrs, attr_key) do
        value = Keyword.get(attrs, attr_key)
        Violation.naming(mod, "module has forbidden attribute :#{attr_key} with value #{inspect(value)}")
      end

    assert_no_violations(violations, "should_not_have_attribute", subject, nil, Keyword.get(opts, :message))
  end

  @doc """
  Asserts all modules in `subject` have the given attribute with the given value.

  ## Example

      modules_matching("**.*Schema")
      |> should_have_attribute_value(:behaviour, [Ecto.Schema])

      modules_matching("MyApp.**")
      |> should_have_attribute_value(:moduledoc, false)
      # (fails for modules with @moduledoc false -- use should_not_have_attribute_value instead)
  """
  @spec should_have_attribute_value(ModuleSet.t(), atom(), term(), keyword()) :: :ok
  def should_have_attribute_value(%ModuleSet{} = subject, attr_key, attr_value, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    warn_if_empty(subject_mods, subject, "should_have_attribute_value")

    violations =
      for mod <- subject_mods,
          attrs = get_module_attributes(mod),
          actual = Keyword.get(attrs, attr_key),
          actual != attr_value do
        Violation.naming(mod, "module attribute :#{attr_key} is #{inspect(actual)}, expected #{inspect(attr_value)}")
      end

    assert_no_violations(violations, "should_have_attribute_value", subject, nil, Keyword.get(opts, :message))
  end

  @doc """
  Asserts all modules in `subject` do NOT have the given attribute with the given value.

  A violation is raised for every module whose attribute matches the forbidden value exactly.

  ## Example

      modules_matching("MyApp.**")
      |> should_not_have_attribute_value(:moduledoc, false)
  """
  @spec should_not_have_attribute_value(ModuleSet.t(), atom(), term(), keyword()) :: :ok
  def should_not_have_attribute_value(%ModuleSet{} = subject, attr_key, attr_value, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    warn_if_empty(subject_mods, subject, "should_not_have_attribute_value")

    violations =
      for mod <- subject_mods,
          attrs = get_module_attributes(mod),
          actual = Keyword.get(attrs, attr_key),
          actual == attr_value do
        Violation.naming(mod, "module has forbidden attribute :#{attr_key} with value #{inspect(attr_value)}")
      end

    assert_no_violations(violations, "should_not_have_attribute_value", subject, nil, Keyword.get(opts, :message))
  end

  @doc """
  Asserts all modules in `subject` use the given module (via `use ModuleName`).

  This is detected heuristically: when a module does `use Foo`, Elixir typically
  adds `:behaviour` or other attributes. This check looks for `module` appearing
  anywhere in the module's flattened attribute values.

  For reliable results with framework modules (GenServer, Ecto.Schema etc.),
  prefer `should_implement_behaviour/2` instead.

  ## Example

      modules_matching("**.*Schema")
      |> should_use(Ecto.Schema)
  """
  @spec should_use(ModuleSet.t(), module(), keyword()) :: :ok
  def should_use(%ModuleSet{} = subject, used_module, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    warn_if_empty(subject_mods, subject, "should_use")

    violations =
      for mod <- subject_mods,
          not module_uses?(mod, used_module) do
        Violation.naming(mod, "module does not appear to use #{inspect(used_module)}. " <>
          "Add `use #{inspect(used_module)}` or check the module attribute :behaviour.")
      end

    assert_no_violations(violations, "should_use", subject, nil, Keyword.get(opts, :message))
  end

  @doc """
  Asserts no module in `subject` uses the given module (via `use ModuleName`).

  This is the inverse of `should_use/3` -- a violation is raised for every
  module that DOES appear to use the given module.

  ## Example

      modules_matching("MyApp.Web.**")
      |> should_not_use(GenServer)
  """
  @spec should_not_use(ModuleSet.t(), module(), keyword()) :: :ok
  def should_not_use(%ModuleSet{} = subject, used_module, opts \\ []) do
    graph = get_graph(opts)
    subject_mods = ModuleSet.resolve(subject, graph)
    warn_if_empty(subject_mods, subject, "should_not_use")

    violations =
      for mod <- subject_mods,
          module_uses?(mod, used_module) do
        Violation.naming(mod, "module appears to use #{inspect(used_module)} but should not. " <>
          "Remove `use #{inspect(used_module)}` from the module.")
      end

    assert_no_violations(violations, "should_not_use", subject, nil, Keyword.get(opts, :message))
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp get_graph(opts) do
    case Keyword.get(opts, :graph) do
      nil ->
        app = Keyword.get(opts, :app, :all)
        Collector.build_graph(app)

      graph when is_map(graph) ->
        graph
    end
  end

  # Warn when the subject resolved to zero modules — almost certainly a
  # wrong pattern, which would silently pass every rule.
  defp warn_if_empty([], subject, rule) do
    patterns = subject.include_patterns |> Enum.map(&inspect/1) |> Enum.join(", ")

    require Logger

    Logger.warning(
      "[ArchTest] #{rule}: subject resolved to 0 modules " <>
        "(patterns: #{patterns}). " <>
        "The rule passes trivially — check your pattern is correct."
    )
  end

  defp warn_if_empty(_mods, _subject, _rule), do: :ok

  defp implements_behaviour?(mod, behaviour) do
    try do
      mod.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()
      |> Enum.member?(behaviour)
    rescue
      _ -> false
    end
  end

  defp implements_protocol?(mod, protocol) do
    impl_module = Module.concat(protocol, mod)
    match?({:module, _}, Code.ensure_loaded(impl_module))
  end

  defp get_public_functions(mod) do
    try do
      mod.__info__(:functions)
    rescue
      _ -> []
    end
  end

  defp get_module_attributes(mod) do
    try do
      mod.__info__(:attributes)
    rescue
      _ -> []
    end
  end

  defp module_uses?(mod, used_module) do
    try do
      attrs = mod.__info__(:attributes)

      attrs
      |> Keyword.values()
      |> List.flatten()
      |> Enum.member?(used_module)
    rescue
      _ -> false
    end
  end

  # Human-readable description of the patterns in a ModuleSet.
  defp format_patterns(%ModuleSet{include_patterns: patterns, exclude_patterns: []}) do
    patterns |> Enum.map(&"\"#{&1}\"") |> Enum.join(" | ")
  end

  defp format_patterns(%ModuleSet{include_patterns: patterns, exclude_patterns: excludes}) do
    inc = patterns |> Enum.map(&"\"#{&1}\"") |> Enum.join(" | ")
    exc = excludes |> Enum.map(&"\"#{&1}\"") |> Enum.join(", ")
    "#{inc} (excluding #{exc})"
  end

  # BFS to find the shortest path between two modules in the graph.
  # Returns a list of modules from `from` to `to` inclusive.
  defp find_shortest_path(graph, from, to) do
    bfs(graph, [[from]], MapSet.new([from]), to)
  end

  defp bfs(_graph, [], _visited, _target), do: []

  defp bfs(graph, [path | rest], visited, target) do
    current = List.last(path)

    if current == target do
      path
    else
      neighbors =
        graph
        |> Map.get(current, [])
        |> Enum.reject(&MapSet.member?(visited, &1))

      new_paths = Enum.map(neighbors, fn n -> path ++ [n] end)
      new_visited = Enum.reduce(neighbors, visited, &MapSet.put(&2, &1))
      bfs(graph, rest ++ new_paths, new_visited, target)
    end
  end

  defp assert_no_violations([], _rule_name, _subject, _object, _user_message), do: :ok

  defp assert_no_violations(violations, rule_name, subject, object, user_message) do
    assert_no_violations_public(violations, rule_name, subject, object, user_message)
  end

  @doc false
  # arity-2: called by Conventions (no subject/object context)
  def assert_no_violations_public([], _rule_name), do: :ok

  def assert_no_violations_public(violations, rule_name) do
    assert_no_violations_public(violations, rule_name, nil, nil, nil)
  end

  # arity-3 with binary: pre-formatted context string from Modulith/Layers
  def assert_no_violations_public([], _rule_name, context) when is_binary(context), do: :ok

  def assert_no_violations_public(violations, rule_name, context) when is_binary(context) do
    count = length(violations)
    formatted = Violation.format_all(violations)

    raise ExUnit.AssertionError,
      message:
        "ArchTest — #{rule_name} — #{count} violation(s) found" <>
          "\n  rule: #{rule_name}" <>
          context <>
          ":\n" <>
          formatted
  end

  # arity-4: no user message (backward-compatible)
  def assert_no_violations_public([], _rule_name, _subject, _object), do: :ok

  def assert_no_violations_public(violations, rule_name, subject, object) do
    assert_no_violations_public(violations, rule_name, subject, object, nil)
  end

  # arity-5: full form with optional user message
  def assert_no_violations_public([], _rule_name, _subject, _object, _user_message), do: :ok

  def assert_no_violations_public(violations, rule_name, subject, object, user_message) do
    count = length(violations)
    formatted = Violation.format_all(violations)
    context_hint = build_context_hint(rule_name, subject, object)

    user_hint =
      case user_message do
        nil -> ""
        msg -> "\n  note:    #{msg}"
      end

    raise ExUnit.AssertionError,
      message:
        "ArchTest — #{rule_name} — #{count} violation(s) found" <>
          context_hint <>
          user_hint <>
          ":\n" <>
          formatted
  end

  defp build_context_hint(rule_name, nil, nil) do
    "\n  rule: #{rule_name}"
  end

  defp build_context_hint(rule_name, subject, nil) do
    patterns = if subject, do: format_patterns(subject), else: "—"

    "\n  rule:    #{rule_name}" <>
      "\n  subject: #{patterns}"
  end

  defp build_context_hint(rule_name, subject, object) do
    sub_patterns = if subject, do: format_patterns(subject), else: "—"
    obj_patterns = if object, do: format_patterns(object), else: "—"

    "\n  rule:    #{rule_name}" <>
      "\n  subject: #{sub_patterns}" <>
      "\n  object:  #{obj_patterns}"
  end
end
