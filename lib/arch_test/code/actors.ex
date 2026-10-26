defmodule ArchTest.Code.Actors do
  @moduledoc false
  # Which calls in a function are made on behalf of the user asking: given, as an argument, the current user or scope,
  # or a value made from it. The user asking is:
  #
  # - what a request's assigns hold under a key such as `current_user`, `current_scope` or `user_id`, as
  #   `conn.assigns.current_user` or `socket.assigns[:current_scope]` do;
  # - what a function named for it returns: a `current_*` one, as `Guardian.Plug.current_resource(conn)` is, or one
  #   naming a user and given the request, as `user_id_from_socket(socket)` is;
  # - what a map pattern binds under such a key, as `%{assigns: %{current_user: user}}` does;
  # - and any variable bound from those, by `=`, `<-` or a `case` clause.
  #
  # And which calls are given the request itself, `conn` or `socket`, which holds the user asking for the code it
  # reaches to read.

  alias ArchTest.Code

  @actor ~r/^current_|(^|_)(user|scope|account|actor|member|owner)(_id)?$/
  @actor_words ~w(user scope account actor member owner)
  @requests [:conn, :socket]

  @type calls :: %{
          on_behalf: [{Code.key(), pos_integer() | nil}],
          requests: [{Code.key(), pos_integer() | nil}]
        }

  @doc false
  # The calls, as `{target, line}`, whose arguments carry the user asking, and those given the request.
  @spec calls([tuple()], module(), MapSet.t()) :: calls()
  def calls(clauses, module, locals) do
    found =
      Enum.flat_map(clauses, fn {_meta, args, _guards, body} ->
        actors = args |> pattern_actors() |> spread(bindings(body))

        body
        |> Macro.prewalk([], fn node, acc ->
          {node, classify(node, actors, module, locals) ++ acc}
        end)
        |> elem(1)
        |> Enum.reverse()
      end)

    %{
      on_behalf: for({:on_behalf, call} <- found, do: call),
      requests: for({:request, call} <- found, do: call)
    }
  end

  defp classify(node, actors, module, locals) do
    case call(node, module, locals) do
      nil ->
        []

      {target, line, args} ->
        for {kind, true} <- [
              on_behalf: carries?(args, actors),
              request: Enum.any?(args, &request?/1)
            ],
            do: {kind, {target, line}}
    end
  end

  defp call({{:., _, [callee, name]}, meta, args}, _module, _locals)
       when is_atom(callee) and is_atom(name) and is_list(args),
       do: {{callee, name, length(args)}, meta[:line], args}

  defp call({name, meta, args}, module, locals) when is_atom(name) and is_list(args) do
    if MapSet.member?(locals, {name, length(args)}),
      do: {{module, name, length(args)}, meta[:line], args}
  end

  defp call(_node, _module, _locals), do: nil

  defp request?({name, meta, context})
       when name in @requests and is_list(meta) and is_atom(context),
       do: true

  defp request?(_arg), do: false

  # Whether an expression carries the user asking: names a variable holding it, or reads it.
  defp carries?(ast, actors) do
    ast
    |> Macro.prewalk(false, fn node, found -> {node, found or actor?(node, actors)} end)
    |> elem(1)
  end

  defp actor?({name, meta, context}, actors)
       when is_atom(name) and is_list(meta) and is_atom(context),
       do: MapSet.member?(actors, {name, context})

  # `conn.assigns.current_user`, or a call with no arguments, such as `MyApp.Auth.current_user()`
  defp actor?({{:., _, [base, key]}, meta, []}, _actors) when is_atom(key) do
    if Keyword.get(meta, :no_parens, false),
      do: assigns?(base) and actor_key?(key),
      else: is_atom(base) and names_actor?(key, [])
  end

  # `conn.assigns[:current_user]`
  defp actor?({{:., _, [Access, :get]}, _, [base, key | _]}, _actors) when is_atom(key),
    do: assigns?(base) and actor_key?(key)

  # `Guardian.Plug.current_resource(conn)`, `user_id_from_socket(socket)`
  defp actor?({{:., _, [callee, name]}, _, args}, _actors)
       when is_atom(callee) and is_atom(name) and is_list(args),
       do: names_actor?(name, args)

  defp actor?({name, _, args}, _actors) when is_atom(name) and is_list(args),
    do: names_actor?(name, args)

  defp actor?(_node, _actors), do: false

  defp assigns?({{:., _, [_base, :assigns]}, meta, []}), do: Keyword.get(meta, :no_parens, false)
  defp assigns?({:assigns, _, context}) when is_atom(context), do: true
  defp assigns?(_ast), do: false

  # A function named for the user asking: `current_*`, or naming a user and given the request.
  defp names_actor?(name, args) do
    words = name |> Atom.to_string() |> String.split("_")

    "current" in words or
      (Enum.any?(words, &(&1 in @actor_words)) and
         Enum.any?(args, &(request?(&1) or assigns?(&1))))
  end

  defp actor_key?(key), do: Regex.match?(@actor, Atom.to_string(key))

  # The variables a pattern binds under a key naming the user asking, at any depth, as `user` in
  # `%{assigns: %{current_user: user}} = socket`. String keys come from the request's params, not from who sent it.
  defp pattern_actors(patterns) do
    patterns
    |> Macro.prewalk(MapSet.new(), fn
      {:%{}, _, pairs} = node, acc when is_list(pairs) ->
        found =
          for {key, value} when is_atom(key) <- pairs,
              actor_key?(key),
              var <- vars(value),
              do: var

        {node, MapSet.union(acc, MapSet.new(found))}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  # Every `pattern = expression`, `pattern <- expression` and `case expression do pattern -> ... end` in a body.
  defp bindings(body) do
    body
    |> Macro.prewalk([], fn
      {op, _, [left, right]} = node, acc when op in [:=, :<-] ->
        {node, [{left, right} | acc]}

      {:case, _, [subject, [do: clauses]]} = node, acc when is_list(clauses) ->
        {node, for({:->, _, [[pattern], _body]} <- clauses, do: {pattern, subject}) ++ acc}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  # The variables holding the user asking: those a binding's pattern names under an actor key, and every variable a
  # binding sets from an expression that carries it, until no more are found.
  defp spread(actors, bindings) do
    next =
      Enum.reduce(bindings, actors, fn {left, right}, acc ->
        acc = MapSet.union(acc, pattern_actors(left))
        if carries?(right, acc), do: MapSet.union(acc, MapSet.new(vars(left))), else: acc
      end)

    if MapSet.size(next) == MapSet.size(actors), do: actors, else: spread(next, bindings)
  end

  defp vars(ast) do
    ast
    |> Macro.prewalk([], fn
      {name, meta, context} = node, acc
      when is_atom(name) and is_list(meta) and is_atom(context) ->
        if String.starts_with?(Atom.to_string(name), "_"),
          do: {node, acc},
          else: {node, [{name, context} | acc]}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end
end
