defmodule ArchTest.Code.Errors do
  @moduledoc false
  # How a function handles errors, read from its expanded code:
  #
  # - the catch-all handlers that turn every error into success: a rescue or catch of anything, or a case or with-else
  #   clause matching any `{:error, _}`, whose result looks like success and isn't the error passed on;
  # - the calls whose results it throws away: a statement in a block, other than an explicit `_ = call`, or the value
  #   of a function given to `Enum.each/2`;
  # - what it returns: whether some tail is an error literal, and which calls are tails, to find every function that
  #   can return `{:error, _}`.

  alias ArchTest.Code

  # Library functions that return `{:error, reason}` when the outside world fails them.
  @error_seeds %{
    Ecto.Repo.Schema => ~w(insert update delete insert_or_update)a,
    Ecto.Repo.Transaction => ~w(transaction transact)a,
    File => ~w(read write rm rmdir mkdir mkdir_p cp cp_r rename touch ln_s ls stat open)a,
    Req => ~w(request get post put patch delete head)a,
    Finch => ~w(request)a,
    HTTPoison => ~w(request get post put patch delete head)a,
    :httpc => ~w(request)a
  }
  @raises [{:erlang, :error}, {:erlang, :raise}, {:erlang, :exit}, {:erlang, :throw}]
  # A callback's or a reduce's reply, which hands control back rather than reporting success.
  @replies [:noreply, :reply, :stop, :cont, :halt, :suspend, :continue]
  # Results that say it failed.
  @failures [:error, :failed, :failure]
  # Modules that only report or format a value: handing the error to them doesn't handle it.
  @reporting [
    Logger,
    IO,
    :io,
    :logger,
    Kernel,
    String.Chars,
    List.Chars,
    Inspect,
    Exception,
    :erlang
  ]
  @discarding [{Enum, :each}, {Stream, :each}]

  @type swallow :: %{
          line: pos_integer() | nil,
          handler: :rescue | :catch | :error,
          returns: String.t(),
          sources: [Code.key() | {:dynamic, atom() | nil, arity()}]
        }
  @type tails :: %{error: boolean(), calls: [Code.key()]}

  @doc false
  # The catch-all handlers in a function that turn every error into success.
  @spec swallows([tuple()], module(), MapSet.t()) :: [swallow()]
  def swallows(clauses, module, locals) do
    clauses
    |> Enum.map(fn {_meta, _args, _guards, body} -> body end)
    |> Macro.prewalk([], fn node, acc -> {node, handlers(node, module, locals) ++ acc} end)
    |> elem(1)
    |> Enum.reverse()
  end

  @doc false
  # The calls whose results a function throws away, as `{target, line}`. A clause that returns an error is already
  # failing, and a cleanup there, as `File.rm(tmp)` before `{:error, reason}` is, can't change that, so its body is
  # left out.
  @spec discards([tuple()], module(), MapSet.t()) :: [{Code.key(), pos_integer() | nil}]
  def discards(clauses, module, locals) do
    clauses
    |> Enum.map(fn {_meta, _args, _guards, body} -> body end)
    |> Macro.prewalk([], fn
      {:->, meta, [patterns, body]}, acc ->
        if error?(tail(body)),
          do: {{:->, meta, [patterns, nil]}, acc},
          else: {{:->, meta, [patterns, body]}, acc}

      node, acc ->
        {node, discarded(node, module, locals) ++ acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  @doc false
  # Whether a function calls through a module chosen at runtime, as `adapter().charge(order)` does. Field access,
  # `order.total`, isn't a call.
  @spec dynamic?([tuple()]) :: boolean()
  def dynamic?(clauses) do
    clauses
    |> Enum.map(fn {_meta, _args, _guards, body} -> body end)
    |> Macro.prewalk(false, fn
      {{:., _, [callee, name]}, meta, args} = node, found
      when is_atom(name) and is_list(args) and not is_atom(callee) ->
        {node, found or not Keyword.get(meta, :no_parens, false)}

      node, found ->
        {node, found}
    end)
    |> elem(1)
  end

  @doc false
  # The functions that call through a module chosen at runtime, directly or through the project functions they call:
  # an adapter's caller may be reaching the database or the network, though the code can't say.
  @spec reaching_dynamic(Code.t()) :: MapSet.t(Code.key())
  def reaching_dynamic(%Code{functions: functions}) do
    direct = for {key, %{dynamic: true}} <- functions, into: MapSet.new(), do: key
    spread(direct, functions)
  end

  defp spread(set, functions) do
    next =
      for {key, %{calls: calls}} <- functions,
          not MapSet.member?(set, key),
          Enum.any?(calls, &MapSet.member?(set, &1.target)),
          into: set,
          do: key

    if MapSet.size(next) == MapSet.size(set), do: set, else: spread(next, functions)
  end

  @doc false
  # Whether some tail of the function is an error literal, and the calls in tail position.
  @spec tails([tuple()], module(), MapSet.t()) :: tails()
  def tails(clauses, module, locals) do
    found = Enum.flat_map(clauses, fn {_meta, _args, _guards, body} -> tail_values(body) end)

    %{
      error: Enum.any?(found, &error?/1),
      calls: found |> Enum.flat_map(&List.wrap(target(&1, module, locals))) |> Enum.uniq()
    }
  end

  @doc false
  # The functions that can return `{:error, _}`: library functions known to, and project functions with an error
  # literal or such a call in tail position.
  @spec returning(Code.t()) :: MapSet.t(Code.key())
  def returning(%Code{functions: functions}) do
    direct = for {key, %{tails: %{error: true}}} <- functions, into: MapSet.new(), do: key
    grow(direct, functions)
  end

  @doc false
  @spec returns_error?(Code.key(), MapSet.t(Code.key())) :: boolean()
  def returns_error?({module, name, _arity} = key, returning) do
    MapSet.member?(returning, key) or name in Map.get(@error_seeds, module, [])
  end

  defp grow(set, functions) do
    next =
      for {key, %{tails: %{calls: calls}}} <- functions,
          not MapSet.member?(set, key),
          Enum.any?(calls, &returns_error?(&1, set)),
          into: set,
          do: key

    if MapSet.size(next) == MapSet.size(set), do: set, else: grow(next, functions)
  end

  # --- catch-all handlers ---------------------------------------------------------------------------------------

  defp handlers({:try, _, [options]}, module, locals) when is_list(options) do
    rescues =
      for {:->, meta, [[pattern], body]} <- Keyword.get(options, :rescue, []),
          any?(pattern),
          do: {meta, :rescue, pattern, body}

    catches =
      for {:->, meta, [patterns, body]} <- Keyword.get(options, :catch, []),
          any?(List.last(patterns)),
          do: {meta, :catch, patterns, body}

    sources = sources(options[:do], module, locals)

    for {meta, handler, pattern, body} <- rescues ++ catches,
        returns = success(body, pattern, locals),
        do: swallow(meta, handler, returns, sources)
  end

  defp handlers({:case, _, [subject, [do: clauses]]}, module, locals) when is_list(clauses),
    do: error_handlers(clauses, List.wrap(target(subject, module, locals)), false, locals)

  defp handlers({:with, _, args}, module, locals) when is_list(args) do
    {matches, [options]} = Enum.split(args, -1)

    sources =
      for {:<-, _, [_, right]} <- matches,
          key <- List.wrap(target(right, module, locals)),
          do: key

    if is_list(options),
      do: error_handlers(Keyword.get(options, :else, []), sources, true, locals),
      else: []
  end

  defp handlers(_node, _module, _locals), do: []

  # Clauses matching any `{:error, _}`, or anything beside an `{:ok, _}` clause or in a with's else. A bare `:error`
  # isn't one: Map.fetch/2 and Integer.parse/1 return it for a missing key or bad input, not a failure. The rule
  # judges them only when a source, the case's subject or a with's right side, can return `{:error, _}`.
  defp error_handlers(clauses, sources, else?, locals) do
    ok? = Enum.any?(clauses, &match?({:->, _, [[{:ok, _}], _]}, &1))

    for {:->, meta, [[pattern], body]} <- clauses,
        any_error?(pattern, ok? or else?),
        not predicate?(body, clauses),
        returns = success(body, pattern, locals),
        do: swallow(meta, :error, returns, sources)
  end

  # `false` beside a clause returning `true` answers whether the call succeeded, as `match?({:ok, _}, call)` does.
  defp predicate?(body, clauses),
    do: tail(body) == false and Enum.any?(clauses, &match?({:->, _, [_, true]}, &1))

  defp swallow(meta, handler, returns, sources),
    do: %{line: meta[:line], handler: handler, returns: returns, sources: sources}

  # A pattern matching every exception or thrown value: a variable or `_`, not `e in [ArgumentError]`.
  defp any?({name, meta, context}) when is_atom(name) and is_list(meta) and is_atom(context),
    do: true

  defp any?(_pattern), do: false

  defp any_error?({:error, reason}, _catch_all?), do: any?(reason)

  defp any_error?({:=, _, [left, right]}, catch_all?),
    do: any_error?(left, catch_all?) or any_error?(right, catch_all?)

  defp any_error?(pattern, catch_all?), do: catch_all? and any?(pattern)

  # How a handler's result looks, when it looks like success: it raises nothing, doesn't pass what it caught on, and
  # its value is a literal other than an error or a callback's reply, such as `{:noreply, socket}`, which hands
  # control back rather than reporting success. What it caught is passed on when the value uses it, as
  # `{:stop, reason}` does, or a call other than a log or a format is given it, as `mark_failed(job, reason)` is.
  defp success(body, pattern, locals) do
    tail = tail(body)
    caught = caught(body, pattern)

    cond do
      raises?(body) -> nil
      error?(tail) or reply?(tail) -> nil
      uses?(tail, caught) or handed_on?(body, caught, locals) -> nil
      literal?(tail) -> describe(tail)
      true -> nil
    end
  end

  # The variables holding what a handler caught: the pattern's, and those bound from them, as `message` is in
  # `message = Exception.message(error)`.
  defp caught(body, pattern) do
    statements = with {:__block__, _, expressions} <- body, do: expressions

    statements
    |> List.wrap()
    |> Enum.reduce(MapSet.new(vars(pattern)), fn
      {:=, _, [left, right]}, caught ->
        if uses?(right, caught), do: MapSet.union(caught, MapSet.new(vars(left))), else: caught

      _statement, caught ->
        caught
    end)
  end

  defp uses?(ast, caught), do: Enum.any?(vars(ast), &MapSet.member?(caught, &1))

  defp handed_on?(body, caught, locals) do
    body
    |> Macro.prewalk(false, fn
      {{:., _, [callee, _name]}, _, args} = node, found when is_list(args) ->
        {node, found or (callee not in @reporting and uses?(args, caught))}

      {name, _, args} = node, found when is_atom(name) and is_list(args) ->
        {node, found or (MapSet.member?(locals, {name, length(args)}) and uses?(args, caught))}

      node, found ->
        {node, found}
    end)
    |> elem(1)
  end

  # The calls in a try's body, with calls through a variable, as `adapter.charge(order)` and `handler.(job)` are,
  # as `{:dynamic, name, arity}`.
  defp sources(body, module, locals) do
    body
    |> Macro.prewalk([], fn
      {{:., _, [_fun]}, _, args} = node, acc when is_list(args) ->
        {node, [{:dynamic, nil, length(args)} | acc]}

      {{:., _, [callee, name]}, _, args} = node, acc
      when is_atom(name) and is_list(args) and not is_atom(callee) ->
        {node, [{:dynamic, name, length(args)} | acc]}

      node, acc ->
        {node, List.wrap(target(node, module, locals)) ++ acc}
    end)
    |> elem(1)
    |> Enum.uniq()
  end

  defp raises?(body) do
    body
    |> Macro.prewalk(false, fn
      {{:., _, [module, name]}, _, _} = node, found -> {node, found or {module, name} in @raises}
      node, found -> {node, found}
    end)
    |> elem(1)
  end

  # The variables an expression names, by name and context, leaving out `_` and the ones starting with it.
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

  defp reply?({first, _}) when first in @replies, do: true
  defp reply?({:{}, _, [first | _]}) when first in @replies, do: true
  defp reply?(_value), do: false

  defp literal?(value)
       when is_atom(value) or is_number(value) or is_binary(value) or is_list(value),
       do: true

  # A map update records something, as `%{acc | failed: acc.failed + 1}` counts a failure.
  defp literal?({:%{}, _, [{:|, _, _}]}), do: false
  defp literal?({:%{}, _, _}), do: true
  defp literal?({:%, _, _}), do: true
  defp literal?({first, _second}) when is_atom(first), do: true
  defp literal?(_value), do: false

  defp describe({:ok, _}), do: "{:ok, ...}"

  defp describe(value)
       when is_atom(value) or is_number(value) or is_binary(value) or value == [],
       do: inspect(value)

  defp describe(_value), do: "a default value"

  defp error?(value) when value in @failures, do: true
  defp error?({:error, _}), do: true
  defp error?({:{}, _, [:error | _]}), do: true
  defp error?(_value), do: false

  # --- discarded results ----------------------------------------------------------------------------------------

  defp discarded({:__block__, _, [_ | _] = expressions}, module, locals) do
    expressions
    |> Enum.drop(-1)
    |> Enum.flat_map(&List.wrap(statement(&1, module, locals)))
  end

  defp discarded({{:., _, [module, name]}, _, [_enumerable, function]}, caller, locals)
       when {module, name} in @discarding do
    case function do
      {:fn, _, clauses} ->
        for {:->, _, [_params, body]} <- clauses,
            found <- List.wrap(statement(tail(body), caller, locals)),
            do: found

      {:&, meta, [{:/, _, [callee, arity]}]} when is_integer(arity) ->
        List.wrap(
          with key when key != nil <- captured(callee, arity, caller, locals),
               do: {key, meta[:line]}
        )

      _ ->
        []
    end
  end

  defp discarded(_node, _module, _locals), do: []

  defp statement({:=, _, [{:_, _, _}, _call]}, _module, _locals), do: nil

  defp statement(expression, module, locals) do
    with key when key != nil <- target(expression, module, locals), do: {key, line(expression)}
  end

  defp captured({{:., _, [module, name]}, _, []}, arity, _caller, _locals) when is_atom(module),
    do: {module, name, arity}

  defp captured({name, _, context}, arity, caller, locals)
       when is_atom(name) and is_atom(context) do
    if MapSet.member?(locals, {name, arity}), do: {caller, name, arity}
  end

  defp captured(_callee, _arity, _caller, _locals), do: nil

  # --- tails ----------------------------------------------------------------------------------------------------

  defp tail_values({:__block__, _, [_ | _] = expressions}),
    do: expressions |> List.last() |> tail_values()

  defp tail_values({form, _, [_subject, [do: clauses]]})
       when form in [:case, :receive] and is_list(clauses),
       do: Enum.flat_map(clauses, &clause_tails/1)

  defp tail_values({:cond, _, [[do: clauses]]}), do: Enum.flat_map(clauses, &clause_tails/1)

  defp tail_values({:with, _, args}) do
    {matches, [options]} = Enum.split(args, -1)

    # Without an else, a with returns whatever a clause's right side gave that didn't match, often an error.
    unmatched =
      if Keyword.has_key?(options, :else),
        do: [],
        else: for({:<-, _, [_, right]} <- matches, do: right)

    tail_values(options[:do]) ++
      Enum.flat_map(Keyword.get(options, :else, []), &clause_tails/1) ++ unmatched
  end

  defp tail_values({:try, _, [options]}) do
    main = if Keyword.has_key?(options, :else), do: [], else: tail_values(options[:do])

    handlers =
      Keyword.get(options, :rescue, []) ++
        Keyword.get(options, :catch, []) ++ Keyword.get(options, :else, [])

    main ++ Enum.flat_map(handlers, &clause_tails/1)
  end

  defp tail_values(value), do: [value]

  defp clause_tails({:->, _, [_patterns, body]}), do: tail_values(body)

  defp tail({:__block__, _, [_ | _] = expressions}), do: List.last(expressions)
  defp tail(expression), do: expression

  defp target({{:., _, [module, name]}, _, args}, _caller, _locals)
       when is_atom(module) and is_atom(name),
       do: {module, name, length(args)}

  defp target({name, _, args}, caller, locals) when is_atom(name) and is_list(args) do
    if MapSet.member?(locals, {name, length(args)}), do: {caller, name, length(args)}
  end

  defp target(_expression, _caller, _locals), do: nil

  defp line({{:., _, _}, meta, _}), do: meta[:line]
  defp line({_name, meta, _args}), do: meta[:line]
end
