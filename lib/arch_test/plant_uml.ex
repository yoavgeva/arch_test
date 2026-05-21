defmodule ArchTest.PlantUML do
  @moduledoc """
  Minimal PlantUML component conformance checks.

  The checker reads component edges such as `[Orders] --> [Accounts]` and
  verifies that actual slice-level dependencies do not exceed the diagram. Line
  comments (`'` and `//`) and PlantUML block comments (`/' ... '/`) are ignored.
  """

  alias ArchTest.{Assertions, Collector, Violation}

  @doc """
  Enforces that actual slice dependencies are present in a PlantUML diagram.

  Options:
  - `:slices` — required keyword list, e.g. `[orders: "MyApp.Orders"]`
  - `:graph` — pre-built graph
  - `:app` — OTP app to inspect when `:graph` is not provided
  """
  @spec enforce(String.t(), keyword()) :: :ok
  def enforce(path, opts) do
    slices = Keyword.fetch!(opts, :slices)

    graph =
      Keyword.get(opts, :graph) || Collector.build_graph(Keyword.get(opts, :app, :all), opts)

    allowed = parse_edges(path)
    actual = actual_slice_dependencies(slices, graph)

    violations =
      actual
      |> Enum.reject(fn {from, to, _caller, _callee} -> MapSet.member?(allowed, {from, to}) end)
      |> Enum.map(fn {from, to, caller, callee} ->
        Violation.forbidden_dep(
          caller,
          callee,
          "plantuml: slice :#{from} depends on :#{to}, but #{Path.basename(path)} " <>
            "does not contain `[#{label(from)}] --> [#{label(to)}]`"
        )
      end)

    Assertions.assert_no_violations_public(violations, "plantuml — enforce")
  end

  @doc """
  Parses allowed component edges from a PlantUML file.
  """
  @spec parse_edges(String.t()) :: MapSet.t({atom(), atom()})
  def parse_edges(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {edges, in_block_comment?} ->
      {line_edges, next_in_block_comment?} = parse_line(line, in_block_comment?)
      {edges ++ line_edges, next_in_block_comment?}
    end)
    |> elem(0)
    |> MapSet.new()
  end

  defp parse_line(line, true) do
    trimmed = String.trim_leading(line)
    {[], not String.contains?(trimmed, "'/")}
  end

  defp parse_line(line, false) do
    trimmed = String.trim_leading(line)

    cond do
      String.starts_with?(trimmed, ["'", "//"]) ->
        {[], false}

      String.starts_with?(trimmed, "/'") ->
        {[], not String.contains?(trimmed, "'/")}

      true ->
        {parse_edge_line(line), false}
    end
  end

  defp parse_edge_line(line) do
    case Regex.run(~r/\[([^\]]+)\]\s*-+>\s*\[([^\]]+)\]/, line) do
      [_whole, from, to] -> [{component_name(from), component_name(to)}]
      _ -> []
    end
  end

  defp actual_slice_dependencies(slices, graph) do
    slice_info =
      Enum.map(slices, fn {name, root} ->
        {name, root, slice_modules(root, graph)}
      end)

    for {from, _root, mods} <- slice_info,
        caller <- mods,
        callee <- Collector.dependencies_of(graph, caller),
        {to, _to_root, to_mods} <- slice_info,
        from != to,
        callee in to_mods do
      {from, to, caller, callee}
    end
    |> Enum.uniq_by(fn {from, to, _caller, _callee} -> {from, to} end)
  end

  defp slice_modules(root, graph) do
    child_pattern = "#{root}.**"

    graph
    |> Map.keys()
    |> Enum.filter(fn mod ->
      mod_str = ArchTest.Pattern.module_to_string(mod)

      ArchTest.Pattern.matches?(root, mod_str) or
        ArchTest.Pattern.matches?(child_pattern, mod_str)
    end)
  end

  defp component_name(name) do
    name
    |> String.trim()
    |> Macro.underscore()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.to_atom()
  end

  defp label(atom) do
    atom
    |> Atom.to_string()
    |> Macro.camelize()
  end
end
