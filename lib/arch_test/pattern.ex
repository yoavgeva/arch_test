defmodule ArchTest.Pattern do
  @moduledoc """
  Glob pattern matching for Elixir module names.

  Module names are treated as dot-separated segments, and glob patterns
  follow these semantics:

  | Pattern | Matches |
  |---------|---------|
  | `"MyApp.Orders.*"` | Direct children only (`MyApp.Orders.Order`) |
  | `"MyApp.Orders.**"` | All descendants at any depth |
  | `"MyApp.Orders"` | Exact match only |
  | `"**.*Service"` | Any module whose last segment ends with `Service` |
  | `"**.*Service*"` | Any module whose last segment contains `Service` |
  | `"MyApp.**.*Repo"` | Under `MyApp`, last segment ends with `Repo` |
  | `"**"` | All modules |
  """

  @doc """
  Compiles a glob pattern string into a `Regex`.

  `**` matches one or more dot-separated segments (any depth).
  `*` within a single segment matches any characters except `.`.
  """
  @spec compile(String.t()) :: Regex.t()
  def compile(pattern) do
    segments = String.split(pattern, ".")
    # A pattern with an empty non-sole segment (e.g. trailing dot "MyApp." or
    # leading dot ".Foo") can never match a valid module name. Detect this by
    # checking whether any segment is empty when there is more than one segment.
    has_empty_segment = length(segments) > 1 and Enum.any?(segments, &(&1 == ""))

    if has_empty_segment do
      # "(?!)" is a never-matching pattern
      Regex.compile!("(?!)")
    else
      regex_str = segments |> segments_to_regex()
      Regex.compile!("^#{regex_str}$")
    end
  end

  @doc """
  Returns `true` if `module_name` matches `pattern`.

  Accepts either a pattern string or a pre-compiled `Regex`.

  ## Examples

      iex> ArchTest.Pattern.matches?("MyApp.Orders.*", "MyApp.Orders.Order")
      true

      iex> ArchTest.Pattern.matches?("MyApp.Orders.*", "MyApp.Orders.Schemas.Order")
      false

      iex> ArchTest.Pattern.matches?("MyApp.Orders.**", "MyApp.Orders.Schemas.Order")
      true

      iex> ArchTest.Pattern.matches?("**.*Service", "MyApp.Orders.OrderService")
      true

      iex> ArchTest.Pattern.matches?("**.*Service", "MyApp.Orders.OrderServiceHelper")
      false
  """
  @spec matches?(String.t() | Regex.t(), String.t() | module()) :: boolean()
  def matches?(pattern, module_name) when is_binary(pattern) do
    regex = compile(pattern)
    matches?(regex, module_name)
  end

  def matches?(%Regex{} = regex, module_name) when is_atom(module_name) do
    matches?(regex, module_to_string(module_name))
  end

  def matches?(%Regex{} = regex, module_name) when is_binary(module_name) do
    Regex.match?(regex, module_name)
  end

  @doc """
  Filters a list of modules/module name strings to those matching `pattern`.
  """
  @spec filter([module() | String.t()], String.t()) :: [module() | String.t()]
  def filter(modules, pattern) do
    regex = compile(pattern)
    Enum.filter(modules, &matches?(regex, &1))
  end

  @doc """
  Converts a module atom to its string representation without the `Elixir.` prefix.
  """
  @spec module_to_string(module()) :: String.t()
  def module_to_string(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> strip_elixir_prefix()
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp strip_elixir_prefix("Elixir." <> rest), do: rest
  defp strip_elixir_prefix(str), do: str

  # Convert a list of dot-split segments to a regex string.
  #
  # Rules for `**`:
  #   - Sole segment ("**"):       matches any non-empty module name
  #   - At start ("**", more...):  matches zero or more "segment." prefixes,
  #                                 followed immediately by the next segment
  #   - At end  (..., "**"):        matches "." + one or more "."-joined segments
  #   - In middle (..., "**", ...): matches zero or more additional ".segment" chunks,
  #                                 followed by "." + the next segment
  #
  # The key insight: "**" in the middle/end always requires at least ONE segment
  # (because it means "one or more"). "**" at the START can match zero segments
  # (meaning the module name starts right at the next segment pattern).
  defp segments_to_regex(segments) do
    total = length(segments)

    segments
    |> Enum.with_index()
    |> Enum.reduce({[], :after_normal}, fn {seg, idx}, {parts, mode} ->
      reduce_segment(seg, idx, idx == total - 1, parts, mode)
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  # Sole ** (only segment)
  defp reduce_segment("**", 0, true, parts, :after_normal),
    do: {["[^.]+(\\.[^.]+)*" | parts], :after_double_star}

  # ** at start, more segments follow
  defp reduce_segment("**", 0, false, parts, :after_normal),
    do: {["(?:[^.]+\\.)*" | parts], :after_double_star}

  # ** at end after a normal segment
  defp reduce_segment("**", _idx, true, parts, :after_normal),
    do: {["\\.(?:[^.]+\\.)*[^.]+" | parts], :after_double_star}

  # ** in middle after a normal segment
  defp reduce_segment("**", _idx, false, parts, :after_normal),
    do: {["\\.(?:[^.]+\\.)*" | parts], :after_double_star}

  # ** at end after a previous **
  defp reduce_segment("**", _idx, true, parts, :after_double_star),
    do: {["[^.]+" | parts], :after_double_star}

  # ** in middle after a previous ** — collapse
  defp reduce_segment("**", _idx, false, parts, :after_double_star),
    do: {parts, :after_double_star}

  # Normal segment at start
  defp reduce_segment(seg, 0, _last, parts, :after_normal),
    do: {[segment_to_regex(seg) | parts], :after_normal}

  # Normal segment after **
  defp reduce_segment(seg, _idx, _last, parts, :after_double_star),
    do: {[segment_to_regex(seg) | parts], :after_normal}

  # Normal segment after normal segment
  defp reduce_segment(seg, _idx, _last, parts, :after_normal),
    do: {[segment_to_regex(seg), "\\." | parts], :after_normal}

  # Converts a single (non-`**`) segment to a regex fragment.
  defp segment_to_regex(seg) do
    seg
    |> Regex.escape()
    |> String.replace("\\*", "[^.]*")
  end
end
