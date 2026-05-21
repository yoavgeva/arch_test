defmodule ArchTest.Rule do
  @moduledoc """
  Represents an architecture rule — a description and a check function that
  evaluates against the dependency graph and returns a list of violations.
  """

  alias ArchTest.Violation

  @enforce_keys [:description, :check_fn]
  defstruct [:description, :check_fn, ignore: [], freeze_id: nil]

  @type graph :: %{module() => [module()]}

  @type t :: %__MODULE__{
          description: String.t(),
          check_fn: (graph() -> [Violation.t()]),
          ignore: keyword(),
          freeze_id: String.t() | nil
        }

  @doc """
  Creates a reusable architecture rule from a graph check function.
  """
  @spec new(String.t(), (graph() -> [Violation.t()])) :: t()
  def new(description, check_fn) when is_binary(description) and is_function(check_fn, 1) do
    %__MODULE__{description: description, check_fn: check_fn}
  end

  @doc """
  Adds ignore filters to a reusable rule.

  Supported keys: `:caller`, `:callee`, and `:module`, each with a module glob
  pattern or list of patterns.
  """
  @spec ignore(t(), keyword()) :: t()
  def ignore(%__MODULE__{} = rule, filters) when is_list(filters) do
    %{rule | ignore: merge_ignore_filters(rule.ignore, filters)}
  end

  @doc """
  Attaches a freeze baseline id to the rule.
  """
  @spec freeze(t(), String.t()) :: t()
  def freeze(%__MODULE__{} = rule, freeze_id) when is_binary(freeze_id) do
    %{rule | freeze_id: freeze_id}
  end

  @doc """
  Evaluates a rule against the given dependency graph.

  Returns `{:ok, []}` when no violations are found, or
  `{:violations, [Violation.t()]}` otherwise.
  """
  @spec evaluate(t(), graph()) :: {:ok, []} | {:violations, [Violation.t()]}
  def evaluate(%__MODULE__{check_fn: check_fn, ignore: ignore}, graph) do
    case check_fn.(graph) |> reject_ignored(ignore) do
      [] -> {:ok, []}
      violations -> {:violations, violations}
    end
  end

  @doc """
  Evaluates a reusable rule and raises an ExUnit assertion on violations.

  Options:
  - `:graph` — pre-built graph
  - `:app` — app to inspect when `:graph` is not present
  """
  @spec assert(t(), keyword()) :: :ok
  def assert(%__MODULE__{} = rule, opts \\ []) do
    graph =
      Keyword.get(opts, :graph) ||
        ArchTest.Collector.build_graph(Keyword.get(opts, :app, :all), opts)

    assertion = fn ->
      violations =
        rule.check_fn.(graph)
        |> reject_ignored(rule.ignore)

      ArchTest.Assertions.assert_no_violations_public(violations, "rule — #{rule.description}")
    end

    case rule.freeze_id do
      nil -> assertion.()
      freeze_id -> ArchTest.Freeze.freeze(freeze_id, assertion)
    end
  end

  defp reject_ignored(violations, []), do: violations

  defp reject_ignored(violations, filters) do
    Enum.reject(violations, &ignored?(&1, filters))
  end

  defp merge_ignore_filters(existing, new) do
    Keyword.merge(existing, new, fn _key, left, right ->
      List.wrap(left) ++ List.wrap(right)
    end)
  end

  defp ignored?(%Violation{} = violation, filters) do
    Enum.any?(filters, fn {field, patterns} ->
      field_value(violation, field)
      |> matches_any?(List.wrap(patterns))
    end)
  end

  defp field_value(%Violation{} = violation, :caller), do: violation.caller
  defp field_value(%Violation{} = violation, :callee), do: violation.callee
  defp field_value(%Violation{} = violation, :module), do: violation.module
  defp field_value(_violation, _field), do: nil

  defp matches_any?(nil, _patterns), do: false

  defp matches_any?(module, patterns) do
    mod_str = ArchTest.Pattern.module_to_string(module)
    Enum.any?(patterns, &ArchTest.Pattern.matches?(&1, mod_str))
  end
end
