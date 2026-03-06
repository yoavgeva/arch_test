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
      metrics = compute_metrics(mod, graph, subject)
      Map.put(acc, mod, metrics)
    end)
  end

  @doc """
  Returns coupling metrics for the given module (or namespace root).

  If a namespace pattern is given (e.g., `"MyApp.Orders"`), it computes
  aggregate metrics treating all matching modules as a single package.
  """
  @spec coupling(String.t() | module(), keyword()) :: metric_map()
  def coupling(module_or_pattern, opts \\ []) do
    graph = get_graph(opts)

    mods =
      case module_or_pattern do
        m when is_atom(m) ->
          MapSet.new([m])

        pattern when is_binary(pattern) ->
          ModuleSet.new(pattern) |> ModuleSet.resolve(graph) |> MapSet.new()
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

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp get_graph(opts) do
    case Keyword.get(opts, :graph) do
      nil -> Collector.build_graph(Keyword.get(opts, :app, :all))
      graph -> graph
    end
  end

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
      |> Enum.count(fn mod ->
        deps = Collector.dependencies_of(graph, mod)

        Enum.any?(deps, fn dep ->
          MapSet.member?(all_module_keys, dep) and not MapSet.member?(mods, dep)
        end)
      end)

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
    # A module is a behaviour if it defines callbacks via behaviour_info/1
    try do
      callbacks = mod.behaviour_info(:callbacks)
      is_list(callbacks) and callbacks != []
    rescue
      _ -> false
    end
  end

  defp protocol?(mod) do
    try do
      function_exported?(mod, :__protocol__, 1) and mod.__protocol__(:functions) != []
    rescue
      _ -> false
    end
  end

  defp average([]), do: 0.0

  defp average(list) do
    Enum.sum(list) / length(list)
  end
end
