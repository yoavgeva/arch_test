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
      is_last = idx == total - 1

      case {seg, mode, is_last} do
        # Sole segment is **
        {"**", :after_normal, true} when idx == 0 ->
          {["[^.]+(\\.[^.]+)*" | parts], :after_double_star}

        # ** at start (first segment, more to follow)
        {"**", :after_normal, false} when idx == 0 ->
          # Match zero or more "segment." prefixes.
          # Since the NEXT segment will NOT add a leading dot (we set mode),
          # the "(?:[^.]+\.)*" already handles the separator.
          {["(?:[^.]+\\.)*" | parts], :after_double_star}

        # ** at end (after normal segment)
        {"**", :after_normal, true} ->
          # Must match at least 1 more segment: "." + segment + optional more
          {["\\.(?:[^.]+\\.)*[^.]+" | parts], :after_double_star}

        # ** in middle (after normal segment)
        {"**", :after_normal, false} ->
          # Emit: "." separator + then zero-or-more "segment." groups.
          # The trailing dot of the last group flows into the next segment directly.
          # Result: "\.(?:[^.]+\.)*" — mandatory leading dot, zero or more trailing groups.
          {["\\.(?:[^.]+\\.)*" | parts], :after_double_star}

        # ** at end after a previous **
        {"**", :after_double_star, true} ->
          # Consecutive ** at end: current regex already has zero-or-more "seg." groups.
          # We need to ensure at least one complete segment is matched.
          # Replace the trailing \.(?:[^.]+\.)* with \.(?:[^.]+\.)*[^.]+
          # by emitting the missing final non-dot-containing segment.
          {["[^.]+" | parts], :after_double_star}

        # ** in middle after a previous **
        {"**", :after_double_star, false} ->
          # Two consecutive ** in middle collapse — no extra emission needed
          {parts, :after_double_star}

        # Normal segment at start (no dot prefix)
        {seg, :after_normal, _} when idx == 0 ->
          {[segment_to_regex(seg) | parts], :after_normal}

        # Normal segment after ** at start: ** emitted "(?:[^.]+\.)*"
        # which already includes the optional trailing dot, so no extra dot needed.
        # BUT: the regex "(?:[^.]+\.)*" matches "A." "A.B." etc., and we need
        # the next segment to follow directly. The "?" already handles zero matches.
        # So: no extra dot for the first segment after a leading **.
        {seg, :after_double_star, _} ->
          {[segment_to_regex(seg) | parts], :after_normal}

        # Normal segment after normal segment: add dot separator
        {seg, :after_normal, _} ->
          {[segment_to_regex(seg), "\\." | parts], :after_normal}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  # Converts a single (non-`**`) segment to a regex fragment.
  defp segment_to_regex(seg) do
    seg
    |> Regex.escape()
    |> String.replace("\\*", "[^.]*")
  end
end
