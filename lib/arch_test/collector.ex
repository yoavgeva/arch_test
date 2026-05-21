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
  @call_cache_key {__MODULE__, :calls}

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
    build_graph_from_paths([ebin_path], opts)
  end

  @doc """
  Builds a dependency graph from one or more BEAM directory paths.

  Options:
  - `:force` — bypass cache
  - `:include` — list of module glob patterns to keep
  - `:exclude` — list of module glob patterns to remove
  """
  @spec build_graph_from_paths(String.t() | [String.t()], keyword()) :: graph()
  def build_graph_from_paths(paths, opts \\ []) do
    beam_paths = List.wrap(paths)
    cache_key = {@cache_key, {:paths, beam_paths}, cache_opts(opts)}
    force = Keyword.get(opts, :force, false)

    if force do
      graph = beam_paths |> do_build_graph_from_paths() |> filter_graph(opts)
      :persistent_term.put(cache_key, graph)
      graph
    else
      case :persistent_term.get(cache_key, :not_found) do
        :not_found ->
          graph = beam_paths |> do_build_graph_from_paths() |> filter_graph(opts)
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
  - `:apps` — list of OTP apps to inspect together
  - `:paths` — BEAM ebin path or paths to inspect instead of an app
  - `:include` — list of module glob patterns to keep
  - `:exclude` — list of module glob patterns to remove
  - `:force` — boolean, bypass cache (default `false`)
  """
  @spec build_graph(atom() | :all, keyword()) :: graph()
  def build_graph(app \\ :all, opts \\ []) do
    cache_key = {@cache_key, app, cache_opts(opts)}
    force = Keyword.get(opts, :force, false)

    if force do
      build_and_cache(app, opts, cache_key)
    else
      case :persistent_term.get(cache_key, :not_found) do
        :not_found -> build_and_cache(app, opts, cache_key)
        graph -> graph
      end
    end
  end

  @doc """
  Returns function-level call metadata for the given OTP application.

  Requires BEAM files compiled with debug info. Missing debug info yields an
  empty call list for that module rather than an exception.

  Accepts the same scope and filter options as `build_graph/2`: `:apps`,
  `:paths`, `:include`, `:exclude`, and `:force`. Compiler-generated metadata
  calls are omitted. Remote captures and static `apply/3` calls are reported
  when debug information exposes them.
  """
  @spec calls(atom() | :all, keyword()) :: [ArchTest.Call.t()]
  def calls(app \\ :all, opts \\ []) do
    beam_paths = beam_paths_for_scope(app, opts)
    calls_from_paths(beam_paths, opts)
  end

  @doc """
  Returns function-level call metadata from a BEAM directory path.
  """
  @spec calls_from_path(String.t(), keyword()) :: [ArchTest.Call.t()]
  def calls_from_path(path, opts \\ []) do
    calls_from_paths([path], opts)
  end

  @doc """
  Returns function-level call metadata from one or more BEAM directory paths.

  Options:
  - `:force` — bypass cache
  - `:include` — list of caller/callee module glob patterns to keep
  - `:exclude` — list of caller/callee module glob patterns to remove
  """
  @spec calls_from_paths(String.t() | [String.t()], keyword()) :: [ArchTest.Call.t()]
  def calls_from_paths(paths, opts \\ []) do
    beam_paths = List.wrap(paths)
    cache_key = {@call_cache_key, {:paths, beam_paths}, cache_opts(opts)}
    force = Keyword.get(opts, :force, false)

    if force do
      calls = beam_paths |> do_calls_from_paths() |> filter_calls(opts)
      :persistent_term.put(cache_key, calls)
      calls
    else
      case :persistent_term.get(cache_key, :not_found) do
        :not_found ->
          calls = beam_paths |> do_calls_from_paths() |> filter_calls(opts)
          :persistent_term.put(cache_key, calls)
          calls

        calls ->
          calls
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

  defp build_and_cache(app, opts, cache_key) do
    graph = do_build_graph(app, opts)
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

  defp do_build_graph(app, opts) do
    app
    |> beam_paths_for_scope(opts)
    |> do_build_graph_from_paths()
    |> filter_graph(opts)
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

  defp beam_paths_for_scope(app, opts) do
    cond do
      paths = Keyword.get(opts, :paths) ->
        List.wrap(paths)

      apps = Keyword.get(opts, :apps) ->
        apps |> List.wrap() |> Enum.flat_map(&beam_paths_for/1)

      true ->
        beam_paths_for(app)
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

  defp cache_opts(opts) do
    opts
    |> Keyword.take([:apps, :paths, :include, :exclude])
    |> Enum.sort()
  end

  defp filter_graph(graph, opts) do
    include_patterns = List.wrap(Keyword.get(opts, :include, ["**"]))
    exclude_patterns = List.wrap(Keyword.get(opts, :exclude, []))

    kept_modules =
      graph
      |> Map.keys()
      |> Enum.filter(&module_allowed?(&1, include_patterns, exclude_patterns))
      |> MapSet.new()

    graph
    |> Enum.filter(fn {mod, _deps} -> MapSet.member?(kept_modules, mod) end)
    |> Enum.map(fn {mod, deps} ->
      {mod, Enum.filter(deps, &MapSet.member?(kept_modules, &1))}
    end)
    |> Map.new()
  end

  defp filter_calls(calls, opts) do
    include_patterns = List.wrap(Keyword.get(opts, :include, ["**"]))
    exclude_patterns = List.wrap(Keyword.get(opts, :exclude, []))

    Enum.filter(calls, fn call ->
      module_allowed?(call.caller_module, include_patterns, exclude_patterns) and
        module_allowed?(call.callee_module, include_patterns, exclude_patterns)
    end)
  end

  defp module_allowed?(mod, include_patterns, exclude_patterns) do
    mod_str = ArchTest.Pattern.module_to_string(mod)

    Enum.any?(include_patterns, &ArchTest.Pattern.matches?(&1, mod_str)) and
      not Enum.any?(exclude_patterns, &ArchTest.Pattern.matches?(&1, mod_str))
  end

  defp do_calls_from_paths(beam_paths) do
    beam_paths
    |> Enum.flat_map(&beam_files_from_path/1)
    |> Enum.flat_map(&calls_from_beam_file/1)
  end

  defp beam_files_from_path(path) do
    case File.ls(path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".beam"))
        |> Enum.map(&Path.join(path, &1))

      {:error, _} ->
        []
    end
  end

  defp calls_from_beam_file(beam_file) do
    module =
      beam_file
      |> Path.basename(".beam")
      |> String.to_atom()
      |> normalize_module()

    forms = abstract_forms(beam_file, module)
    source = compile_source(beam_file)

    forms
    |> Enum.flat_map(fn
      {:function, _anno, fun, arity, body} ->
        if generated_function?(fun, arity) do
          []
        else
          extract_remote_calls(body, %{
            module: module,
            function: fun,
            arity: arity,
            file: source
          })
        end

      _ ->
        []
    end)
  end

  defp abstract_forms(beam_file, module) do
    beam_chars = String.to_charlist(beam_file)

    case :beam_lib.chunks(beam_chars, [:abstract_code]) do
      {:ok, {_, [{:abstract_code, {_, forms}}]}} -> forms
      _ -> debug_info_forms(beam_chars, module)
    end
  end

  defp debug_info_forms(beam_chars, module) do
    case :beam_lib.chunks(beam_chars, [:debug_info]) do
      {:ok, {_, [{:debug_info, {:debug_info_v1, backend, data}}]}} ->
        case backend.debug_info(:erlang_v1, module, data, []) do
          {:ok, forms} -> forms
          _ -> []
        end

      _ ->
        []
    end
  end

  defp compile_source(beam_file) do
    case :beam_lib.chunks(String.to_charlist(beam_file), [:compile_info]) do
      {:ok, {_, [{:compile_info, info}]}} ->
        info
        |> Keyword.get(:source)
        |> case do
          nil -> nil
          source when is_list(source) -> List.to_string(source)
          source when is_binary(source) -> source
        end

      _ ->
        nil
    end
  end

  defp extract_remote_calls(term, caller) do
    do_extract_remote_calls(term, caller, [])
  end

  defp do_extract_remote_calls({:call, anno, {:atom, _, :apply}, args} = term, caller, acc) do
    line = line_from_anno(anno)

    acc =
      case static_apply_target(args) do
        {:ok, callee_module, callee_fun, callee_arity} ->
          add_call(acc, caller, callee_module, callee_fun, callee_arity, line, :static_apply)

        :error ->
          acc
      end

    term
    |> Tuple.to_list()
    |> Enum.reduce(acc, &do_extract_remote_calls(&1, caller, &2))
  end

  defp do_extract_remote_calls(
         {:call, anno, {:remote, _, module_ast, fun_ast}, args} = term,
         caller,
         acc
       ) do
    line = line_from_anno(anno)

    acc =
      case {static_atom(module_ast), static_atom(fun_ast)} do
        {{:ok, :erlang}, {:ok, :apply}} ->
          case static_apply_target(args) do
            {:ok, callee_module, callee_fun, callee_arity} ->
              add_call(acc, caller, callee_module, callee_fun, callee_arity, line, :static_apply)

            :error ->
              add_call(acc, caller, :erlang, :apply, length(args), line, :remote_call)
          end

        {{:ok, callee_module}, {:ok, callee_fun}} ->
          add_call(acc, caller, callee_module, callee_fun, length(args), line, :remote_call)

        _ ->
          acc
      end

    term
    |> Tuple.to_list()
    |> Enum.reduce(acc, &do_extract_remote_calls(&1, caller, &2))
  end

  defp do_extract_remote_calls(
         {:fun, anno, {:function, module_ast, fun_ast, arity_ast}} = term,
         caller,
         acc
       ) do
    line = line_from_anno(anno)

    acc =
      with {:ok, callee_module} <- static_atom(module_ast),
           {:ok, callee_fun} <- static_atom(fun_ast),
           {:ok, callee_arity} <- static_integer(arity_ast) do
        add_call(acc, caller, callee_module, callee_fun, callee_arity, line, :remote_capture)
      else
        _ -> acc
      end

    term
    |> Tuple.to_list()
    |> Enum.reduce(acc, &do_extract_remote_calls(&1, caller, &2))
  end

  defp do_extract_remote_calls(tuple, caller, acc) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(acc, &do_extract_remote_calls(&1, caller, &2))
  end

  defp do_extract_remote_calls(list, caller, acc) when is_list(list) do
    Enum.reduce(list, acc, &do_extract_remote_calls(&1, caller, &2))
  end

  defp do_extract_remote_calls(_other, _caller, acc), do: acc

  defp add_call(acc, caller, callee_module, callee_fun, callee_arity, line, kind) do
    if generated_call?(callee_module, callee_fun, line) do
      acc
    else
      [
        %ArchTest.Call{
          caller_module: caller.module,
          caller_function: caller.function,
          caller_arity: caller.arity,
          callee_module: normalize_module(callee_module),
          callee_function: callee_fun,
          callee_arity: callee_arity,
          file: caller.file,
          line: line,
          kind: kind
        }
        | acc
      ]
    end
  end

  defp static_apply_target([module_ast, fun_ast, args_ast]) do
    with {:ok, callee_module} <- static_atom(module_ast),
         {:ok, callee_fun} <- static_atom(fun_ast),
         {:ok, callee_arity} <- static_list_length(args_ast) do
      {:ok, callee_module, callee_fun, callee_arity}
    else
      _ -> :error
    end
  end

  defp static_apply_target(_args), do: :error

  defp static_list_length(args) when is_list(args), do: {:ok, length(args)}

  defp static_list_length({:cons, _anno, _head, tail}) do
    case static_list_length(tail) do
      {:ok, length} -> {:ok, length + 1}
      :error -> :error
    end
  end

  defp static_list_length({nil, _anno}), do: {:ok, 0}
  defp static_list_length(_args), do: :error

  defp static_atom(atom) when is_atom(atom), do: {:ok, atom}
  defp static_atom({:atom, _anno, atom}) when is_atom(atom), do: {:ok, atom}
  defp static_atom(_), do: :error

  defp static_integer(int) when is_integer(int), do: {:ok, int}
  defp static_integer({:integer, _anno, int}) when is_integer(int), do: {:ok, int}
  defp static_integer(_), do: :error

  defp generated_function?(:__info__, 1), do: true
  defp generated_function?(:module_info, 0), do: true
  defp generated_function?(:module_info, 1), do: true
  defp generated_function?(:impl_for, 1), do: true
  defp generated_function?(:impl_for!, 1), do: true
  defp generated_function?(:__impl__, 1), do: true
  defp generated_function?(:__protocol__, 1), do: true
  defp generated_function?(_fun, _arity), do: false

  defp generated_call?(_mod, _fun, line) when not is_integer(line) or line <= 0, do: true
  defp generated_call?(:erlang, :get_module_info, _line), do: true

  defp generated_call?(:erlang, fun, _line),
    do: fun |> Atom.to_string() |> String.starts_with?("is_")

  defp generated_call?(:elixir_erl_pass, :no_parens_remote, _line), do: true
  defp generated_call?(_mod, _fun, _line), do: false

  defp line_from_anno(anno) when is_integer(anno), do: anno

  defp line_from_anno(anno) do
    :erl_anno.line(anno)
  rescue
    _ -> nil
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
