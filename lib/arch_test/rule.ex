defmodule ArchTest.Rule do
  @moduledoc """
  Represents an architecture rule — a description and a check function that
  evaluates against the dependency graph and returns a list of violations.
  """

  alias ArchTest.Violation

  @enforce_keys [:description, :check_fn]
  defstruct [:description, :check_fn]

  @type graph :: %{module() => [module()]}

  @type t :: %__MODULE__{
          description: String.t(),
          check_fn: (graph() -> [Violation.t()])
        }

  @doc """
  Evaluates a rule against the given dependency graph.

  Returns `{:ok, []}` when no violations are found, or
  `{:violations, [Violation.t()]}` otherwise.
  """
  @spec evaluate(t(), graph()) :: {:ok, []} | {:violations, [Violation.t()]}
  def evaluate(%__MODULE__{check_fn: check_fn}, graph) do
    case check_fn.(graph) do
      [] -> {:ok, []}
      violations -> {:violations, violations}
    end
  end
end
