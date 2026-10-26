defmodule ArchTest.Code.Signatures do
  @moduledoc false
  # What a function takes and returns, read from its clauses:
  #
  # - its parameters' names, by position, where a clause names one with a plain variable;
  # - its flags: boolean parameters it branches on. A parameter is boolean when a spec types it `boolean()`, its
  #   default is `true` or `false`, a clause matches `true` or `false` there, or a guard checks `is_boolean/1` on it;
  #   the function branches on it when clauses match different booleans there, or a `case`, `if` or `unless` tests it;
  # - its choices between three or more string literals, in clause heads or a `case`, other than a parser's, whose
  #   every choice returns an atom, `{:ok, atom}` or `:error`;
  # - its alternative return types: an `if` or `case` on one of its options, read from a keyword parameter, whose
  #   branches return values of different kinds, as a bare value and a tuple are.

  @type flag :: %{position: non_neg_integer(), name: atom() | nil, line: pos_integer() | nil}
  @type choice :: %{line: pos_integer() | nil, strings: [String.t()]}
  @type alternative :: %{line: pos_integer() | nil, option: atom()}
  @type t :: %{
          params: [atom() | nil],
          flags: [flag()],
          choices: [choice()],
          alternatives: [alternative()]
        }

  @doc false
  # `booleans` are the positions a spec types `boolean()`, and `defaults` the default values by position.
  @spec of([tuple()], MapSet.t(non_neg_integer()), %{non_neg_integer() => term()}) :: t()
  def of(clauses, booleans, defaults) do
    params = params(clauses)

    %{
      params: params,
      flags: flags(clauses, params, booleans, defaults),
      choices: head_choices(clauses) ++ case_choices(clauses),
      alternatives: alternatives(clauses)
    }
  end

  @doc false
  # The default values a lower-arity clause passes, by position, from its `super` call's arguments:
  # `def render(text, html \\ false)` makes `render/1` call `super(x0, false)`.
  @spec defaults([Macro.t()]) :: %{non_neg_integer() => term()}
  def defaults(args) do
    for {arg, position} <- Enum.with_index(args), literal?(arg), into: %{}, do: {position, arg}
  end

  # --- parameters -----------------------------------------------------------------------------------------------

  defp params([{_meta, args, _guards, _body} | _] = clauses) do
    for position <- 0..(length(args) - 1)//1 do
      Enum.find_value(clauses, fn {_meta, args, _guards, _body} ->
        name(Enum.at(args, position))
      end)
    end
  end

  defp params([]), do: []

  defp name({name, meta, context}) when is_atom(name) and is_list(meta) and is_atom(context),
    do: name |> Atom.to_string() |> String.trim_leading("_") |> String.to_atom()

  defp name(_pattern), do: nil

  # --- flags ----------------------------------------------------------------------------------------------------

  defp flags([{_meta, args, _guards, _body} | _] = clauses, params, booleans, defaults) do
    for position <- 0..(length(args) - 1)//1,
        boolean?(clauses, position, booleans, defaults),
        line = branches_on(clauses, position),
        do: %{position: position, name: Enum.at(params, position), line: line}
  end

  defp flags([], _params, _booleans, _defaults), do: []

  # A clause matching `nil` there too takes an optional boolean as data, as an encoder does, not a flag.
  defp boolean?(clauses, position, booleans, defaults) do
    optional? =
      Enum.any?(clauses, fn {_meta, args, _guards, _body} ->
        Enum.at(args, position) == nil and length(args) > position
      end)

    not optional? and
      (MapSet.member?(booleans, position) or Map.get(defaults, position) in [true, false] or
         Enum.any?(clauses, fn {_meta, args, guards, _body} ->
           Enum.at(args, position) in [true, false] or
             checks_boolean?(guards, Enum.at(args, position))
         end))
  end

  defp checks_boolean?(guards, {name, _, context}) when is_atom(name) and is_atom(context) do
    guards
    |> Macro.prewalk(false, fn
      {{:., _, [:erlang, :is_boolean]}, _, [{^name, _, ^context}]} = node, _found -> {node, true}
      {:is_boolean, _, [{^name, _, ^context}]} = node, _found -> {node, true}
      node, found -> {node, found}
    end)
    |> elem(1)
  end

  defp checks_boolean?(_guards, _arg), do: false

  # The line of the first clause that branches on the parameter: clauses matching different booleans there, or a
  # `case`, `if` or `unless` on it.
  defp branches_on(clauses, position) do
    literals =
      for {_meta, args, _guards, _body} <- clauses,
          (arg = Enum.at(args, position)) in [true, false],
          do: arg

    if length(Enum.uniq(literals)) == 2,
      do: clauses |> hd() |> elem(0) |> Keyword.get(:line),
      else: Enum.find_value(clauses, &tested_at(&1, position))
  end

  defp tested_at({meta, args, _guards, body}, position) do
    case Enum.at(args, position) do
      {name, _, context} when is_atom(name) and is_atom(context) ->
        if tests?(body, name, context), do: meta[:line]

      _ ->
        nil
    end
  end

  # Whether a body has a `case` on the variable: `if` and `unless` expand to one.
  defp tests?(body, name, context) do
    body
    |> Macro.prewalk(false, fn
      {:case, _, [{^name, _, ^context}, _]} = node, _found -> {node, true}
      node, found -> {node, found}
    end)
    |> elem(1)
  end

  # --- string choices -------------------------------------------------------------------------------------------

  defp head_choices([{meta, args, _guards, _body} | _] = clauses) when length(clauses) >= 3 do
    for position <- 0..(length(args) - 1)//1,
        strings =
          for(
            {_meta, args, _guards, _body} <- clauses,
            is_binary(Enum.at(args, position)),
            do: Enum.at(args, position)
          ),
        length(Enum.uniq(strings)) >= 3,
        not vocabulary?(strings),
        not parser?(
          for {_meta, args, _guards, body} <- clauses,
              is_binary(Enum.at(args, position)),
              do: body
        ),
        do: %{line: meta[:line], strings: Enum.uniq(strings)}
  end

  defp head_choices(_clauses), do: []

  defp case_choices(clauses) do
    clauses
    |> Enum.map(fn {_meta, _args, _guards, body} -> body end)
    |> Macro.prewalk([], fn
      {:case, meta, [_subject, [do: arms]]} = node, acc when is_list(arms) ->
        string_arms =
          for {:->, _, [[pattern], body]} <- arms, is_binary(pattern), do: {pattern, body}

        strings = string_arms |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

        if length(strings) >= 3 and not vocabulary?(strings) and
             not parser?(Enum.map(string_arms, &elem(&1, 1))),
           do: {node, [%{line: meta[:line], strings: strings} | acc]},
           else: {node, acc}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # A parser turns each string into an atom: `:standard`, `{:ok, :standard}`, or `:error`.
  defp parser?(bodies), do: Enum.all?(bodies, &(tail(&1) |> parsed?()))

  # Strings from a vocabulary outside the code, which atoms wouldn't name better: single characters, as a tokenizer's
  # `"("` and `"["` are, file and template names, as `"index.html"` is, and paths, as `"/settings"` is.
  defp vocabulary?(strings) do
    Enum.all?(strings, &(String.length(&1) == 1)) or
      Enum.all?(strings, &Regex.match?(~r/^[\w.-]+\.[a-z0-9]{1,5}$/, &1)) or
      Enum.all?(strings, &(&1 == "" or String.starts_with?(&1, "/")))
  end

  # A parser's answer: an atom, `{:ok, ...}` or an error, as `{:ok, :md5, false}` or `{:ok, 12}` are.
  defp parsed?(value) when is_atom(value), do: true
  defp parsed?({:ok, _value}), do: true
  defp parsed?({:{}, _, [:ok | _]}), do: true
  defp parsed?(value), do: error?(value)

  # --- alternative return types ---------------------------------------------------------------------------------

  defp alternatives(clauses) do
    Enum.flat_map(clauses, fn {_meta, args, _guards, body} ->
      options =
        for {name, meta, context} <- args,
            is_atom(name) and is_list(meta) and is_atom(context),
            do: {name, context}

      body
      |> Macro.prewalk([], fn node, acc ->
        {node, List.wrap(alternative(node, options)) ++ acc}
      end)
      |> elem(1)
      |> Enum.reverse()
    end)
  end

  # A `case` on an option whose arms return different kinds of value.
  defp alternative({:case, meta, [subject, [do: arms]]}, options) when is_list(arms) do
    tails = for {:->, _, [patterns, arm]} <- arms, not passes_on?(patterns, arm), do: tail(arm)

    with option when option != nil <- option_read(subject, options),
         true <- kinds_differ?(tails),
         do: %{line: meta[:line], option: option},
         else: (_ -> nil)
  end

  defp alternative(_node, _options), do: nil

  # The option a condition reads from a parameter: `Keyword.get(opts, :raw)`, `Keyword.fetch!(opts, :raw)` or
  # `opts[:raw]`.
  defp option_read({{:., _, [Keyword, function]}, _, [{name, _, context}, option | _]}, params)
       when function in [:get, :fetch, :fetch!, :has_key?] and is_atom(option) do
    if {name, context} in params, do: option
  end

  # `opts[:raw]` reads an option when the parameter is named for options; on a map, it reads a field.
  defp option_read({{:., _, [Access, :get]}, _, [{name, _, context}, option | _]}, params)
       when is_atom(option) do
    if {name, context} in params and options?(name), do: option
  end

  defp option_read(_subject, _params), do: nil

  # Whether a branch returns the value its pattern bound, as `opts[:limit] || 10` does for a limit given: the option's
  # own value, whose kind the code doesn't say.
  defp passes_on?([pattern], arm) do
    case {pattern, tail(arm)} do
      {{:when, _, [{name, _, context} | _]}, {name, _, context}} -> true
      {{name, _, context}, {name, _, context}} when is_atom(name) and is_atom(context) -> true
      _ -> false
    end
  end

  defp passes_on?(_patterns, _arm), do: false

  defp options?(name) do
    name = Atom.to_string(name)
    name in ["opts", "options"] or String.ends_with?(name, ["_opts", "_options"])
  end

  # Whether the branches return two kinds of value, one a tuple, list or map, as `int` and `{int, rest}` are. An
  # error, which any function may return, and a call, whose kind the code doesn't say, don't count.
  # Two branches return different kinds of value when they return two kinds of literal, one a tuple, list or map, or
  # when one returns a variable and another a tuple holding it, as `int` and `{int, rest}` do. A variable's kind isn't
  # known otherwise, and a map update keeps the map's.
  defp kinds_differ?(tails) do
    tails = Enum.reject(tails, &error?/1)
    kinds = tails |> Enum.map(&kind/1) |> Enum.reject(&(&1 == :unknown)) |> Enum.uniq()

    returned =
      for {name, meta, context} <- tails,
          is_atom(name) and is_list(meta) and is_atom(context),
          do: {name, context}

    (length(kinds) > 1 and Enum.any?(kinds, &(&1 != :value))) or
      Enum.any?(tails, &(tuple?(&1) and Enum.any?(vars(&1), fn var -> var in returned end)))
  end

  defp tuple?({:{}, _, _}), do: true
  defp tuple?({first, _second}) when not is_atom(first) or first not in [:%{}, :%], do: true
  defp tuple?(_value), do: false

  defp kind({:{}, _, items}), do: {:tuple, length(items)}
  defp kind({:%{}, _, [{:|, _, _}]}), do: :unknown
  defp kind({:%{}, _, _}), do: :map
  defp kind({:%, _, _}), do: :map
  defp kind({first, _second}) when not is_atom(first) or first not in [:%{}, :%], do: {:tuple, 2}
  defp kind(list) when is_list(list), do: :list
  defp kind(literal) when is_atom(literal) or is_number(literal) or is_binary(literal), do: :value
  defp kind(_expression), do: :unknown

  defp vars(ast) do
    ast
    |> Macro.prewalk([], fn
      {name, meta, context} = node, acc
      when is_atom(name) and is_list(meta) and is_atom(context) ->
        {node, [{name, context} | acc]}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp error?(:error), do: true
  defp error?({:error, _}), do: true
  defp error?({:{}, _, [:error | _]}), do: true
  defp error?(_value), do: false

  defp tail({:__block__, _, [_ | _] = expressions}), do: List.last(expressions)
  defp tail(expression), do: expression

  defp literal?(value) when is_atom(value) or is_number(value) or is_binary(value), do: true
  defp literal?(value) when is_list(value), do: Enum.all?(value, &literal?/1)
  defp literal?(_value), do: false
end
