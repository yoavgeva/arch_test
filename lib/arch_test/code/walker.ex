defmodule ArchTest.Code.Walker do
  @moduledoc false
  # Finds the calls in a function's expanded code, and the loop each one runs in: a function given to `Enum`,
  # `Stream` or `Task.async_stream`, or the body of a `for`. A call in a loop runs once per item when its arguments
  # use the item, or a variable bound from it. A function captured into a loop, as in
  # `Enum.map(ids, &Accounts.get_user!/1)`, runs once per item too.

  # Stream functions whose function runs once per step they make up, such as a page of results, not per item.
  @per_step [{Stream, :resource}, {Stream, :unfold}, {Stream, :iterate}, {Stream, :repeatedly}]

  @doc false
  @spec calls([tuple()], module(), MapSet.t()) :: [ArchTest.Code.call()]
  def calls(clauses, module, locals) do
    state = %{module: module, locals: locals, loop: nil, calls: []}

    clauses
    |> Enum.reduce(state, fn {_meta, _args, guards, body}, acc ->
      walk([guards, body], %{acc | loop: nil})
    end)
    |> Map.fetch!(:calls)
    |> Enum.reverse()
  end

  @doc false
  # Whether a GenServer callback returns the state it was given: `:kept` when every reply tuple each clause
  # returns, such as `{:reply, value, state}` or `{:noreply, state}`, names the state parameter itself, and
  # `:changed` when one returns anything else, or a clause builds no reply the code shows.
  @spec state([tuple()]) :: :kept | :changed
  def state(clauses) do
    if Enum.all?(clauses, &keeps_state?/1), do: :kept, else: :changed
  end

  defp keeps_state?({_meta, args, _guards, body}) do
    with {:ok, var} <- state_var(List.last(args)),
         [_ | _] = returned <- returned_states(body) do
      Enum.all?(returned, &(var_key(&1) == var))
    else
      _ -> false
    end
  end

  defp state_var({:=, _, [left, right]}) do
    with :error <- state_var(left), do: state_var(right)
  end

  defp state_var(ast) do
    case var_key(ast) do
      nil -> :error
      key -> {:ok, key}
    end
  end

  defp var_key({name, meta, context}) when is_atom(name) and is_list(meta) and is_atom(context),
    do: {name, context}

  defp var_key(_ast), do: nil

  defp returned_states(body) do
    body
    |> Macro.prewalk([], fn
      {:{}, _, [:reply, _reply, state | _]} = node, acc -> {node, [state | acc]}
      {:{}, _, [:noreply, state | _]} = node, acc -> {node, [state | acc]}
      {:noreply, state} = node, acc -> {node, [state | acc]}
      {:{}, _, [:stop, _reason, state]} = node, acc -> {node, [state | acc]}
      {:{}, _, [:stop, _reason, _reply, state]} = node, acc -> {node, [state | acc]}
      node, acc -> {node, acc}
    end)
    |> elem(1)
  end

  defp walk({:for, _meta, args}, state) when is_list(args), do: walk_for(args, state)

  defp walk({{:., _, [module, name]}, meta, args} = call, state)
       when is_atom(module) and is_atom(name) and is_list(args) do
    state = record(state, {module, name, length(args)}, meta, args)

    if loop?(module, name, args), do: walk_loop(call, state), else: walk(args, state)
  end

  defp walk({:&, meta, [{:/, _, [callee, arity]}]}, state) when is_integer(arity) do
    case captured(callee, arity, state) do
      nil -> state
      target -> add(state, target, meta, false)
    end
  end

  defp walk({:=, _, [pattern, expression]}, state) do
    state |> then(&walk(expression, &1)) |> bind(pattern, expression)
  end

  # A function with default arguments compiles its shorter arities to `super` calls of the full one.
  defp walk({:super, meta, args}, state) when is_list(args) do
    {_kind, name} = Keyword.fetch!(meta, :super)

    walk({name, meta, args}, state)
  end

  defp walk({name, meta, args}, state) when is_atom(name) and is_list(args) do
    state =
      if MapSet.member?(state.locals, {name, length(args)}),
        do: record(state, {state.module, name, length(args)}, meta, args),
        else: state

    walk(args, state)
  end

  defp walk({form, _meta, args}, state) when is_list(args), do: walk(args, walk(form, state))
  defp walk({left, right}, state), do: walk(right, walk(left, state))
  defp walk(list, state) when is_list(list), do: Enum.reduce(list, state, &walk/2)
  defp walk(_leaf, state), do: state

  defp loop?(module, name, [_enumerable | functions]) when module in [Enum, Stream, Task] do
    (module != Task or name == :async_stream) and {module, name} not in @per_step and
      Enum.any?(functions, &function?/1)
  end

  defp loop?(_module, _name, _args), do: false

  defp function?({:fn, _, _}), do: true
  defp function?({:&, _, [{:/, _, [_callee, arity]}]}) when is_integer(arity), do: true
  defp function?(_argument), do: false

  defp walk_loop({{:., _, [module, name]}, meta, [enumerable | arguments]}, state) do
    loop = %{label: "#{inspect(module)}.#{name}/#{length(arguments) + 1}", vars: loop_vars(state)}

    Enum.reduce(arguments, walk(enumerable, state), &walk_loop_argument(&1, loop, meta, &2))
  end

  defp walk_loop_argument({:fn, _, clauses}, loop, _meta, state) do
    Enum.reduce(clauses, state, fn {:->, _, [params, body]}, acc ->
      in_loop(acc, %{loop | vars: MapSet.union(loop.vars, vars_in(params))}, &walk(body, &1))
    end)
  end

  defp walk_loop_argument({:&, _, [{:/, _, [callee, arity]}]}, loop, meta, state) do
    case captured(callee, arity, state) do
      nil -> state
      target -> in_loop(state, loop, &add(&1, target, meta, true))
    end
  end

  defp walk_loop_argument(argument, _loop, _meta, state), do: walk(argument, state)

  # The first generator's enumerable runs once; later generators, filters and the body run per item.
  defp walk_for(args, state) do
    {qualifiers, options} = Enum.split_with(args, &(not Keyword.keyword?(&1)))
    options = List.flatten(options)
    loop = %{label: "for", vars: loop_vars(state)}

    {state, loop, _first?} = Enum.reduce(qualifiers, {state, loop, true}, &walk_qualifier/2)

    state = Enum.reduce([options[:into], options[:reduce]], state, &walk/2)
    in_loop(state, loop, &walk(options[:do], &1))
  end

  defp walk_qualifier({:<-, _, [pattern, enumerable]}, {state, loop, first?}) do
    state =
      if first?, do: walk(enumerable, state), else: in_loop(state, loop, &walk(enumerable, &1))

    {state, %{loop | vars: MapSet.union(loop.vars, vars_in(pattern))}, false}
  end

  defp walk_qualifier(filter, {state, loop, first?}),
    do: {in_loop(state, loop, &walk(filter, &1)), loop, first?}

  defp in_loop(state, loop, walker), do: %{walker.(%{state | loop: loop}) | loop: state.loop}

  defp captured({{:., _, [module, name]}, _, []}, arity, _state)
       when is_atom(module) and is_atom(name),
       do: {module, name, arity}

  defp captured({name, _, context}, arity, state) when is_atom(name) and is_atom(context) do
    if MapSet.member?(state.locals, {name, arity}), do: {state.module, name, arity}
  end

  defp captured(_callee, _arity, _state), do: nil

  defp record(state, target, meta, args) do
    state
    |> add(target, meta, state.loop != nil and uses?(args, state.loop.vars))
    |> with_receiver(args)
  end

  defp add(state, target, meta, per_item) do
    call = %{
      target: target,
      line: meta[:line],
      loop: state.loop && state.loop.label,
      per_item: per_item,
      receiver: nil
    }

    %{state | calls: [call | state.calls]}
  end

  # The process a call such as `GenServer.call(MyApp.Cache, request)` or `send(MyApp.Cache, message)` talks to:
  # its first argument, when that's a name rather than a pid.
  defp with_receiver(%{calls: [call | rest]} = state, [receiver | _args])
       when is_atom(receiver) and receiver not in [nil, true, false],
       do: %{state | calls: [%{call | receiver: receiver} | rest]}

  defp with_receiver(state, _args), do: state

  # A variable bound from the item is the item too, as `user_id` is in `user_id = order.user_id`.
  defp bind(%{loop: nil} = state, _pattern, _expression), do: state

  defp bind(%{loop: loop} = state, pattern, expression) do
    if uses?(expression, loop.vars),
      do: %{state | loop: %{loop | vars: MapSet.union(loop.vars, vars_in(pattern))}},
      else: state
  end

  defp loop_vars(%{loop: nil}), do: MapSet.new()
  defp loop_vars(%{loop: loop}), do: loop.vars

  defp uses?(ast, vars), do: not MapSet.disjoint?(vars_in(ast), vars)

  # The variables an expression binds or reads, leaving out pinned ones, which belong to the enclosing scope.
  defp vars_in(ast) do
    ast
    |> Macro.prewalk(MapSet.new(), fn
      {:^, _, _}, acc ->
        {nil, acc}

      {name, meta, context} = var, acc
      when is_atom(name) and is_list(meta) and is_atom(context) ->
        {var, MapSet.put(acc, {name, context})}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end
end
