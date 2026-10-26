defmodule ArchTest.Code.Data do
  @moduledoc false
  # What a function does with stored data, read from its expanded clauses: the fields it casts from params, the whole
  # tables it lists, the fields it sets from their own old values, and whether it locks the rows it reads. And what a
  # module's fields hold: an Ecto schema's types, from `__changeset__/0`, and a struct's float defaults.

  alias ArchTest.Code

  @type cast :: %{line: pos_integer() | nil, fields: [atom()]}
  @type table :: %{target: Code.key(), line: pos_integer() | nil, schema: module()}
  @type derived :: %{line: pos_integer() | nil, field: atom()}
  @type flow :: %{
          from: non_neg_integer(),
          target: Code.key(),
          to: non_neg_integer(),
          line: pos_integer() | nil,
          whole: boolean(),
          overrides: [String.t()]
        }

  # What turns a value into a new one, here an old value of the field it's written back to: arithmetic, and appending
  # to a list. Concatenating a string formats it, as `"New " <> post.title` does, rather than counting with it.
  @operators [:+, :-, :*, :/, :++, :div, :rem]
  @decimal [:add, :sub, :mult, :div]
  # Selects that return one row, or one per group, rather than a table.
  @aggregates [:count, :sum, :avg, :min, :max]

  @doc false
  # The fields each `Ecto.Changeset.cast/3,4` takes from params, when the code lists them, as a literal or a module
  # attribute does.
  @spec casts([tuple()]) :: [cast()]
  def casts(clauses) do
    clauses
    |> bodies()
    |> Macro.prewalk([], fn
      {{:., _, [Ecto.Changeset, :cast]}, meta, [_data, _params, fields | _]} = node, acc
      when is_list(fields) ->
        if fields != [] and Enum.all?(fields, &is_atom/1),
          do: {node, [%{line: meta[:line], fields: fields} | acc]},
          else: {node, acc}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  @doc false
  # The calls that list every row of a table: `all/1,2` given a schema, or a query with no `where`, `limit` or
  # aggregate, as `Repo.all(Post)` and `Post |> order_by(:title) |> Repo.all()` are. A query the function is given, or
  # one another function builds, isn't known, so it isn't counted.
  @spec whole_tables([tuple()]) :: [table()]
  def whole_tables(clauses) do
    Enum.flat_map(clauses, fn {_meta, _args, _guards, body} ->
      bound = bindings(body)

      body
      |> Macro.prewalk([], fn node, acc -> {node, List.wrap(whole_table(node, bound)) ++ acc} end)
      |> elem(1)
      |> Enum.reverse()
    end)
  end

  defp whole_table({{:., _, [module, :all]}, meta, [query | _] = args}, bound)
       when is_atom(module) and length(args) <= 2 do
    with schema when schema != nil <- table(query, bound, 0),
         do: %{target: {module, :all, length(args)}, line: meta[:line], schema: schema}
  end

  defp whole_table(_node, _bound), do: nil

  @doc false
  # The changes that set a field from its own old value, as `change(post, views: post.views + 1)` and
  # `put_change(changeset, :balance, account.balance - amount)` do. A `change/2` or `cast/3` counts only reads of the
  # record it changes, so a position set from its neighbours' isn't one.
  @spec derived([tuple()]) :: [derived()]
  def derived(clauses) do
    clauses
    |> bodies()
    |> Macro.prewalk([], fn
      {{:., _, [Ecto.Changeset, name]}, meta, [data, changes | _]} = node, acc
      when name in [:change, :cast] ->
        {node, Enum.reverse(from_changes(changes, data, meta[:line])) ++ acc}

      {{:., _, [Ecto.Changeset, name]}, meta, [_changeset, field, value]} = node, acc
      when name in [:put_change, :force_change] and is_atom(field) ->
        if derived?({field, :any}, value),
          do: {node, [%{line: meta[:line], field: field} | acc]},
          else: {node, acc}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  @doc false
  # Whether the function locks the rows it reads: a query with `lock: "FOR UPDATE"` or the like, or `lock/2,3`.
  @spec locks?([tuple()]) :: boolean()
  def locks?(clauses) do
    clauses
    |> bodies()
    |> Macro.prewalk(false, fn
      {:lock, "FOR " <> _} = node, _found -> {node, true}
      {{:., _, [Ecto.Query.Builder.Lock, _]}, _, _} = node, _found -> {node, true}
      {{:., _, [Ecto.Query, :lock]}, _, _} = node, _found -> {node, true}
      node, found -> {node, found}
    end)
    |> elem(1)
  end

  @doc false
  # For each call, which of the function's parameters flow into which of its arguments: a parameter's variables, and
  # every variable bound from an expression that holds one, as `id = String.to_integer(params["id"])` binds `id`. A
  # flow is `whole` when the argument is the parameter's map itself, or a map inside it, as `params["user"]` is, rather
  # than a value made from it: then `overrides` are the keys the code sets on the way, as
  # `Map.put(params, "user_id", user.id)` sets one. A lower arity that passes its arguments on, as a default argument
  # makes, flows into the full one.
  @spec flows([tuple()], module(), MapSet.t()) :: [flow()]
  def flows(clauses, module, locals) do
    clauses
    |> Enum.flat_map(fn {_meta, args, _guards, body} ->
      params =
        for {arg, position} <- Enum.with_index(args), var <- vars(arg), reduce: %{} do
          acc -> Map.update(acc, var, MapSet.new([position]), &MapSet.put(&1, position))
        end

      bound = patterns(body)
      held = spread(params, bound)
      whole = Map.new(params, fn {var, found} -> {var, Map.new(found, &{&1, MapSet.new()})} end)
      maps = spread_maps(whole, bound)

      body
      |> Macro.prewalk([], fn node, acc ->
        {node, call_flows(node, {held, maps}, module, locals) ++ acc}
      end)
      |> elem(1)
      |> Enum.reverse()
    end)
    |> Enum.uniq()
  end

  @doc false
  # Each field's type, from the `__changeset__/0` an Ecto schema defines.
  @spec fields([tuple()]) :: %{atom() => term()}
  def fields(definitions) do
    for {{:__changeset__, 0}, _kind, _meta, clauses} <- definitions,
        {_meta, _args, _guards, {:%{}, _, pairs}} <- clauses,
        {field, type} when is_atom(field) <- pairs,
        into: %{},
        do: {field, type}
  end

  @doc false
  # The struct fields that default to a float, from `__struct__/0`.
  @spec float_defaults([tuple()]) :: [atom()]
  def float_defaults(definitions) do
    for {{:__struct__, 0}, _kind, _meta, clauses} <- definitions,
        {_meta, _args, _guards, {:%{}, _, pairs}} <- clauses,
        {field, value} when is_atom(field) and is_float(value) <- pairs,
        uniq: true,
        do: field
  end

  defp bodies(clauses), do: Enum.map(clauses, fn {_meta, _args, _guards, body} -> body end)

  # The schema a query lists every row of, or nil when it filters, limits or aggregates, or isn't known.
  defp table(module, _bound, _depth) when is_atom(module) do
    if schema?(module), do: module
  end

  defp table({name, meta, context}, bound, depth)
       when is_atom(name) and is_list(meta) and is_atom(context) and depth < 8 do
    case Map.fetch(bound, var(name, meta, context)) do
      {:ok, query} -> table(query, bound, depth + 1)
      :error -> nil
    end
  end

  defp table({:%{}, _, pairs}, _bound, _depth) do
    if Keyword.get(pairs, :__struct__) == Ecto.Query and Keyword.get(pairs, :wheres) == [] and
         Keyword.get(pairs, :limit) == nil and Keyword.get(pairs, :havings, []) == [] and
         not aggregates?(Keyword.get(pairs, :select)),
       do: source(Keyword.get(pairs, :from))
  end

  defp table({{:., _, [Ecto.Query.Builder.Filter, :apply]}, _, _args}, _bound, _depth), do: nil

  defp table(
         {{:., _, [Ecto.Query.Builder.LimitOffset, :apply]}, _, [query, :offset | _]},
         bound,
         depth
       ),
       do: table(query, bound, depth + 1)

  defp table({{:., _, [Ecto.Query.Builder.LimitOffset, :apply]}, _, _args}, _bound, _depth),
    do: nil

  defp table({{:., _, [builder, :apply]}, _, [query | rest]}, bound, depth)
       when is_atom(builder) do
    if String.starts_with?(Atom.to_string(builder), "Elixir.Ecto.Query.Builder.") and
         not aggregates?(rest),
       do: table(query, bound, depth + 1)
  end

  defp table({{:., _, [Ecto.Query, name]}, _, [query | _]}, bound, depth)
       when name in [:exclude, :preload, :order_by, :distinct, :select_merge],
       do: table(query, bound, depth + 1)

  defp table({{:., _, [Ecto.Queryable, :to_query]}, _, [query]}, bound, depth),
    do: table(query, bound, depth + 1)

  defp table(_query, _bound, _depth), do: nil

  defp source({:%, _, [Ecto.Query.FromExpr, {:%{}, _, pairs}]}) do
    case Keyword.get(pairs, :source) do
      {_source, schema} when is_atom(schema) -> if schema?(schema), do: schema
      _ -> nil
    end
  end

  defp source(_from), do: nil

  defp schema?(module),
    do:
      module not in [nil, true, false] and String.starts_with?(Atom.to_string(module), "Elixir.")

  defp aggregates?(ast) do
    ast
    |> Macro.prewalk(false, fn
      {name, _, args} = node, _found when name in @aggregates and is_list(args) ->
        {node, true}

      # An expression Ecto escaped into the query, as `count(p.id)` in a `select`.
      {:{}, _, [name, _, args]} = node, _found when name in @aggregates and is_list(args) ->
        {node, true}

      node, found ->
        {node, found}
    end)
    |> elem(1)
  end

  # Every `variable = expression` in a body, the last one for each variable.
  defp bindings(body) do
    body
    |> Macro.prewalk(%{}, fn
      {:=, _, [{name, meta, context}, expression]} = node, acc
      when is_atom(name) and is_list(meta) and is_atom(context) ->
        {node, Map.put(acc, var(name, meta, context), expression)}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp from_changes(changes, data, line) do
    pairs =
      case changes do
        list when is_list(list) -> list
        {:%{}, _, pairs} -> pairs
        _ -> []
      end

    record = root(data)

    for {field, value} <- pairs,
        name = field_name(field),
        name != nil and record != nil and derived?({name, record}, value),
        do: %{line: line, field: name}
  end

  defp field_name(field) when is_atom(field), do: field
  defp field_name(field) when is_binary(field), do: String.to_atom(field)
  defp field_name(_field), do: nil

  # The variable a record or changeset is held in, as `post` in `post` or `changeset.data`.
  defp root({name, meta, context}) when is_atom(name) and is_list(meta) and is_atom(context),
    do: var(name, meta, context)

  defp root({{:., _, [base, _field]}, _, []}), do: root(base)
  defp root(_ast), do: nil

  # Whether a value computes a new one from the old value of `field`, read from `record`, or from any record when
  # that's `:any`, as for a `put_change/3` on a changeset made elsewhere.
  defp derived?(target, value) do
    value
    |> Macro.prewalk(false, fn node, found -> {node, found or computes_from?(node, target)} end)
    |> elem(1)
  end

  defp computes_from?({op, _, [_, _] = operands}, target) when op in @operators,
    do: reads?(operands, target)

  defp computes_from?({{:., _, [:erlang, op]}, _, [_, _] = operands}, target)
       when op in @operators,
       do: reads?(operands, target)

  defp computes_from?({{:., _, [Decimal, op]}, _, [_, _ | _] = operands}, target)
       when op in @decimal,
       do: reads?(operands, target)

  defp computes_from?(_node, _target), do: false

  # Whether an expression reads the field from the record, as `post.views` or `changeset.data.views` do.
  defp reads?(ast, {field, record}) do
    ast
    |> Macro.prewalk(false, fn
      {{:., _, [base, ^field]}, meta, []} = node, found ->
        {node, found or (Keyword.get(meta, :no_parens, false) and record in [:any, root(base)])}

      node, found ->
        {node, found}
    end)
    |> elem(1)
  end

  # Every `pattern = expression`, `pattern <- expression` and `case expression do pattern -> ... end` in a body.
  defp patterns(body) do
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

  # The parameters each variable holds a value from, adding every variable a pattern binds from an expression that
  # holds one, until no more are found.
  defp spread(held, patterns) do
    next =
      Enum.reduce(patterns, held, fn {left, right}, acc ->
        case positions(right, acc) do
          [] ->
            acc

          found ->
            found = MapSet.new(found)

            Enum.reduce(vars(left), acc, &add_positions(&2, &1, found))
        end
      end)

    if next == held, do: held, else: spread(next, patterns)
  end

  defp add_positions(held, var, found), do: Map.update(held, var, found, &MapSet.union(&1, found))

  defp positions(ast, held) do
    ast
    |> Macro.prewalk(MapSet.new(), fn
      {name, meta, context} = node, acc
      when is_atom(name) and is_list(meta) and is_atom(context) ->
        {node, MapSet.union(acc, Map.get(held, var(name, meta, context), MapSet.new()))}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.sort()
  end

  defp call_flows(node, {held, maps}, module, locals) do
    case callee(node, module, locals) do
      {target, line, args} ->
        for {arg, to} <- Enum.with_index(args),
            shapes = shape(arg, maps),
            from <- positions(arg, held) do
          overrides = Map.get(shapes, from)

          %{
            from: from,
            target: target,
            to: to,
            line: line,
            whole: overrides != nil,
            overrides: if(overrides, do: Enum.sort(overrides), else: [])
          }
        end

      nil ->
        []
    end
  end

  # The variables holding a parameter's map, or a map inside it, with the keys set on the way.
  defp spread_maps(maps, patterns) do
    next =
      Enum.reduce(patterns, maps, fn {left, right}, acc ->
        case shape(right, acc) do
          found when found == %{} ->
            acc

          found ->
            Enum.reduce(vars(left), acc, &add_shape(&2, &1, bound(left, found)))
        end
      end)

    if next == maps, do: maps, else: spread_maps(next, patterns)
  end

  defp add_shape(maps, var, found), do: Map.update(maps, var, found, &merge_shapes(&1, found))

  # A pattern that takes a map apart binds what's inside, which the keys set on the outside don't touch.
  defp bound({name, meta, context}, found)
       when is_atom(name) and is_list(meta) and is_atom(context), do: found

  defp bound(_pattern, found),
    do: Map.new(found, fn {position, _keys} -> {position, MapSet.new()} end)

  # The parameters whose map an expression is, with the keys set on it: a variable holding one, a map inside one, or
  # one with keys put or merged in. A map the code builds itself, or takes chosen keys from, isn't one: its keys are
  # the code's.
  defp shape({name, meta, context}, maps)
       when is_atom(name) and is_list(meta) and is_atom(context),
       do: Map.get(maps, var(name, meta, context), %{})

  defp shape({{:., _, [Access, :get]}, _, [inner, _key | _]}, maps), do: inside(inner, maps)

  defp shape({{:., _, [Map, name]}, _, [inner | _]}, maps) when name in [:get, :fetch!],
    do: inside(inner, maps)

  defp shape({{:., _, [Map, name]}, _, [inner, key | _]}, maps) when name in [:put, :put_new],
    do: set(shape(inner, maps), [key])

  defp shape({{:., _, [Map, :drop]}, _, [inner, keys]}, maps) when is_list(keys),
    do: set(shape(inner, maps), keys)

  defp shape({{:., _, [Map, :delete]}, _, [inner, key]}, maps), do: set(shape(inner, maps), [key])

  defp shape({{:., _, [Map, name]}, _, [inner | _]}, maps)
       when name in [:drop, :update, :update!, :replace!],
       do: shape(inner, maps)

  # The compiler writes `Map.put/3`, `Map.merge/2` and `Map.delete/2` as `:maps` calls, the map last for `put` and
  # `remove`. Keys the code deletes, as it sets, aren't the client's.
  defp shape({{:., _, [:maps, :put]}, _, [key, _value, inner]}, maps),
    do: set(shape(inner, maps), [key])

  defp shape({{:., _, [:maps, :remove]}, _, [key, inner]}, maps),
    do: set(shape(inner, maps), [key])

  defp shape({{:., _, [module, :merge]}, _, [left, {:%{}, _, pairs}]}, maps)
       when module in [Map, :maps],
       do: set(shape(left, maps), Enum.map(pairs, &elem(&1, 0)))

  defp shape({{:., _, [module, :merge]}, _, [left, right]}, maps) when module in [Map, :maps],
    do: merge_shapes(shape(left, maps), shape(right, maps))

  defp shape({{:., _, [inner, _key]}, meta, []}, maps) do
    if Keyword.get(meta, :no_parens, false), do: inside(inner, maps), else: %{}
  end

  defp shape(_ast, _maps), do: %{}

  defp inside(inner, maps), do: bound(nil, shape(inner, maps))

  defp set(shapes, keys) do
    names = for key <- keys, is_atom(key) or is_binary(key), do: to_string(key)
    Map.new(shapes, fn {position, set} -> {position, MapSet.union(set, MapSet.new(names))} end)
  end

  # Two ways a variable can hold a parameter's map: only keys set on both are sure to be set.
  defp merge_shapes(left, right),
    do: Map.merge(left, right, fn _position, a, b -> MapSet.intersection(a, b) end)

  defp callee({{:., _, [module, name]}, meta, args}, _module, _locals)
       when is_atom(module) and is_atom(name) and is_list(args),
       do: {{module, name, length(args)}, meta[:line], args}

  defp callee({:super, meta, args}, module, _locals) when is_list(args) do
    {_kind, name} = Keyword.fetch!(meta, :super)
    {{module, name, length(args)}, meta[:line], args}
  end

  defp callee({name, meta, args}, module, locals) when is_atom(name) and is_list(args) do
    if MapSet.member?(locals, {name, length(args)}),
      do: {{module, name, length(args)}, meta[:line], args}
  end

  defp callee(_node, _module, _locals), do: nil

  defp vars(ast) do
    ast
    |> Macro.prewalk([], fn
      {name, meta, context} = node, acc
      when is_atom(name) and is_list(meta) and is_atom(context) ->
        if String.starts_with?(Atom.to_string(name), "_"),
          do: {node, acc},
          else: {node, [var(name, meta, context) | acc]}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  # A variable, by its name and the binding the compiler numbered, so `attrs` rebound to a map the code builds isn't
  # the `attrs` it was given.
  defp var(name, meta, context), do: {name, context, Keyword.get(meta, :version)}
end
