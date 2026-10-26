defmodule ArchTest.Code do
  @moduledoc false
  # A project's compiled Elixir code, read from the `:elixir_v1` debug info of its BEAM files: every function's
  # calls, with the loop each one runs in, and each module's behaviours and source file. Debug info holds the
  # code after macro expansion, with aliases and imports resolved, so `Repo.get!(User, id)` is a call to
  # `MyApp.Repo.get!/2`. Reading starts at the modules a rule checks and follows their calls into the other
  # modules in scope, so a rule reads only the code it can reach.

  alias ArchTest.Code.{Actors, Errors, Signatures, Waits, Walker}
  alias ArchTest.Collector

  defstruct modules: %{}, functions: %{}, scope: MapSet.new()

  # A function another module's macro defined, as `use GenServer` defines default callbacks, is `injected`: its
  # line is the `use`, not code the module's authors wrote.

  # GenServer callbacks whose replies carry the process's next state.
  @callbacks [{:handle_call, 3}, {:handle_cast, 2}, {:handle_info, 2}, {:handle_continue, 2}]

  @type key :: {module(), atom(), arity()}
  @type call :: %{
          target: key(),
          line: pos_integer() | nil,
          loop: String.t() | nil,
          per_item: boolean(),
          receiver: atom() | nil,
          writes_sql: boolean(),
          inside: %{target: key(), line: pos_integer() | nil} | nil
        }
  @type function_info :: %{
          kind: :def | :defp,
          line: pos_integer() | nil,
          calls: [call()],
          state: :kept | :changed | nil,
          injected: boolean(),
          macro: module() | nil,
          runs_funs: boolean(),
          stub: String.t() | nil,
          references: MapSet.t(module()),
          swallows: [Errors.swallow()],
          discards: [{key(), pos_integer() | nil}],
          tails: Errors.tails(),
          dynamic: boolean(),
          actors: Actors.calls(),
          waits: [Waits.wait()],
          signature: Signatures.t()
        }
  @type module_info :: %{
          file: String.t() | nil,
          behaviours: [module()],
          impls: MapSet.t({atom(), arity()}),
          hidden: MapSet.t({atom(), arity()}),
          callbacks: MapSet.t({atom(), arity()}),
          routes: [route()],
          component_values: MapSet.t(String.t())
        }
  @type route :: %{
          controller: module(),
          action: atom(),
          pipe_through: [atom()],
          verb: String.t() | nil,
          on_mount: [module()]
        }
  @type t :: %__MODULE__{
          modules: %{module() => module_info()},
          functions: %{key() => function_info()},
          scope: MapSet.t(module())
        }

  @doc false
  # Reads `modules` and every module in scope their calls reach. The scope is the `:paths`, `:apps` or `:app` in
  # `opts`, or else the ebin directories that hold `modules`.
  @spec load([module()], keyword()) :: t()
  def load(modules, opts) do
    beams = beams_in_scope(modules, opts)

    reach(modules, beams, %__MODULE__{scope: beams |> Map.keys() |> MapSet.new()})
  end

  @doc false
  # Reads every module in scope: the `:paths`, `:apps` or `:app` in `opts`, or else the Mix project running the
  # tests.
  @spec load_scope(keyword()) :: t()
  def load_scope(opts) do
    opts = with_project_app(opts)
    beams = beams_in_scope([], opts)
    modules = beams |> Map.keys() |> Enum.sort()

    reach(modules, beams, %__MODULE__{scope: MapSet.new(modules)})
  end

  @doc false
  # The module's functions, sorted, as `{key, function_info}` pairs.
  @spec functions_of(t(), module()) :: [{key(), function_info()}]
  def functions_of(%__MODULE__{functions: functions}, module) do
    functions
    |> Enum.filter(fn {{owner, _name, _arity}, _info} -> owner == module end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc false
  @spec behaviours(t(), module()) :: [module()]
  def behaviours(%__MODULE__{modules: modules}, module) do
    modules |> Map.get(module, %{behaviours: []}) |> Map.fetch!(:behaviours)
  end

  @doc false
  # The module's source file, relative to the working directory when it lies inside it.
  @spec file(t(), module()) :: String.t() | nil
  def file(%__MODULE__{modules: modules}, module) do
    case modules do
      %{^module => %{file: file}} when is_binary(file) -> Path.relative_to_cwd(file)
      _ -> nil
    end
  end

  defp reach([], _beams, code), do: code

  defp reach([module | rest], beams, code) do
    with false <- Map.has_key?(code.modules, module),
         {:ok, beam} <- Map.fetch(beams, module),
         {:ok, read} <- read(module, beam) do
      reached =
        for {_key, info} <- read.functions, %{target: {target, _, _}} <- info.calls, do: target

      reach(Enum.uniq(reached) ++ rest, beams, add(code, module, read))
    else
      _ -> reach(rest, beams, code)
    end
  end

  defp add(code, module, read) do
    %{
      code
      | modules:
          Map.put(
            code.modules,
            module,
            Map.take(read, [
              :file,
              :behaviours,
              :impls,
              :hidden,
              :callbacks,
              :routes,
              :component_values
            ])
          ),
        functions: Map.merge(code.functions, read.functions)
    }
  end

  defp with_project_app(opts) do
    scoped? =
      Keyword.has_key?(opts, :paths) or Keyword.has_key?(opts, :apps) or
        Keyword.get(opts, :app, :all) != :all

    # Called through a variable, since only projects that `mix test` runs have a Mix project.
    mix_project = Mix.Project

    if scoped? or not Code.ensure_loaded?(mix_project),
      do: opts,
      else: Keyword.put(opts, :app, mix_project.config()[:app])
  end

  defp beams_in_scope(modules, opts) do
    app = Keyword.get(opts, :app, :all)

    directories =
      if app == :all and not Keyword.has_key?(opts, :paths) and not Keyword.has_key?(opts, :apps) do
        modules
        |> Enum.map(&:code.which/1)
        |> Enum.filter(&is_list/1)
        |> Enum.map(&Path.dirname/1)
        |> Enum.uniq()
      else
        Collector.beam_paths(app, opts)
      end

    for directory <- directories, file <- beam_files(directory), into: %{} do
      {file |> Path.basename(".beam") |> String.to_atom(), Path.join(directory, file)}
    end
  end

  defp beam_files(directory) do
    case File.ls(directory) do
      {:ok, files} -> Enum.filter(files, &String.ends_with?(&1, ".beam"))
      {:error, _} -> []
    end
  end

  # Reading a module is cached by the content of its BEAM file, so every rule in a test run reads it once.
  defp read(module, beam) do
    binary = File.read!(beam)
    cache_key = {__MODULE__, module, :erlang.md5(binary)}

    case :persistent_term.get(cache_key, :not_found) do
      :not_found ->
        result = read_binary(module, binary)
        :persistent_term.put(cache_key, result)
        result

      result ->
        result
    end
  end

  defp read_binary(module, binary) do
    with {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(binary, [:debug_info]),
         {:ok, info} <- backend.debug_info(:elixir_v1, module, data, []) do
      {:ok,
       %{
         file: info.file,
         behaviours: behaviours_in(binary),
         impls: MapSet.new(Map.get(info, :impls, []), &elem(&1, 0)),
         hidden: hidden_in(binary),
         callbacks: callbacks_in(binary),
         functions: functions(module, info.definitions, booleans_in(binary)),
         routes: routes_in(info.definitions),
         component_values: component_values_in(info.definitions)
       }}
    else
      _ -> :error
    end
  end

  # The string values a Phoenix component's attributes declare, as `attr :size, :string, values: ~w(small large)`
  # does, from the `__components__/0` that `Phoenix.Component` writes.
  defp component_values_in(definitions) do
    for {{:__components__, 0}, _kind, _meta, clauses} <- definitions,
        {_meta, _args, _guards, body} <- clauses,
        value <- strings_in(body),
        into: MapSet.new(),
        do: value
  end

  defp strings_in(ast) do
    ast
    |> Macro.prewalk([], fn
      value, acc when is_binary(value) -> {value, [value | acc]}
      node, acc -> {node, acc}
    end)
    |> elem(1)
  end

  # A Phoenix router's routes, from the clauses of its `__match_route__/3`: each one's controller or LiveView, action,
  # HTTP verb, the pipelines it goes through, which the router defines as functions of the same names, and a
  # LiveView's `on_mount` hooks.
  defp routes_in(definitions) do
    for {{:__match_route__, 3}, _kind, _meta, clauses} <- definitions,
        {_meta, args, _guards, body} <- clauses,
        verb = Enum.find(args, &is_binary/1),
        route <- route_maps(body),
        do: Map.put(route, :verb, verb)
  end

  defp route_maps(body) do
    body
    |> Macro.prewalk([], fn
      {:%{}, _, pairs} = node, acc when is_list(pairs) -> {node, List.wrap(route(pairs)) ++ acc}
      node, acc -> {node, acc}
    end)
    |> elem(1)
  end

  defp route(pairs) do
    with true <- Keyword.keyword?(pairs),
         controller when is_atom(controller) and controller != nil <- pairs[:plug],
         action when is_atom(action) and action != nil <- pairs[:plug_opts],
         pipelines when is_list(pipelines) <- pairs[:pipe_through] do
      live(
        %{controller: controller, action: action, pipe_through: pipelines, on_mount: []},
        pairs[:phoenix_live_view]
      )
    else
      _ -> nil
    end
  end

  # A LiveView's route: the LiveView, and the modules its live_session's `on_mount` hooks name.
  defp live(route, {:{}, _, [view, _action, _opts, session]}) when is_atom(view) do
    hooks =
      session
      |> Macro.prewalk([], fn
        {:id, {module, _}} = node, acc when is_atom(module) -> {node, [module | acc]}
        node, acc -> {node, acc}
      end)
      |> elem(1)

    %{route | controller: view, on_mount: Enum.reverse(hooks)}
  end

  defp live(route, _metadata), do: route

  # The positions each function's spec types `boolean()`.
  defp booleans_in(binary) do
    case Code.Typespec.fetch_specs(binary) do
      {:ok, specs} -> Map.new(specs, fn {key, types} -> {key, boolean_positions(types)} end)
      :error -> %{}
    end
  end

  defp boolean_positions(types) do
    for {:type, _, :fun, [{:type, _, :product, args}, _result]} <- types,
        {{:type, _, :boolean, []}, position} <- Enum.with_index(args),
        into: MapSet.new(),
        do: position
  end

  # The functions marked `@doc false`, from the Docs chunk the compiler writes.
  defp hidden_in(binary) do
    case :beam_lib.chunks(binary, [~c"Docs"]) do
      {:ok, {_module, [{~c"Docs", docs}]}} ->
        {:docs_v1, _anno, _language, _format, _module_doc, _meta, entries} =
          :erlang.binary_to_term(docs)

        for {{:function, name, arity}, _anno, _signature, :hidden, _meta} <- entries,
            into: MapSet.new(),
            do: {name, arity}

      _ ->
        MapSet.new()
    end
  end

  # The callbacks a behaviour module declares.
  defp callbacks_in(binary) do
    case Code.Typespec.fetch_callbacks(binary) do
      {:ok, callbacks} -> MapSet.new(callbacks, &elem(&1, 0))
      :error -> MapSet.new()
    end
  end

  defp behaviours_in(binary) do
    case :beam_lib.chunks(binary, [:attributes]) do
      {:ok, {_module, [attributes: attributes]}} ->
        for {name, values} <- attributes,
            name in [:behaviour, :behavior],
            value <- values,
            do: value

      _ ->
        []
    end
  end

  defp functions(module, definitions, booleans) do
    defaults =
      for {{name, _arity}, kind, _meta, [{_, _, _, {:super, _, args}}]} <- definitions,
          kind in [:def, :defp] and is_list(args),
          reduce: %{} do
        acc ->
          Map.update(
            acc,
            {name, length(args)},
            Signatures.defaults(args),
            &Map.merge(&1, Signatures.defaults(args))
          )
      end

    locals =
      for {{name, arity}, kind, _meta, _clauses} <- definitions,
          kind in [:def, :defp],
          into: MapSet.new(),
          do: {name, arity}

    sql_writers =
      for {{name, arity}, kind, _meta, clauses} <- definitions,
          kind in [:def, :defp] and Walker.sql_writer?(clauses),
          into: MapSet.new(),
          do: {name, arity}

    for {{name, arity}, kind, meta, clauses} <- definitions, kind in [:def, :defp], into: %{} do
      state = if {name, arity} in @callbacks, do: Walker.state(clauses)

      {{module, name, arity},
       %{
         kind: kind,
         line: meta[:line],
         calls: Walker.calls(clauses, module, locals, sql_writers),
         state: state,
         injected: Keyword.has_key?(meta, :context),
         macro: meta[:context],
         runs_funs: Errors.runs_funs?(clauses),
         stub: Walker.stub(clauses),
         references: Walker.references(clauses),
         swallows: Errors.swallows(clauses, module, locals),
         discards: Errors.discards(clauses, module, locals),
         tails: Errors.tails(clauses, module, locals),
         dynamic: Errors.dynamic?(clauses),
         actors: Actors.calls(clauses, module, locals),
         waits: Waits.unbounded(clauses, module, name, arity, locals),
         signature:
           Signatures.of(
             clauses,
             Map.get(booleans, {name, arity}, MapSet.new()),
             Map.get(defaults, {name, arity}, %{})
           )
       }}
    end
  end
end
