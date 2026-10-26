defmodule ArchTest.Code.Data do
  @moduledoc false
  # What a function does with stored data, read from its expanded clauses: the fields it casts from params, the whole
  # tables it lists, the fields it sets from their own old values, and whether it locks the rows it reads. And what a
  # module's fields hold: an Ecto schema's types, from `__changeset__/0`, and a struct's float defaults.

  alias ArchTest.Code

  @type cast :: %{line: pos_integer() | nil, fields: [atom()]}
  @type table :: %{target: Code.key(), line: pos_integer() | nil, schema: module()}
  @type derived :: %{line: pos_integer() | nil, field: atom()}

  # What turns a value into a new one, here an old value of the field it's written back to.
  @operators [:+, :-, :*, :/, :++, :<>, :div, :rem]
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
    case Map.fetch(bound, {name, context}) do
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
        {node, Map.put(acc, {name, context}, expression)}

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
    do: {name, context}

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
end
