defmodule ArchTest.Data do
  @moduledoc """
  Rules about stored data: who may set which fields, what concurrent writes do to them, what type money is stored
  as, and how many rows a request loads.

  ## Usage

      defmodule MyApp.DataTest do
        use ExUnit.Case
        use ArchTest, app: :my_app
        use ArchTest.Data

        test "requests can't set privileged fields" do
          no_mass_assignment(modules_matching("MyAppWeb.**"), app: :my_app, policy: MyApp.Policy)
        end

        test "no lost updates" do
          no_lost_updates(modules_matching("MyApp.**"), app: :my_app)
        end

        test "money isn't a float" do
          no_float_money(modules_matching("MyApp.**"), app: :my_app)
        end

        test "pages don't load whole tables" do
          no_unbounded_queries(modules_matching("MyAppWeb.**"), app: :my_app)
        end
      end

  Like `ArchTest.Effects`, they read the code from the BEAM files' debug info, after macro expansion, and follow
  every call: a controller action reaches the changeset its context builds.
  """

  alias ArchTest.{Code, ModuleSet}
  alias ArchTest.Code.{Authorization, Rules}
  alias ArchTest.Code.Effects, as: Reach

  # Fields that grant access, name an owner, or record a check the server makes: none of them is the user's to set.
  @privileged ~w(role roles admin is_admin superuser is_superuser super_admin staff is_staff permissions privileges
                 owner_id user_id account_id organization_id org_id team_id tenant_id verified email_verified
                 verified_at confirmed confirmed_at approved hashed_password password_hash)a
  # Words that name an amount of money in a field's name, as `total_price` and `shipping_fee` do.
  @money ~w(price prices amount amounts cost costs fee fees balance balances salary salaries tax taxes revenue budget
            payment payments refund refunds payout payouts wage wages money cash earnings income expense expenses
            spend spent subtotal cents)
  # Words that make such a name a ratio or count rather than an amount, as `tax_rate` and `fee_percent` do.
  @not_money ~w(rate rates ratio percent percentage pct factor weight score count multiplier share)
  # Library calls that read one row by its key, which a request names.
  @fetches [:get, :get!, :get_by, :get_by!]

  @doc false
  defmacro __using__(_opts) do
    quote do
      import ArchTest.Data
    end
  end

  @doc """
  Asserts that no endpoint lets a request set a privileged field: "mass assignment".

  Endpoints are controller actions, a LiveView's or LiveComponent's `handle_event/3` and a channel's `handle_in/3`.
  One is flagged when it reaches, directly or through what it calls, an `Ecto.Changeset.cast/3,4` that takes a
  privileged field from the params: one that grants access (`role`, `admin`, `permissions`), names an owner
  (`user_id`, `owner_id`, `account_id`, `organization_id`, `team_id`, `tenant_id`), or records a check the server
  makes (`verified`, `confirmed_at`, `approved`, `hashed_password`). Whoever sends the request can then make
  themselves an admin, or move a record to another account. Passing the current user doesn't help: the user is
  changing their own record.

  The changeset must be saved: a function on the way to the cast writes to the database, or the endpoint does when it
  casts itself or calls the changeset function directly. A changeset built only to show a form's errors, as a
  "validate" event's is, sets nothing.

  An endpoint that a policy checks, as `writes_are_authorized/2` reads one, passes: an admin may set roles. So does
  a change made in a function given to a helper that checks the user first, as
  `with_admin(conn, fn -> Accounts.set_role(user, params) end)` does. Only the params map itself counts, or a map
  inside it, as `params["user"]` is: a map the code builds, as `%{role: role}`, holds the keys the code chose, and
  keys it puts, merges in or drops, as `Map.put(params, "user_id", user.id)` does, are the code's too.

  ## Options

  - `:policy` — modules that check permissions, such as `MyApp.Policy` or a plug like `MyAppWeb.Plugs.RequireAdmin`
  """
  @spec no_mass_assignment(ModuleSet.t(), keyword()) :: :ok
  def no_mass_assignment(%ModuleSet{} = subject, opts \\ []) do
    {configured, policies} = Authorization.policies(opts)
    {modules, code, effects} = Rules.analyze(subject, opts)
    routes = Authorization.routes(code, opts)

    # Only the request's map itself carries keys the client chose, less those the code sets on the way.
    search = %{
      sink: &cast_sink/3,
      extend: fn flow, fields -> if flow.whole, do: nonempty(fields -- atoms(flow.overrides)) end,
      passes?: fn _key, info, flow ->
        flow.whole and
          not MapSet.member?(Authorization.guarded(info, code), {flow.target, flow.line})
      end
    }

    casting = Reach.flowing(code, search)

    violations =
      for module <- modules,
          endpoint <- Authorization.endpoints(code, module, :changes),
          {call, path, fields} <-
            List.wrap(
              Reach.first_flow(
                endpoint,
                code.functions[endpoint],
                Authorization.request_params(endpoint),
                casting,
                search
              )
            ),
          saves?(endpoint, path, effects),
          not Authorization.checked?(code, routes, endpoint, policies) do
        through =
          if path == [],
            do: "",
            else:
              " through #{Rules.name(call.target, module)}#{Rules.reaching(path, call.target, module)},"

        Rules.violation(code, "no_mass_assignment", endpoint,
          line: call.line,
          callee: if(path == [], do: nil, else: call.target),
          message:
            "lets the request set #{list(fields)}#{through} where cast/3 takes it from the params",
          fix:
            "leave #{list(fields)} out of cast/3 and set it with put_change/3 from the current user or scope, or " <>
              "cast it in a changeset that only endpoints checking #{Authorization.policy_names(configured)} use"
        )
      end

    Rules.report(violations, "no_mass_assignment")
  end

  @doc """
  Asserts that no function sets a field from its own old value before writing it: "lost updates".

  `change(post, views: post.views + 1)`, `change(list, %{tags: list.tags ++ [tag]})` and
  `put_change(changeset, :balance, changeset.data.balance - amount)` compute the new value from the one read before.
  Two requests at once both read the same value, and the second write undoes the first. A change is flagged when
  the function, or one that calls it, writes to the database, and neither locks the row: with `Ecto.Changeset.optimistic_lock/3`, or with
  `lock: "FOR UPDATE"` in a query it makes or calls, inside a transaction it, or its caller, opens around the work. A
  lock taken outside a transaction ends with the read that takes it. Change the value
  in the database instead, as `Repo.update_all(query, inc: [views: 1])` does.
  """
  @spec no_lost_updates(ModuleSet.t(), keyword()) :: :ok
  def no_lost_updates(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, effects} = Rules.analyze(subject, opts)
    callers = callers(code)
    locking = Reach.paths(code, fn _key, info -> info.locks end)

    violations =
      for module <- modules,
          {key, info} <- Code.functions_of(code, module),
          not info.injected and info.derived != [],
          around = [key | Map.get(callers, key, [])],
          Enum.any?(around, &Map.has_key?(Map.get(effects, &1, %{}), :db_write)),
          not Enum.any?(around, &optimistic?(code.functions[&1])),
          not (locked?(around, locking) and in_transaction?(key, around, code, effects)),
          change <- Enum.uniq_by(info.derived, & &1.field) do
        why =
          if locked?(around, locking),
            do: ~s(its lock: "FOR UPDATE" ends with the read, since no transaction holds it, so ),
            else: ""

        Rules.violation(code, "no_lost_updates", key,
          line: change.line,
          message:
            "sets #{inspect(change.field)} from its old value: #{why}a request that changes it between the read " <>
              "and this write is lost",
          fix:
            "change it in the database, as Repo.update_all(query, inc: [#{change.field}: 1]) does, or read the " <>
              ~s(row with lock: "FOR UPDATE" in the transaction that writes it, or add optimistic_lock/3)
        )
      end

    Rules.report(violations, "no_lost_updates")
  end

  @doc """
  Asserts that no schema or struct stores money as a float.

  A float can't hold most decimal amounts exactly: `0.1 + 0.2` is `0.30000000000000004`, so sums, comparisons and
  rounding drift by fractions of a cent. Flags an Ecto schema's `:float` field, or a struct field that defaults to a
  float, whose name names an amount of money: `price`, `amount`, `cost`, `fee`, `balance`, `tax`, `revenue`,
  `payment`, `refund`, `cents` and the like. Names that make it a ratio or count, as `tax_rate`, `fee_percent` and
  `price_count` do, pass. Store money as a `:decimal`, or as an `:integer` count of cents.
  """
  @spec no_float_money(ModuleSet.t(), keyword()) :: :ok
  def no_float_money(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, _effects} = Rules.analyze(subject, opts)

    violations =
      for module <- modules,
          info = code.modules[module],
          info != nil,
          {field, how} <- floats(info),
          money?(field) do
        Rules.violation(code, "no_float_money", {module, how, 0},
          line: field_line(code, module, field, how),
          message:
            "stores #{inspect(field)} as a float, which can't hold most decimal amounts exactly, so sums and " <>
              "comparisons drift by fractions of a cent",
          fix: "store it as a :decimal, or as an :integer count of cents"
        )
      end

    Rules.report(violations, "no_float_money")
  end

  @doc """
  Asserts that no endpoint loads every row of a table.

  Endpoints are controller actions, a LiveView's `mount/3`, `handle_params/3` and `handle_event/3`, a
  LiveComponent's `handle_event/3` and a channel's `join/3` and `handle_in/3`. One is flagged when it reaches,
  directly or through what it calls, a repo's `all/1,2` given a schema, or a query with no `where`, `limit`,
  aggregate or join on a pinned value, as `Repo.all(Post)` and `Post |> order_by(:title) |> Repo.all()` are. Each request then loads more as
  the table grows, until pages time out. Paginate the query, or filter it to what the page shows. A query a function
  is given, or one built elsewhere, isn't known, so it isn't counted.
  """
  @spec no_unbounded_queries(ModuleSet.t(), keyword()) :: :ok
  def no_unbounded_queries(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, effects} = Rules.analyze(subject, opts)
    listing = Reach.paths(code, fn _key, info -> whole_table(info, effects) != nil end)

    violations =
      for module <- modules,
          endpoint <- Authorization.endpoints(code, module, :reads),
          {call, path, table} <- List.wrap(listing(code, endpoint, listing, effects)) do
        Rules.violation(code, "no_unbounded_queries", endpoint,
          line: call.line,
          callee: call.target,
          message:
            "loads every row of #{inspect(table.schema)} through #{Rules.name(call.target, module)}" <>
              "#{Rules.reaching(path, call.target, module)}, so each request loads more as the table grows",
          fix:
            "paginate it, as limit and offset or a cursor do, or filter it to what the page shows"
        )
      end

    Rules.report(violations, "no_unbounded_queries")
  end

  @doc false
  # The library calls that read one row by its key, as `Repo.get!/2` makes.
  @spec fetch?(Code.key()) :: boolean()
  def fetch?({Ecto.Repo.Queryable, name, _arity}), do: name in @fetches
  def fetch?(_target), do: false

  # Whether the changeset is saved: a function on the way to the cast writes to the database, or, when the endpoint
  # casts itself or calls the function that does, the endpoint writes. A changeset built only to show a form's errors,
  # as a "validate" event's is, sets nothing.
  defp saves?(endpoint, path, effects) do
    writes? = &Map.has_key?(Map.get(effects, &1, %{}), :db_write)
    reached = Enum.map(path, & &1.target)
    Enum.any?(reached, writes?) or (length(reached) <= 1 and writes?.(endpoint))
  end

  # A cast/3 that takes privileged fields from the map flowing in, but for those the code set on it: the function
  # holding it is where the path ends.
  defp cast_sink(_key, info, %{target: {Ecto.Changeset, :cast, _arity}, to: 1, line: line} = flow) do
    with fields when fields != nil <-
           info.casts
           |> Enum.filter(&(&1.line == line))
           |> privileged()
           |> Kernel.--(atoms(flow.overrides))
           |> nonempty(),
         do: {[], fields}
  end

  defp cast_sink(_key, _info, _flow), do: nil

  defp atoms(keys),
    do: for(key <- keys, field <- @privileged, Atom.to_string(field) == key, do: field)

  defp nonempty([]), do: nil
  defp nonempty(list), do: list

  defp privileged(casts) do
    for cast <- casts, field <- cast.fields, field in @privileged, uniq: true, do: field
  end

  defp list([field]), do: inspect(field)

  defp list(fields) do
    {init, [last]} = Enum.split(fields, -1)
    Enum.map_join(init, ", ", &inspect/1) <> " and " <> inspect(last)
  end

  # Each project function's callers.
  defp callers(code) do
    for {caller, info} <- code.functions,
        %{target: target} <- info.calls,
        target != caller and Map.has_key?(code.functions, target),
        reduce: %{} do
      acc -> Map.update(acc, target, [caller], &[caller | &1])
    end
  end

  defp locked?(around, locking), do: Enum.any?(around, &Map.has_key?(locking, &1))

  # Whether the function's work runs in a transaction: one it opens, or gives its work to a helper that opens, as
  # `with_locked(query, fn row -> ... end)` does, or one its caller opens around the call the same ways.
  defp in_transaction?(key, around, code, effects) do
    Enum.any?(around, fn function ->
      info = code.functions[function]

      Enum.any?(
        info.calls,
        &((function == key or &1.target == key) and opened_by_transaction?(&1, code, effects))
      ) or
        Enum.any?(info.actors.callbacks, fn {{helper, _line}, calls} ->
          (function == key or Enum.any?(calls, &(elem(&1, 0) == key))) and
            transaction_helper?(helper, MapSet.new([function]), code, effects)
        end)
    end)
  end

  # A function that opens a transaction, as `Repo.transaction(fn -> fun.(row) end)` does, and so runs the function it's
  # given inside it, or gives its own to one that does.
  defp transaction_helper?(key, seen, code, effects) do
    case code.functions[key] do
      nil ->
        false

      info ->
        Enum.any?(info.calls, &opened_by_transaction?(&1, code, effects)) or
          Enum.any?(info.actors.callbacks, fn {{helper, _line}, _calls} ->
            not MapSet.member?(seen, helper) and
              transaction_helper?(helper, MapSet.put(seen, key), code, effects)
          end)
    end
  end

  defp opened_by_transaction?(%{inside: %{target: opener}}, code, effects),
    do: Rules.transaction?(opener, code, effects)

  defp opened_by_transaction?(_call, _code, _effects), do: false

  defp optimistic?(info),
    do: Enum.any?(info.calls, &match?(%{target: {Ecto.Changeset, :optimistic_lock, _}}, &1))

  # A schema's float fields, and a struct's fields that default to a float, sorted by name.
  defp floats(info) do
    schema = for {field, :float} <- Map.get(info, :fields, %{}), do: {field, :__changeset__}

    struct =
      for field <- Map.get(info, :float_defaults, []),
          not Map.has_key?(info.fields, field),
          do: {field, :__struct__}

    Enum.sort(schema ++ struct)
  end

  defp money?(field) do
    words = field |> Atom.to_string() |> String.split("_")
    Enum.any?(words, &(&1 in @money)) and not Enum.any?(words, &(&1 in @not_money))
  end

  # The line that declares a field: `field :price, :float` in a schema, `price: 0.0` in a `defstruct`, or the line of
  # the schema or struct when the source can't be read.
  defp field_line(code, module, field, how) do
    pattern =
      case how do
        :__changeset__ -> ~r/\bfield[\s(]+:#{field}\b/
        :__struct__ -> ~r/\b#{field}:\s*-?[0-9]/
      end

    with file when is_binary(file) <- Code.file(code, module),
         {:ok, text} <- File.read(file),
         index when is_integer(index) <-
           text |> String.split("\n") |> Enum.find_index(&Regex.match?(pattern, &1)) do
      index + 1
    else
      _ -> get_in(code.functions, [{module, how, 0}, :line])
    end
  end

  # A repo's `all/1,2` a function gives a whole table, if it makes one.
  defp whole_table(info, effects),
    do: Enum.find(info.whole_tables, &Rules.kind(&1.target, [:db_read], effects))

  # The first whole table an endpoint lists, itself or through what it calls, with the call that leads there and the
  # path from it to the repo call.
  defp listing(code, endpoint, listing, effects) do
    info = code.functions[endpoint]

    case whole_table(info, effects) do
      %{} = table ->
        step = %{target: table.target, line: table.line}
        {step, [step], table}

      nil ->
        with {call, path} <- Reach.first_path(info.calls, listing) do
          table = whole_table(code.functions[List.last(path).target], effects)
          {call, path ++ [%{target: table.target, line: table.line}], table}
        end
    end
  end
end
