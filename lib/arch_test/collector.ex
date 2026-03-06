defmodule ArchTest.Collector do
  @moduledoc """
  Builds a module dependency graph using OTP's `:xref` tool.

  The graph is a map of `%{caller_module => [callee_module]}` derived from
  BEAM files. Results are cached in `:persistent_term` for the duration of
  the test run.

  No external dependencies are required — `:xref` and `:beam_lib` are
  standard OTP applications.
  """

  require Logger

  @cache_key {__MODULE__, :graph}

  @type graph :: %{module() => [module()]}

  @doc """
  Builds a dependency graph from a specific BEAM directory path.

  Useful for testing against a pre-compiled application without registering
  it as an OTP application.

  ## Options
  - `:force` — boolean, bypass cache (default `false`)

  ## Example

      ebin = "test/support/fixture_app/_build/dev/lib/fixture_app/ebin"
      graph = ArchTest.Collector.build_graph_from_path(ebin)
  """
  @spec build_graph_from_path(String.t(), keyword()) :: graph()
  def build_graph_from_path(ebin_path, opts \\ []) do
    cache_key = {@cache_key, {:path, ebin_path}}
    force = Keyword.get(opts, :force, false)

    if force do
      graph = do_build_graph_from_paths([ebin_path])
      :persistent_term.put(cache_key, graph)
      graph
    else
      case :persistent_term.get(cache_key, :not_found) do
        :not_found ->
          graph = do_build_graph_from_paths([ebin_path])
          :persistent_term.put(cache_key, graph)
          graph

        graph ->
          graph
      end
    end
  end

  @doc """
  Returns the dependency graph for the given OTP application (or all loaded
  modules if `app` is `:all`).

  The graph is cached in `:persistent_term` after the first call.
  Pass `force: true` to bypass the cache and rebuild.

  ## Options
  - `:app` — OTP app atom or `:all` (default `:all`)
  - `:force` — boolean, bypass cache (default `false`)
  """
  @spec build_graph(atom() | :all, keyword()) :: graph()
  def build_graph(app \\ :all, opts \\ []) do
    cache_key = {@cache_key, app}
    force = Keyword.get(opts, :force, false)

    if force do
      build_and_cache(app, cache_key)
    else
      case :persistent_term.get(cache_key, :not_found) do
        :not_found -> build_and_cache(app, cache_key)
        graph -> graph
      end
    end
  end

  @doc """
  Returns all modules known in the graph.
  """
  @spec all_modules(graph()) :: [module()]
  def all_modules(graph), do: Map.keys(graph)

  @doc """
  Returns the direct dependencies of `module` (modules it calls).
  """
  @spec dependencies_of(graph(), module()) :: [module()]
  def dependencies_of(graph, module), do: Map.get(graph, module, [])

  @doc """
  Returns all modules that directly depend on `module` (callers of it).
  """
  @spec dependents_of(graph(), module()) :: [module()]
  def dependents_of(graph, target) do
    graph
    |> Enum.filter(fn {_caller, callees} -> target in callees end)
    |> Enum.map(fn {caller, _} -> caller end)
  end

  @doc """
  Returns all dependency cycles found in the given modules.

  Each cycle is a list of modules forming a circular dependency chain.
  """
  @spec cycles(graph()) :: [[module()]]
  def cycles(graph) do
    find_cycles(graph)
  end

  @doc """
  Computes transitive dependencies of `module` up to `max_depth` hops
  (default: unlimited).
  """
  @spec transitive_dependencies_of(graph(), module(), pos_integer() | :infinity) :: [module()]
  def transitive_dependencies_of(graph, module, max_depth \\ :infinity) do
    do_transitive(graph, [module], MapSet.new([module]), max_depth, 0)
    |> MapSet.delete(module)
    |> MapSet.to_list()
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp build_and_cache(app, cache_key) do
    graph = do_build_graph(app)
    :persistent_term.put(cache_key, graph)
    graph
  end

  defp do_build_graph_from_paths(beam_paths) do
    {:ok, xref} = :xref.start([{:verbose, false}, {:warnings, false}])

    try do
      Enum.each(beam_paths, fn path ->
        :xref.add_directory(xref, String.to_charlist(path))
      end)

      {:ok, edges} = :xref.q(xref, ~c"(Mod) E")

      edges
      |> Enum.reduce(%{}, fn {caller, callee}, acc ->
        caller_mod = beam_module_to_atom(caller)
        callee_mod = beam_module_to_atom(callee)

        if caller_mod == callee_mod do
          acc
        else
          Map.update(acc, caller_mod, [callee_mod], fn deps ->
            if callee_mod in deps, do: deps, else: [callee_mod | deps]
          end)
        end
      end)
      |> ensure_all_modules_present(beam_paths)
    after
      :xref.stop(xref)
    end
  end

  defp do_build_graph(app) do
    beam_paths_for(app) |> do_build_graph_from_paths()
  end

  # Make sure every module in the app appears as a key, even if it has no deps
  defp ensure_all_modules_present(graph, beam_paths) do
    all_mods = all_modules_from_beam(beam_paths)

    Enum.reduce(all_mods, graph, fn mod, acc ->
      Map.put_new(acc, mod, [])
    end)
  end

  defp all_modules_from_beam(beam_paths) do
    Enum.flat_map(beam_paths, &modules_from_beam_path/1)
  end

  defp modules_from_beam_path(path) do
    case File.ls(path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".beam"))
        |> Enum.map(fn file ->
          file |> String.replace_suffix(".beam", "") |> String.to_atom()
        end)
        |> Enum.map(&normalize_module/1)

      {:error, _} ->
        []
    end
  end

  defp beam_paths_for(:all) do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&File.dir?/1)
  end

  defp beam_paths_for(app) when is_atom(app) do
    case :code.lib_dir(app) do
      {:error, :bad_name} ->
        # Try to find it via application path (may raise ArgumentError)
        try do
          path = Application.app_dir(app, "ebin")
          if File.dir?(path), do: [path], else: []
        rescue
          ArgumentError -> []
        end

      path ->
        ebin = Path.join(List.to_string(path), "ebin")
        if File.dir?(ebin), do: [ebin], else: []
    end
  end

  defp beam_module_to_atom(mod) when is_atom(mod), do: normalize_module(mod)

  defp normalize_module(mod) when is_atom(mod) do
    str = Atom.to_string(mod)

    # xref returns modules as plain atoms without Elixir. prefix for Erlang,
    # but Elixir modules already have the Elixir. prefix when stored in BEAM
    if String.starts_with?(str, "Elixir.") do
      mod
    else
      # Erlang module — keep as-is
      mod
    end
  end

  # BFS-based transitive dependency traversal where `depth` counts hops
  # (levels), not individual dequeues. We process all nodes at the current
  # level before advancing depth, which matches the expected semantics of
  # max_depth (e.g. max_depth=1 returns only direct dependencies).
  defp do_transitive(_graph, [], visited, _max_depth, _depth), do: visited

  defp do_transitive(_graph, _queue, visited, max_depth, depth) when depth >= max_depth,
    do: visited

  defp do_transitive(graph, current_level, visited, max_depth, depth) do
    # Expand all nodes at the current level to find the next level
    next_level =
      current_level
      |> Enum.flat_map(&Map.get(graph, &1, []))
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.uniq()

    new_visited = Enum.reduce(next_level, visited, &MapSet.put(&2, &1))

    do_transitive(graph, next_level, new_visited, max_depth, depth + 1)
  end

  defp find_cycles(graph) do
    modules = Map.keys(graph)

    {cycles, _} =
      Enum.reduce(modules, {[], MapSet.new()}, fn mod, {found, visited} ->
        if MapSet.member?(visited, mod) do
          {found, visited}
        else
          {new_cycles, new_visited} = dfs_cycles(graph, mod, [], MapSet.new(), visited)
          {found ++ new_cycles, MapSet.union(visited, new_visited)}
        end
      end)

    cycles
    |> Enum.map(&normalize_cycle/1)
    |> Enum.uniq()
  end

  defp dfs_cycles(graph, node, path, on_stack, global_visited) do
    if MapSet.member?(on_stack, node) do
      # Found a cycle — extract it
      cycle_start = Enum.find_index(path, &(&1 == node))

      if cycle_start do
        cycle = Enum.drop(path, cycle_start) ++ [node]
        {[cycle], global_visited}
      else
        {[], global_visited}
      end
    else
      dfs_unvisited(graph, node, path, on_stack, global_visited)
    end
  end

  defp dfs_unvisited(graph, node, path, on_stack, global_visited) do
    if MapSet.member?(global_visited, node) do
      {[], global_visited}
    else
      new_path = path ++ [node]
      new_on_stack = MapSet.put(on_stack, node)
      deps = Map.get(graph, node, [])

      {cycles, visited} =
        Enum.reduce(deps, {[], global_visited}, fn dep, {found, vis} ->
          {new_found, new_vis} = dfs_cycles(graph, dep, new_path, new_on_stack, vis)
          {found ++ new_found, new_vis}
        end)

      {cycles, MapSet.put(visited, node)}
    end
  end

  # Normalizes a cycle to a canonical form for deduplication.
  # Cycles from dfs_cycles/5 have the form [A, B, ..., A] — the start node
  # is repeated at the end. We strip the trailing duplicate, then rotate so
  # the lexicographically smallest element comes first.
  defp normalize_cycle(cycle) do
    # Drop the trailing repeat of the first node (if present)
    nodes =
      case cycle do
        [first | _] = c when length(c) > 1 ->
          if List.last(c) == first, do: Enum.drop(c, -1), else: c

        c ->
          c
      end

    min = Enum.min(nodes)
    idx = Enum.find_index(nodes, &(&1 == min))
    {head, tail} = Enum.split(nodes, idx)
    tail ++ head
  end
end
