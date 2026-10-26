defmodule ArchTest.Metrics do
  @moduledoc """
  Coupling and instability metrics for architecture analysis.

  Implements Robert C. Martin's package metrics:

  - **Afferent coupling (Ca)** — number of modules outside the package that
    depend on modules inside it. High Ca = the package is used a lot (stable).
  - **Efferent coupling (Ce)** — number of modules inside the package that
    depend on modules outside it. High Ce = the package depends on many others.
  - **Instability (I)** — `Ce / (Ca + Ce)`. Range: 0 (stable) to 1 (unstable).
  - **Abstractness (A)** — ratio of abstract modules (behaviours, protocols)
    to total modules. Range: 0 to 1.
  - **Distance from main sequence (D)** — `|A + I - 1|`. Ideal = 0.

  ## Usage

      # Per-module metrics for a namespace
      metrics = ArchTest.Metrics.martin("MyApp.**")
      # %{MyApp.Orders => %{instability: 0.6, abstractness: 0.0, distance: 0.4}, ...}

      # Single module coupling
      ArchTest.Metrics.coupling("MyApp.Orders")
      # %{afferent: 3, efferent: 7, instability: 0.7}

      ArchTest.Metrics.afferent("MyApp.Orders")
      ArchTest.Metrics.efferent("MyApp.Orders")

      # Assert on metrics
      assert ArchTest.Metrics.instability("MyApp.Orders") < 0.5
  """

  alias ArchTest.{Collector, ModuleSet}

  @type metric_map :: %{
          afferent: non_neg_integer(),
          efferent: non_neg_integer(),
          instability: float(),
          abstractness: float(),
          distance: float()
        }

  @doc """
  Computes Martin's package metrics for all modules matching `pattern`.

  Returns a map of `module => metric_map`.
  """
  @spec martin(String.t(), keyword()) :: %{module() => metric_map()}
  def martin(pattern, opts \\ []) do
    graph = get_graph(opts)
    subject = ModuleSet.new(pattern) |> ModuleSet.resolve(graph) |> MapSet.new()

    Enum.reduce(subject, %{}, fn mod, acc ->
      metrics = compute_metrics(mod, graph, MapSet.new([mod]))
      Map.put(acc, mod, metrics)
    end)
  end

  @doc """
  Returns coupling metrics for the given module (or namespace root).

  If a namespace pattern is given (e.g., `"MyApp.Orders"`), it computes
  aggregate metrics treating the root and descendants as a single package.
  Pass a module atom to measure only that exact module.
  """
  @spec coupling(String.t() | module(), keyword()) :: metric_map()
  def coupling(module_or_pattern, opts \\ []) do
    graph = get_graph(opts)

    mods =
      case module_or_pattern do
        m when is_atom(m) ->
          MapSet.new([m])

        pattern when is_binary(pattern) ->
          pattern
          |> modules_for_binary_pattern(graph)
          |> MapSet.new()
      end

    compute_package_metrics(mods, graph)
  end

  @doc """
  Returns the instability value for a single module or namespace.

  Range: 0.0 (maximally stable) to 1.0 (maximally unstable).
  """
  @spec instability(String.t() | module(), keyword()) :: float()
  def instability(module_or_pattern, opts \\ []) do
    coupling(module_or_pattern, opts).instability
  end

  @doc """
  Returns the abstractness value for a single module or namespace.

  Range: 0.0 (fully concrete) to 1.0 (fully abstract).
  """
  @spec abstractness(String.t() | module(), keyword()) :: float()
  def abstractness(module_or_pattern, opts \\ []) do
    coupling(module_or_pattern, opts).abstractness
  end

  @doc """
  Returns afferent coupling (`Ca`) for a module or namespace.
  """
  @spec afferent(String.t() | module(), keyword()) :: non_neg_integer()
  def afferent(module_or_pattern, opts \\ []) do
    coupling(module_or_pattern, opts).afferent
  end

  @doc """
  Returns efferent coupling (`Ce`) for a module or namespace.
  """
  @spec efferent(String.t() | module(), keyword()) :: non_neg_integer()
  def efferent(module_or_pattern, opts \\ []) do
    coupling(module_or_pattern, opts).efferent
  end

  @doc """
  Counts modules that depend directly on the given module.
  """
  @spec fan_in(module(), keyword()) :: non_neg_integer()
  def fan_in(module, opts \\ []) when is_atom(module) do
    opts
    |> get_graph()
    |> Enum.count(fn {_caller, deps} -> module in deps end)
  end

  @doc """
  Counts direct dependencies of the given module that are present in the graph.
  """
  @spec fan_out(module(), keyword()) :: non_neg_integer()
  def fan_out(module, opts \\ []) when is_atom(module) do
    graph = get_graph(opts)
    known_modules = MapSet.new(Map.keys(graph))

    graph
    |> Collector.dependencies_of(module)
    |> Enum.count(&MapSet.member?(known_modules, &1))
  end

  @doc """
  Returns the longest dependency path depth from the given module.
  """
  @spec dependency_depth(module(), keyword()) :: non_neg_integer()
  def dependency_depth(module, opts \\ []) when is_atom(module) do
    graph = get_graph(opts)
    do_depth(graph, module, MapSet.new())
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp get_graph(opts) do
    case Keyword.get(opts, :graph) do
      nil -> Collector.build_graph(Keyword.get(opts, :app, :all), opts)
      graph -> graph
    end
  end

  defp modules_for_binary_pattern(pattern, graph) do
    if glob_pattern?(pattern) do
      ModuleSet.new(pattern) |> ModuleSet.resolve(graph)
    else
      root = ModuleSet.new(pattern) |> ModuleSet.resolve(graph)
      descendants = ModuleSet.new("#{pattern}.**") |> ModuleSet.resolve(graph)
      Enum.uniq(root ++ descendants)
    end
  end

  defp glob_pattern?(pattern), do: String.contains?(pattern, ["*", "?"])

  defp compute_metrics(mod, graph, subject_set) do
    ca = afferent_coupling(mod, graph, subject_set)
    ce = efferent_coupling(mod, graph, subject_set)
    i = instability_value(ca, ce)
    a = abstractness_value(mod)
    d = abs(a + i - 1.0)

    %{afferent: ca, efferent: ce, instability: i, abstractness: a, distance: d}
  end

  defp compute_package_metrics(mods, graph) do
    all_module_keys = MapSet.new(Map.keys(graph))

    ca =
      graph
      |> Enum.count(fn {caller, deps} ->
        not MapSet.member?(mods, caller) and
          Enum.any?(deps, &MapSet.member?(mods, &1))
      end)

    ce =
      mods
      |> Enum.flat_map(&Collector.dependencies_of(graph, &1))
      |> Enum.filter(fn dep ->
        MapSet.member?(all_module_keys, dep) and not MapSet.member?(mods, dep)
      end)
      |> Enum.uniq()
      |> length()

    i = instability_value(ca, ce)

    a =
      mods
      |> Enum.map(&abstractness_value/1)
      |> average()

    d = abs(a + i - 1.0)

    %{afferent: ca, efferent: ce, instability: i, abstractness: a, distance: d}
  end

  defp afferent_coupling(mod, graph, subject_set) do
    graph
    |> Enum.count(fn {caller, deps} ->
      MapSet.member?(subject_set, caller) == false and mod in deps
    end)
  end

  defp efferent_coupling(mod, graph, subject_set) do
    mod
    |> then(&Collector.dependencies_of(graph, &1))
    |> Enum.count(fn dep -> not MapSet.member?(subject_set, dep) end)
  end

  defp instability_value(ca, ce) do
    total = ca + ce
    if total == 0, do: 0.0, else: ce / total
  end

  # Abstractness = 1.0 for behaviours/protocols, 0.0 for concrete modules.
  defp abstractness_value(mod) do
    cond do
      behaviour?(mod) -> 1.0
      protocol?(mod) -> 1.0
      true -> 0.0
    end
  end

  defp behaviour?(mod) do
    # A module is a behaviour if it defines callbacks via behaviour_info/1, which raises for other modules
    mod.behaviour_info(:callbacks) != []
  rescue
    _ -> false
  end

  defp protocol?(mod) do
    function_exported?(mod, :__protocol__, 1) and mod.__protocol__(:functions) != []
  rescue
    _ -> false
  end

  defp average([]), do: 0.0

  defp average(list) do
    Enum.sum(list) / length(list)
  end

  defp do_depth(graph, module, visited) do
    deps =
      graph
      |> Collector.dependencies_of(module)
      |> Enum.reject(&MapSet.member?(visited, &1))

    case deps do
      [] ->
        0

      deps ->
        next_visited = MapSet.put(visited, module)
        1 + (deps |> Enum.map(&do_depth(graph, &1, next_visited)) |> Enum.max())
    end
  end
end
