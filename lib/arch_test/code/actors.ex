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
  # reaches to read; which calls a function given as an argument makes, with the call it's given to; which calls are
  # given a value the request's assigns hold, as `socket.assigns.post` is; and whether the function reads the user
  # asking at all.

  alias ArchTest.Code

  @actor ~r/^current_|(^|_)(user|scope|account|actor|member|owner|subject)(_id)?$/
  @actor_words ~w(user scope account actor member owner subject)
  # The comparisons that check a value against another, as `post.user_id == user.id` does, as the compiler writes them.
  @comparisons [:==, :"/=", :"=:=", :"=/="]
  @requests [:conn, :socket]

  @type call :: {Code.key(), pos_integer() | nil}
  @type calls :: %{
          on_behalf: [call()],
          requests: [call()],
          callbacks: [{call(), [call()]}],
          held: [call()],
          reads_user: boolean()
        }

  @doc false
  # The calls, as `{target, line}`, whose arguments carry the user asking, and those given the request.
  @spec calls([tuple()], module(), MapSet.t()) :: calls()
  def calls(clauses, module, locals) do
    found =
      Enum.flat_map(clauses, fn {_meta, args, _guards, body} ->
        bindings = bindings(body)
        actors = args |> pattern_actors() |> spread(bindings)

        # A value compared with the user's, as a post whose owner is, has been checked against them.
        compared = compared(body, actors)
        actors = spread(MapSet.union(actors, compared), bindings)
        held = spread_held(MapSet.new(), bindings)

        reads =
          if MapSet.size(actors) > 0 or carries?(body, actors), do: [{:reads, true}], else: []

        # A read whose result is then compared with the user's, as `post = get_post!(id)` is, reads on their behalf.
        checked_reads =
          for {left, right} <- bindings,
              Enum.any?(vars(left), &MapSet.member?(compared, &1)),
              {target, line, _args} <- List.wrap(call(right, module, locals)),
              do: {:on_behalf, {target, line}}

        body
        |> Macro.prewalk(reads ++ checked_reads, fn node, acc ->
          {node, classify(node, {actors, held}, module, locals) ++ acc}
        end)
        |> elem(1)
        |> Enum.reverse()
      end)

    %{
      on_behalf: for({:on_behalf, call} <- found, do: call),
      requests: for({:request, call} <- found, do: call),
      callbacks: for({:callback, pair} <- found, do: pair),
      held: for({:held, call} <- found, do: call),
      reads_user: Keyword.has_key?(found, :reads)
    }
  end

  defp classify(node, {actors, held}, module, locals) do
    case call(node, module, locals) do
      nil -> []
      {target, line, args} -> classify_call({target, line}, args, {actors, held}, module, locals)
    end
  end

  defp classify_call(call, args, {actors, held}, module, locals) do
    on_behalf? = carries?(args, actors)

    kinds =
      for {kind, true} <- [
            on_behalf: on_behalf?,
            request: Enum.any?(args, &request?/1),
            held: holds?(args, held)
          ],
          do: {kind, call}

    callbacks =
      for {:fn, _, _} = fun <- args, do: {:callback, {call, calls_in(fun, module, locals)}}

    captured = if on_behalf?, do: captures(args, module, locals), else: []
    kinds ++ callbacks ++ Enum.map(captured, &{:on_behalf, &1})
  end

  # The functions captured in a call's arguments, as `&archive/2` is, where they're captured: given along with the
  # user asking, as `Batches.each_for(subject, ids, &archive/2)` gives it, they run on the user's behalf.
  defp captures(args, module, locals) do
    args
    |> Macro.prewalk([], fn
      {:&, meta, [{:/, _, [callee, arity]}]} = node, acc when is_integer(arity) ->
        case captured(callee, arity, module, locals) do
          nil -> {node, acc}
          target -> {node, [{target, meta[:line]} | acc]}
        end

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp captured({{:., _, [callee, name]}, _, []}, arity, _module, _locals)
       when is_atom(callee) and is_atom(name),
       do: {callee, name, arity}

  defp captured({name, _, context}, arity, module, locals)
       when is_atom(name) and is_atom(context) do
    if MapSet.member?(locals, {name, arity}), do: {module, name, arity}
  end

  defp captured(_callee, _arity, _module, _locals), do: nil

  defp calls_in(ast, module, locals) do
    ast
    |> Macro.prewalk([], fn node, acc ->
      case call(node, module, locals) do
        {target, line, _args} -> {node, [{target, line} | acc]}
        nil -> {node, acc}
      end
    end)
    |> elem(1)
  end

  # Whether an expression carries a value the request's assigns hold, other than the user asking: a record the
  # server loaded, as `socket.assigns.post` is, or a variable bound from one.
  defp holds?(ast, held) do
    ast
    |> Macro.prewalk(false, fn node, found -> {node, found or held?(node, held)} end)
    |> elem(1)
  end

  defp held?({name, meta, context}, held)
       when is_atom(name) and is_list(meta) and is_atom(context),
       do: MapSet.member?(held, {name, context})

  defp held?({{:., _, [base, key]}, meta, []}, _held) when is_atom(key),
    do: Keyword.get(meta, :no_parens, false) and request_assigns?(base) and not actor_key?(key)

  defp held?({{:., _, [Access, :get]}, _, [base, key | _]}, _held) when is_atom(key),
    do: request_assigns?(base) and not actor_key?(key)

  defp held?(_node, _held), do: false

  defp request_assigns?({{:., _, [base, :assigns]}, meta, []}),
    do: Keyword.get(meta, :no_parens, false) and request?(base)

  defp request_assigns?(_ast), do: false

  defp spread_held(held, bindings) do
    next =
      Enum.reduce(bindings, held, fn {left, right}, acc ->
        if holds?(right, acc), do: MapSet.union(acc, MapSet.new(vars(left))), else: acc
      end)

    if MapSet.size(next) == MapSet.size(held), do: held, else: spread_held(next, bindings)
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

      # An anonymous function's parameters, as `fn %{current_user: user} -> ... end` given a socket's assigns.
      {:fn, _, clauses} = node, acc ->
        {node, for({:->, _, [patterns, _body]} <- clauses, do: {patterns, nil}) ++ acc}

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

  # The variables a comparison checks against the user asking: those on one side of `==` or `!=` when the other side
  # carries the user, as `post` in `post.user_id == user.id` is.
  defp compared(body, actors) do
    body
    |> Macro.prewalk(MapSet.new(), fn
      {{:., _, [:erlang, op]}, _, [left, right]} = node, acc when op in @comparisons ->
        {node, MapSet.union(acc, checked(left, right, actors))}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp checked(left, right, actors) do
    cond do
      carries?(right, actors) and not carries?(left, actors) -> MapSet.new(vars(left))
      carries?(left, actors) and not carries?(right, actors) -> MapSet.new(vars(right))
      true -> MapSet.new()
    end
  end
end
