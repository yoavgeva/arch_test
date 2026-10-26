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
    :file,
    :line,
    :caller_function,
    :callee_function,
    :message,
    :rule,
    :fix
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
          file: String.t() | nil,
          line: pos_integer() | nil,
          caller_function: {atom(), non_neg_integer()} | nil,
          callee_function: {atom(), non_neg_integer()} | nil,
          message: String.t(),
          rule: String.t() | nil,
          fix: String.t() | nil
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
      |> Enum.map_join("\n\n  #{String.duplicate("─", 60)}\n\n", fn {group_key, group_violations} ->
        format_group(group_key, group_violations)
      end)

    "\n\n#{sections}\n"
  end

  @doc """
  Formats a single violation into a human-readable string.
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = v), do: format_single(v)

  @doc """
  Returns a stable, structured key suitable for freeze baselines.

  The key is intentionally line-oriented and text-friendly, but it is derived
  from the violation struct rather than parsed from rendered assertion output.
  A violation's `rule` and `fix` aren't part of it, so rewording a fix keeps
  baselines valid.
  """
  @spec key(t()) :: String.t()
  def key(%__MODULE__{} = v) do
    [
      {"type", v.type},
      {"caller", v.caller},
      {"callee", v.callee},
      {"module", v.module},
      {"path", format_path(v.path)},
      {"caller_function", format_function(v.caller_function)},
      {"callee_function", format_function(v.callee_function)},
      {"location", format_location(v.file, v.line)},
      {"message", normalize_message(v.message)}
    ]
    |> Enum.map_join("\t", fn {key, value} -> "#{key}=#{format_value(value)}" end)
  end

  @doc """
  Returns sorted stable keys for all violations.
  """
  @spec keys([t()]) :: [String.t()]
  def keys(violations) do
    violations
    |> Enum.map(&key/1)
    |> Enum.sort()
  end

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
    Enum.map_join(violations, "\n\n", &format_single/1)
  end

  defp format_group(mod, violations) do
    header = "  #{inspect(mod)}"
    items = Enum.map_join(violations, "\n", &format_single/1)
    "#{header}\n#{items}"
  end

  defp format_single(%__MODULE__{rule: rule} = v) when is_binary(rule) do
    function =
      case v.caller_function do
        {name, arity} -> "#{inspect(v.module)}.#{name}/#{arity}"
        nil -> inspect(v.module)
      end

    fix = if v.fix, do: "\n      → fix: #{v.fix}", else: ""

    "    ✗ #{format_location(v.file, v.line) || "(no location)"} #{function}\n      #{v.message}#{fix}"
  end

  defp format_single(%__MODULE__{type: :cycle, path: path, message: msg}) when not is_nil(path) do
    arrow_chain = Enum.map_join(path, " → ", &inspect/1)

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
    path_str = Enum.map_join(path, "\n    │    → ", &inspect/1)

    """
        ✗ depends on #{inspect(callee)}  [transitive]
          #{format_location_line(caller, nil)}
          #{msg}
          via: #{path_str}\
    """
  end

  defp format_single(%__MODULE__{caller: caller, callee: callee, message: msg} = v)
       when not is_nil(callee) do
    location = format_location_line(caller, v)
    "    ✗ depends on #{inspect(callee)}#{location}\n      #{msg}"
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

  defp format_location_line(_caller, %{file: file, line: line})
       when is_binary(file) and is_integer(line) do
    " at #{file}:#{line}"
  end

  defp format_location_line(_caller, _violation), do: ""

  defp format_value(nil), do: ""

  defp format_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> strip_elixir_prefix()

  defp format_value(value), do: to_string(value)

  defp format_path(nil), do: nil
  defp format_path(path), do: Enum.map_join(path, " -> ", &format_value/1)

  defp format_function(nil), do: nil
  defp format_function({name, arity}), do: "#{name}/#{arity}"
  defp format_function(value), do: inspect(value)

  defp format_location(nil, _line), do: nil
  defp format_location(_file, nil), do: nil
  defp format_location(file, line), do: "#{file}:#{line}"

  defp normalize_message(message) do
    message
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp strip_elixir_prefix("Elixir." <> rest), do: rest
  defp strip_elixir_prefix(other), do: other
end
