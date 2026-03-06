defmodule ArchTest.ModuleSet do
  @moduledoc """
  Represents a lazy selection of modules for use in architecture rules.

  A `ModuleSet` is created with one or more include patterns and optional
  exclude patterns. Actual module resolution is deferred until
  `resolve/2` is called with a dependency graph.

  ## Building a ModuleSet

      import ArchTest

      modules_matching("MyApp.Orders.*")
      modules_matching("MyApp.Orders.**")
      modules_in("MyApp.Orders")
      all_modules()

  ## Composing ModuleSets

      modules_matching("**.*Controller")
      |> excluding("MyApp.Web.ErrorController")

      modules_matching("**.*Service")
      |> union(modules_matching("**.*View"))

      modules_matching("MyApp.**")
      |> intersection(modules_matching("**.*Schema"))
  """

  alias ArchTest.Pattern

  @enforce_keys [:include_patterns]
  defstruct include_patterns: [],
            exclude_patterns: [],
            custom_filter: nil,
            app: nil

  @type t :: %__MODULE__{
          include_patterns: [String.t()],
          exclude_patterns: [String.t()],
          custom_filter: (module() -> boolean()) | nil,
          app: atom() | nil
        }

  @doc """
  Creates a `ModuleSet` matching the given glob pattern.

  ## Examples

      iex> import ArchTest
      iex> ms = modules_matching("MyApp.Orders.*")
      iex> %ArchTest.ModuleSet{include_patterns: ["MyApp.Orders.*"]} = ms
  """
  @spec new(String.t() | [String.t()]) :: t()
  def new(pattern) when is_binary(pattern) do
    %__MODULE__{include_patterns: [pattern]}
  end

  def new(patterns) when is_list(patterns) do
    %__MODULE__{include_patterns: patterns}
  end

  @doc """
  Creates a `ModuleSet` that matches all modules.
  """
  @spec all() :: t()
  def all do
    %__MODULE__{include_patterns: ["**"]}
  end

  @doc """
  Creates a `ModuleSet` for all direct children of `namespace`.

  Equivalent to `modules_matching("Namespace.*")`.
  """
  @spec in_namespace(String.t()) :: t()
  def in_namespace(namespace) do
    %__MODULE__{include_patterns: ["#{namespace}.*"]}
  end

  @doc """
  Creates a `ModuleSet` using a custom filter function.

  The function receives a module atom and returns `true` to include it.

  ## Example

      modules_satisfying(fn mod ->
        function_exported?(mod, :__schema__, 1)
      end)
  """
  @spec satisfying((module() -> boolean())) :: t()
  def satisfying(filter_fn) when is_function(filter_fn, 1) do
    %__MODULE__{include_patterns: ["**"], custom_filter: filter_fn}
  end

  @doc """
  Adds exclude patterns to a `ModuleSet`.
  """
  @spec excluding(t(), String.t() | [String.t()]) :: t()
  def excluding(%__MODULE__{} = ms, pattern) when is_binary(pattern) do
    %{ms | exclude_patterns: ms.exclude_patterns ++ [pattern]}
  end

  def excluding(%__MODULE__{} = ms, patterns) when is_list(patterns) do
    %{ms | exclude_patterns: ms.exclude_patterns ++ patterns}
  end

  @doc """
  Returns a new `ModuleSet` matching modules in *either* set (union / OR).

  A module is included if it matches set `a` OR set `b` (with each set's
  own include/exclude/custom_filter applied independently).
  """
  @spec union(t(), t()) :: t()
  def union(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      include_patterns: ["**"],
      custom_filter: fn mod ->
        module_matches?(a, mod) or module_matches?(b, mod)
      end
    }
  end

  @doc """
  Returns a new `ModuleSet` matching modules in *both* sets (intersection / AND).

  A module is included only if it matches both set `a` AND set `b`.
  """
  @spec intersection(t(), t()) :: t()
  def intersection(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      include_patterns: ["**"],
      custom_filter: fn mod ->
        module_matches?(a, mod) and module_matches?(b, mod)
      end
    }
  end

  @doc """
  Resolves the `ModuleSet` against the given dependency graph.

  Returns the list of actual module atoms that match the set's patterns.
  """
  @spec resolve(t(), ArchTest.Collector.graph()) :: [module()]
  def resolve(%__MODULE__{} = ms, graph) do
    all_mods = Map.keys(graph)

    all_mods
    |> Enum.filter(&module_matches?(ms, &1))
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp module_matches?(%__MODULE__{} = ms, mod) do
    mod_str = Pattern.module_to_string(mod)

    included?(ms.include_patterns, mod_str) and
      not excluded?(ms.exclude_patterns, mod_str) and
      passes_custom_filter?(ms.custom_filter, mod)
  end

  defp included?([], _mod_str), do: false

  defp included?(patterns, mod_str) do
    Enum.any?(patterns, &Pattern.matches?(&1, mod_str))
  end

  defp excluded?([], _mod_str), do: false

  defp excluded?(patterns, mod_str) do
    Enum.any?(patterns, &Pattern.matches?(&1, mod_str))
  end

  defp passes_custom_filter?(nil, _mod), do: true
  defp passes_custom_filter?(filter_fn, mod), do: filter_fn.(mod)
end
