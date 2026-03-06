defmodule ArchTest.Violation do
  @moduledoc """
  Represents a single architecture rule violation.

  Violations are collected during rule evaluation and reported as
  ExUnit assertion failures with human-readable messages.
  """

  @enforce_keys [:type, :message]
  defstruct [
    :type,
    :caller,
    :callee,
    :module,
    :path,
    :message
  ]

  @type violation_type ::
          :forbidden_dep
          | :missing_dep
          | :naming
          | :existence
          | :cycle
          | :metric
          | :custom

  @type t :: %__MODULE__{
          type: violation_type(),
          caller: module() | nil,
          callee: module() | nil,
          module: module() | nil,
          path: [module()] | nil,
          message: String.t()
        }

  @doc """
  Formats a list of violations into a human-readable string for ExUnit output.

  Groups violations by offending module where possible and adds visual
  separators for readability.
  """
  @spec format_all([t()]) :: String.t()
  def format_all([]), do: "(no violations)"

  def format_all(violations) do
    grouped = group_violations(violations)

    sections =
      grouped
      |> Enum.map(fn {group_key, group_violations} ->
        format_group(group_key, group_violations)
      end)
      |> Enum.join("\n\n  #{String.duplicate("─", 60)}\n\n")

    "\n\n#{sections}\n"
  end

  @doc """
  Formats a single violation into a human-readable string.
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = v), do: format_single(v)

  @doc """
  Builds a `:forbidden_dep` violation.
  """
  @spec forbidden_dep(module(), module(), String.t()) :: t()
  def forbidden_dep(caller, callee, reason) do
    %__MODULE__{
      type: :forbidden_dep,
      caller: caller,
      callee: callee,
      message: reason
    }
  end

  @doc """
  Builds a `:forbidden_dep` violation with a transitive path shown.
  """
  @spec transitive_dep(module(), module(), [module()], String.t()) :: t()
  def transitive_dep(caller, callee, path, reason) do
    %__MODULE__{
      type: :forbidden_dep,
      caller: caller,
      callee: callee,
      path: path,
      message: reason
    }
  end

  @doc """
  Builds a `:naming` violation.
  """
  @spec naming(module(), String.t()) :: t()
  def naming(mod, reason) do
    %__MODULE__{
      type: :naming,
      module: mod,
      message: reason
    }
  end

  @doc """
  Builds an `:existence` violation (module should not exist).
  """
  @spec existence(module(), String.t()) :: t()
  def existence(mod, reason) do
    %__MODULE__{
      type: :existence,
      module: mod,
      message: reason
    }
  end

  @doc """
  Builds a `:cycle` violation.
  """
  @spec cycle([module()], String.t()) :: t()
  def cycle(cycle_path, reason) do
    %__MODULE__{
      type: :cycle,
      path: cycle_path,
      message: reason
    }
  end

  # ------------------------------------------------------------------
  # Private formatting
  # ------------------------------------------------------------------

  # Groups violations by their primary module (caller or module field).
  # Ungroupable violations (e.g. cycles) get their own :ungrouped bucket.
  defp group_violations(violations) do
    violations
    |> Enum.group_by(fn
      %{caller: caller} when not is_nil(caller) -> caller
      %{module: mod} when not is_nil(mod) -> mod
      _ -> :ungrouped
    end)
    |> Enum.sort_by(fn {key, _} ->
      case key do
        :ungrouped -> ""
        atom -> inspect(atom)
      end
    end)
  end

  defp format_group(:ungrouped, violations) do
    violations
    |> Enum.map(&format_single/1)
    |> Enum.join("\n\n")
  end

  defp format_group(mod, violations) do
    header = "  #{inspect(mod)}"

    items =
      violations
      |> Enum.map(&format_single/1)
      |> Enum.join("\n")

    "#{header}\n#{items}"
  end

  defp format_single(%__MODULE__{type: :cycle, path: path, message: msg}) when not is_nil(path) do
    arrow_chain =
      path
      |> Enum.map(&inspect/1)
      |> Enum.join(" → ")

    # Show the cycle closing back to start
    closing = inspect(List.first(path))

    """
    ┌─ Circular dependency detected ─────────────────────────────
    │  #{arrow_chain} → #{closing}
    │
    │  #{msg}
    └─────────────────────────────────────────────────────────────\
    """
    |> indent(2)
  end

  defp format_single(%__MODULE__{caller: caller, callee: callee, path: path, message: msg})
       when not is_nil(caller) and not is_nil(callee) and not is_nil(path) do
    # Transitive dependency: show the full path
    path_str =
      path
      |> Enum.map(&inspect/1)
      |> Enum.join("\n    │    → ")

    """
        ✗ depends on #{inspect(callee)}  [transitive]
          #{msg}
          via: #{path_str}\
    """
  end

  defp format_single(%__MODULE__{caller: _caller, callee: callee, message: msg})
       when not is_nil(callee) do
    "    ✗ depends on #{inspect(callee)}\n      #{msg}"
  end

  defp format_single(%__MODULE__{type: :existence, module: mod, message: msg})
       when not is_nil(mod) do
    "    ✗ #{inspect(mod)}\n      #{msg}"
  end

  defp format_single(%__MODULE__{module: mod, message: msg}) when not is_nil(mod) do
    "    ✗ #{inspect(mod)}\n      #{msg}"
  end

  defp format_single(%__MODULE__{message: msg}), do: "    ✗ #{msg}"

  defp indent(str, spaces) do
    pad = String.duplicate(" ", spaces)

    str
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> pad <> line
    end)
  end
end
