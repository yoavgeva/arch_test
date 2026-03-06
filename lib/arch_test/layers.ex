defmodule ArchTest.Layers do
  @moduledoc """
  Layered architecture enforcement.

  Define layers top-to-bottom; `enforce_direction/1` ensures each layer
  only depends on layers below it (never upward).

  ## Example

      define_layers(
        web:     "MyApp.Web.**",
        context: "MyApp.**",
        repo:    "MyApp.Repo.**"
      )
      |> enforce_direction()

  ## Onion / Hexagonal Architecture

      define_onion(
        domain:      "MyApp.Domain.**",
        application: "MyApp.Application.**",
        adapters:    "MyApp.Adapters.**"
      )
      |> enforce_onion_rules()
  """

  alias ArchTest.{Assertions, Collector, ModuleSet, Violation}

  defstruct layers: [], custom_rules: [], app: nil

  @type layer_name :: atom()
  @type t :: %__MODULE__{
          layers: [{layer_name(), String.t()}],
          custom_rules: [
            {layer_name(), :may_only_depend_on | :may_not_depend_on, [layer_name()]}
          ],
          app: atom() | nil
        }

  @doc """
  Defines an ordered list of architecture layers (top to bottom).

  Accepts a keyword list of `layer_name: "Pattern"` pairs.
  Order matters: earlier entries are "higher" layers.
  """
  @spec define_layers(keyword()) :: t()
  def define_layers(layer_defs) when is_list(layer_defs) do
    %__MODULE__{layers: layer_defs}
  end

  @doc """
  Defines an onion/hexagonal architecture with ordered rings (innermost first).

  Equivalent to `define_layers/1` but with onion semantics applied in
  `enforce_onion_rules/1`.
  """
  @spec define_onion(keyword()) :: t()
  def define_onion(layer_defs) when is_list(layer_defs) do
    %__MODULE__{layers: layer_defs}
  end

  @doc """
  Adds a custom rule: the given layer may only depend on listed layers.
  """
  @spec layer_may_only_depend_on(t(), layer_name(), [layer_name()]) :: t()
  def layer_may_only_depend_on(%__MODULE__{} = arch, layer, allowed_layers) do
    rule = {layer, :may_only_depend_on, allowed_layers}
    %{arch | custom_rules: arch.custom_rules ++ [rule]}
  end

  @doc """
  Adds a custom rule: the given layer may not depend on listed layers.
  """
  @spec layer_may_not_depend_on(t(), layer_name(), [layer_name()]) :: t()
  def layer_may_not_depend_on(%__MODULE__{} = arch, layer, forbidden_layers) do
    rule = {layer, :may_not_depend_on, forbidden_layers}
    %{arch | custom_rules: arch.custom_rules ++ [rule]}
  end

  @doc """
  Sets the OTP application to introspect (default: `:all`).
  """
  @spec for_app(t(), atom()) :: t()
  def for_app(%__MODULE__{} = arch, app), do: %{arch | app: app}

  @doc """
  Enforces that each layer only depends on layers below it in the ordered list.

  Violations are raised as ExUnit assertion failures.
  """
  @spec enforce_direction(t()) :: :ok
  def enforce_direction(%__MODULE__{} = arch) do
    graph = Collector.build_graph(arch.app || :all)
    layer_names = Keyword.keys(arch.layers)

    violations =
      arch.layers
      |> Enum.with_index()
      |> Enum.flat_map(fn {{layer_name, pattern}, idx} ->
        # Layers above this one (higher index = lower in stack)
        higher_layers = Enum.take(layer_names, idx)

        higher_layer_modules =
          higher_layers
          |> Enum.flat_map(fn l ->
            p = Keyword.fetch!(arch.layers, l)
            ModuleSet.new(p) |> ModuleSet.resolve(graph)
          end)
          |> MapSet.new()

        layer_modules = ModuleSet.new(pattern) |> ModuleSet.resolve(graph)

        for mod <- layer_modules,
            dep <- Collector.dependencies_of(graph, mod),
            MapSet.member?(higher_layer_modules, dep) do
          dep_layer = find_layer(dep, arch.layers, graph)

          Violation.forbidden_dep(
            mod,
            dep,
            "layer :#{layer_name} must not depend on :#{dep_layer} (which is a higher layer). " <>
              "Dependencies must flow downward only."
          )
        end
      end)

    # Also evaluate custom rules
    custom_violations = evaluate_custom_rules(arch, graph)

    all_violations = violations ++ custom_violations

    layer_names = arch.layers |> Keyword.keys() |> Enum.map_join(" → ", &":#{&1}")

    Assertions.assert_no_violations_public(
      all_violations,
      "layers — enforce_direction",
      "\n  layers: #{layer_names} (top → bottom)"
    )
  end

  @doc """
  Enforces onion/hexagonal architecture rules:
  - Inner rings (listed first) must not depend on outer rings
  - Outer rings may depend on inner rings

  In other words: dependencies can only point inward.
  """
  @spec enforce_onion_rules(t()) :: :ok
  def enforce_onion_rules(%__MODULE__{} = arch) do
    # For onion architecture, innermost is listed first.
    # Inner rings must not depend on outer rings (higher index = outer).
    graph = Collector.build_graph(arch.app || :all)
    layer_names = Keyword.keys(arch.layers)
    total = length(layer_names)

    violations =
      arch.layers
      |> Enum.with_index()
      |> Enum.flat_map(fn {{layer_name, pattern}, idx} ->
        # Outer layers (higher index)
        outer_layers = Enum.drop(layer_names, idx + 1)

        outer_modules =
          outer_layers
          |> Enum.flat_map(fn l ->
            p = Keyword.fetch!(arch.layers, l)
            ModuleSet.new(p) |> ModuleSet.resolve(graph)
          end)
          |> MapSet.new()

        layer_modules = ModuleSet.new(pattern) |> ModuleSet.resolve(graph)

        for mod <- layer_modules,
            dep <- Collector.dependencies_of(graph, mod),
            MapSet.member?(outer_modules, dep) do
          dep_layer = find_layer(dep, arch.layers, graph)

          Violation.forbidden_dep(
            mod,
            dep,
            "onion rule: :#{layer_name} (ring #{idx + 1}/#{total}) must not depend on " <>
              "outer ring :#{dep_layer}. In an onion architecture, " <>
              "dependencies must point inward only."
          )
        end
      end)

    layer_names = arch.layers |> Keyword.keys() |> Enum.map_join(" → ", &":#{&1}")

    Assertions.assert_no_violations_public(
      violations,
      "layers — enforce_onion_rules",
      "\n  rings: #{layer_names} (innermost → outermost)"
    )
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp evaluate_custom_rules(%__MODULE__{custom_rules: rules, layers: layers}, graph) do
    Enum.flat_map(rules, fn {layer_name, rule_type, target_layers} ->
      pattern = Keyword.fetch!(layers, layer_name)
      layer_modules = ModuleSet.new(pattern) |> ModuleSet.resolve(graph)

      case rule_type do
        :may_only_depend_on ->
          allowed_mods =
            target_layers
            |> Enum.flat_map(fn l ->
              p = Keyword.fetch!(layers, l)
              ModuleSet.new(p) |> ModuleSet.resolve(graph)
            end)
            |> MapSet.new()

          for mod <- layer_modules,
              dep <- Collector.dependencies_of(graph, mod),
              Map.has_key?(graph, dep),
              not MapSet.member?(allowed_mods, dep) do
            dep_layer = find_layer(dep, layers, graph)

            allowed_str = target_layers |> Enum.map_join(", ", &":#{&1}")

            Violation.forbidden_dep(
              mod,
              dep,
              "layer :#{layer_name} may only depend on [#{allowed_str}] " <>
                "but depends on :#{dep_layer}."
            )
          end

        :may_not_depend_on ->
          forbidden_mods =
            target_layers
            |> Enum.flat_map(fn l ->
              p = Keyword.fetch!(layers, l)
              ModuleSet.new(p) |> ModuleSet.resolve(graph)
            end)
            |> MapSet.new()

          for mod <- layer_modules,
              dep <- Collector.dependencies_of(graph, mod),
              MapSet.member?(forbidden_mods, dep) do
            dep_layer = find_layer(dep, layers, graph)

            Violation.forbidden_dep(
              mod,
              dep,
              "layer :#{layer_name} must not depend on :#{dep_layer} (explicitly forbidden)."
            )
          end
      end
    end)
  end

  defp find_layer(mod, layers, graph) do
    Enum.find_value(layers, :unknown, fn {layer_name, pattern} ->
      mods = ModuleSet.new(pattern) |> ModuleSet.resolve(graph)
      if mod in mods, do: layer_name
    end)
  end
end
