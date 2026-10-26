defmodule ArchTest.Effects do
  @moduledoc """
  Rules about what code does to the outside world: the database, HTTP, the network, mail, published messages, files,
  the console, other processes, the operating system, the clock, randomness and the environment.

  They follow every call, not only the ones written in a function: `Orders.with_users/1` calling
  `Accounts.get_user!/1` once per order queries the database once per order, though no `Repo` call appears in it.
  They read the code from the BEAM files' debug info, after macro expansion, so aliases, imports and `use` are
  resolved.

  ## Usage

      defmodule MyApp.EffectsTest do
        use ExUnit.Case
        use ArchTest, app: :my_app
        use ArchTest.Effects

        test "no N+1 queries" do
          no_queries_in_loops(modules_matching("MyApp.**"), app: :my_app)
        end

        test "the pricing core is pure" do
          should_be_free_of_side_effects(modules_matching("MyApp.Pricing.**"), app: :my_app)
        end

        test "GenServers start fast" do
          no_work_in_init(modules_matching("MyApp.**"), app: :my_app)
        end

        test "transactions stay in the database" do
          no_io_in_transactions(modules_matching("MyApp.**"), app: :my_app)
        end

        test "writes are authorized" do
          writes_are_authorized(modules_matching("MyAppWeb.**"), app: :my_app, policy: MyApp.Policy)
        end

        test "private records are read by their owners" do
          reads_are_authorized(modules_matching("MyAppWeb.Account.**"), app: :my_app, policy: MyApp.Policy)
        end
      end

  Each violation names the file and line, the path to the effect, and how to fix it.

  ## What counts

  An effect is a call to a library that touches the outside world, such as `Ecto.Repo.Queryable` (behind every Ecto
  repo), `Req`, `Finch`, `HTTPoison`, `Tesla`, `:httpc`, `Swoosh.Mailer`, `Phoenix.PubSub.broadcast/3`, `File`,
  `IO.puts/1`, `System.cmd/3`, `GenServer.call/2`,
  `DateTime.utc_now/0`, `:rand` or `System.get_env/1`, or a call to a project function that has one. Building a
  value, as `Req.new/1` or `Ecto.Query.from/2` do, isn't an effect. Calls through a module held in a variable aren't
  followed, since the code doesn't say which module runs.
  """

  alias ArchTest.{Code, ModuleSet}
  alias ArchTest.Code.{Authorization, Rules}
  alias ArchTest.Code.Effects, as: Reach

  @queries [:db_read, :http]
  @work [:db_read, :db_write, :http, :network, :mail, :file, :system]
  # What a rollback can't undo, and what a transaction shouldn't wait on.
  @outside [:http, :network, :mail, :publish]
  @outside_verbs %{
    http: "makes an HTTP request",
    network: "uses the network",
    mail: "sends email",
    publish: "publishes a message"
  }
  @groups [
    database: [:db_read, :db_write],
    http: [:http],
    network: [:network],
    mail: [:mail],
    publish: [:publish],
    file: [:file],
    console: [:console],
    system: [:system],
    process: [:process],
    clock: [:clock],
    random: [:random],
    env: [:env]
  ]
  @verbs %{
    db_read: "touches the database",
    db_write: "touches the database",
    http: "makes HTTP requests",
    network: "uses the network",
    mail: "sends email",
    publish: "publishes messages",
    file: "touches files",
    console: "writes to the console",
    system: "runs operating-system commands",
    process: "talks to other processes",
    clock: "reads the clock",
    random: "uses randomness",
    env: "reads the environment"
  }
  # Names of functions that change something rather than read it, such as `create_user/1` or `Req.post!/2`.
  @commands ~w(create insert update delete save put upsert remove send post patch publish broadcast notify enqueue
               schedule write store persist destroy archive mark set add append push register subscribe copy purge)

  @doc false
  defmacro __using__(_opts) do
    quote do
      import ArchTest.Effects
    end
  end

  @doc """
  Asserts that no function in `subject` makes a query once per item: N+1.

  A query reads the database or makes an HTTP request, directly or through the functions it calls, and isn't
  named for a change, as `create_user/1` or `Req.post!/2` are, nor runs raw SQL that writes, as
  `Repo.query!("UPDATE ...", params)` does. It counts when it runs once per item of a loop: in a
  function given to `Enum`, `Stream` or `Task.async_stream`, captured into one, as in
  `Enum.map(ids, &Accounts.get_user!/1)`, or in the body of a `for`, and is given the item or a value made from it.

  One query per item turns a page of 50 orders into 51 round trips. Load what the loop needs with one query before
  it instead.
  """
  @spec no_queries_in_loops(ModuleSet.t(), keyword()) :: :ok
  def no_queries_in_loops(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, effects} = Rules.analyze(subject, opts)

    violations =
      for module <- modules,
          {{^module, name, arity}, info} <- Code.functions_of(code, module),
          call <- info.calls,
          call.per_item and not call.writes_sql,
          {kind, path} <- List.wrap(query(call.target, effects)) do
        phrase = if kind == :http, do: "makes an HTTP request", else: "queries the database"
        reaching = Rules.reaching([Rules.step(call) | path], call.target, module)

        Rules.violation(code, "no_queries_in_loops", {module, name, arity},
          line: call.line,
          callee: call.target,
          message:
            "#{phrase} once per item: #{call.loop} calls #{Rules.name(call.target, module)}#{reaching}",
          fix: query_fix(kind)
        )
      end

    Rules.report(violations, "no_queries_in_loops")
  end

  @doc """
  Asserts that functions in `subject`, a functional core, have no side effects.

  Each call that leaves the core and touches the outside world is reported once per function and kind of effect,
  where the call is made: a call to a library such as `DateTime.utc_now/0`, or to a project function outside
  `subject` that has the effect. Calls between functions of `subject` aren't reported, since the call that leaves
  the core already is.

  ## Options

  - `:allow` — effects the core may have, from `:database`, `:http`, `:network`, `:file`, `:console`, `:system`,
    `:process`, `:clock`, `:random` and `:env`
  """
  @spec should_be_free_of_side_effects(ModuleSet.t(), keyword()) :: :ok
  def should_be_free_of_side_effects(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, effects} = Rules.analyze(subject, opts)
    allowed = opts |> Keyword.get(:allow, []) |> Enum.flat_map(&Keyword.fetch!(@groups, &1))
    core = MapSet.new(modules)

    violations =
      for module <- modules,
          {{^module, name, arity}, info} <- Code.functions_of(code, module),
          {_group, kinds} <- @groups,
          {call, path} <- List.wrap(leaving(info.calls, kinds -- allowed, core, effects)) do
        kind = Rules.kind(call.target, kinds, effects)
        reaching = Rules.reaching(path, call.target, module)

        Rules.violation(code, "should_be_free_of_side_effects", {module, name, arity},
          line: call.line,
          callee: call.target,
          message: "#{@verbs[kind]} through #{Rules.name(call.target, module)}#{reaching}",
          fix:
            "move the call out to the code that uses the functional core, and pass its result in as an argument"
        )
      end

    Rules.report(violations, "should_be_free_of_side_effects")
  end

  @doc """
  Asserts that no function in `subject` reaches outside the database inside a transaction.

  Inside a function given to a repo's `transaction/1,2` or `transact/1,2`, or to `Ecto.Multi.run`, a call that
  makes an HTTP request, uses the network, sends email or publishes a message, directly or through the functions it
  calls, is flagged. The transaction holds its database connection while it waits, which can drain the pool, and a
  rollback can't undo what went out. Do it after the commit, or record it in the transaction, as an outbox row or an
  Oban job, and do it after.
  """
  @spec no_io_in_transactions(ModuleSet.t(), keyword()) :: :ok
  def no_io_in_transactions(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, effects} = Rules.analyze(subject, opts)

    violations =
      for module <- modules,
          {{^module, name, arity}, info} <- Code.functions_of(code, module),
          %{inside: %{} = opener} = call <- info.calls,
          Rules.transaction?(opener.target, code, effects),
          {call, path} <- List.wrap(first_effect([call], @outside, effects)) do
        kind = Rules.kind(call.target, @outside, effects)

        Rules.violation(code, "no_io_in_transactions", {module, name, arity},
          line: call.line,
          callee: call.target,
          message:
            "#{@outside_verbs[kind]} inside #{Rules.name(opener.target, module)} through " <>
              "#{Rules.name(call.target, module)}#{Rules.reaching(path, call.target, module)}: " <>
              "the transaction holds its database connection while it waits, and a rollback can't undo it",
          fix:
            "do it after the transaction commits, or record it in the transaction, as an outbox row or an " <>
              "Oban job, and do it after the commit"
        )
      end

    Rules.report(violations, "no_io_in_transactions")
  end

  @doc """
  Asserts that every endpoint in `subject` that writes to the database checks who's asking.

  Endpoints are controller actions, a LiveView's or LiveComponent's `handle_event/3` and a channel's `handle_in/3`.
  One that writes, directly or through the functions it calls, passes when:

  - it gives the user asking to the call that writes: the current user or scope, as `conn.assigns.current_user`,
    `socket.assigns.current_scope`, `Guardian.Plug.current_resource(conn)` or a value made from them, for the code
    it calls to scope the change to;
  - the write runs in a function it gives to a helper that reads the user first, as
    `with_own_post(conn, id, fn post -> ... end)` checking the post's owner does;
  - it's a LiveView event that writes to a record the socket's assigns hold, as `socket.assigns.post`, and the
    LiveView's `mount/3` or `handle_params/3` loads records for the user asking, or the LiveComponent's `update/2`
    is given the user by its parent;
  - it, one of its controller's plugs, every router pipeline to it, or every `live_session` `on_mount` hook to its
    LiveView, calls a policy: `Bodyguard`, `Canada`, or a module given as `policy:`;
  - or every route to it is a GET or HEAD: a request to read, so what it writes is bookkeeping, as a cache or a
    view count is.

  Otherwise anyone who can reach the endpoint can change any record whose id they send.

  ## Options

  - `:policy` — modules that check permissions, such as `MyApp.Policy` or a plug like `MyAppWeb.Plugs.RequireAdmin`
  """
  @spec writes_are_authorized(ModuleSet.t(), keyword()) :: :ok
  def writes_are_authorized(%ModuleSet{} = subject, opts \\ []) do
    {configured, policies} = Authorization.policies(opts)
    {modules, code, effects} = Rules.analyze(subject, opts)
    routes = Authorization.routes(code, opts)
    writes = &first_effect(&1, [:db_write], effects)

    violations =
      for module <- modules,
          endpoint <- Authorization.endpoints(code, module, :changes),
          not Authorization.reads_only?(routes, endpoint),
          not Authorization.checked?(code, routes, endpoint, policies),
          {call, path} <- List.wrap(Authorization.unchecked(code, endpoint, writes)) do
        Rules.violation(code, "writes_are_authorized", endpoint,
          line: call.line,
          callee: call.target,
          message:
            "writes to the database through #{Rules.name(call.target, module)}" <>
              "#{Rules.reaching(path, call.target, module)}: nothing checks that the user asking may make this change",
          fix:
            "pass the current user or scope to the code that writes, and scope the change to it, or check " <>
              "#{Authorization.policy_names(configured)} first"
        )
      end

    Rules.report(violations, "writes_are_authorized")
  end

  @doc """
  Asserts that every endpoint in `subject` that reads a record by its id checks who's asking.

  Endpoints are those `writes_are_authorized/2` checks, and a LiveView's `mount/3` and `handle_params/3` and a
  channel's `join/3`, which load what a page or channel shows. One is flagged when it reads a row by the key the
  request names, with a repo's `get/2,3`, `get!/2,3`, `get_by/2,3` or `get_by!/2,3`, directly or through what it
  calls, and nothing ties the read to the user asking: it passes on the terms `writes_are_authorized/2` does, except
  that a GET route is a read like any other. Otherwise anyone can read any record by changing the id in the URL.

  Many records are public by design, such as published posts or packages, so this rule isn't in
  `ArchTest.Recommended`: point it at the endpoints that show private data.

  ## Options

  - `:policy` — modules that check permissions, such as `MyApp.Policy` or a plug like `MyAppWeb.Plugs.RequireAdmin`
  """
  @spec reads_are_authorized(ModuleSet.t(), keyword()) :: :ok
  def reads_are_authorized(%ModuleSet{} = subject, opts \\ []) do
    {configured, policies} = Authorization.policies(opts)
    {modules, code, _effects} = Rules.analyze(subject, opts)
    routes = Authorization.routes(code, opts)

    # A call made on behalf of the user asking is scoped to them, and a helper that reads the user checks what it
    # loads, as one that loads an organization and then checks the user's role in it does.
    unchecked = fn key, info, flow ->
      not MapSet.member?(Authorization.on_behalf(key, info, code), {flow.target, flow.line})
    end

    search = %{
      sink: &fetch_sink/3,
      extend: fn _flow, carried -> carried end,
      passes?: fn key, info, flow ->
        not info.actors.reads_user and unchecked.(key, info, flow)
      end
    }

    fetching = Reach.flowing(code, search)

    violations =
      for module <- modules,
          endpoint <- Authorization.endpoints(code, module, :reads),
          not Authorization.checked?(code, routes, endpoint, policies),
          {call, path, _carried} <-
            List.wrap(
              Reach.first_flow(
                endpoint,
                code.functions[endpoint],
                Authorization.request_params(endpoint),
                fetching,
                %{search | passes?: unchecked}
              )
            ) do
        Rules.violation(code, "reads_are_authorized", endpoint,
          line: call.line,
          callee: call.target,
          message:
            "reads a record by its id through #{Rules.name(call.target, module)}" <>
              "#{Rules.reaching(path, call.target, module)}: nothing checks that the user asking may see it",
          fix:
            "pass the current user or scope to the code that reads, and scope the query to it, or check " <>
              "#{Authorization.policy_names(configured)} first"
        )
      end

    Rules.report(violations, "reads_are_authorized")
  end

  # A repo call that reads one row by the key flowing in, as the id `Repo.get!/2` hands `Ecto.Repo.Queryable.get!/4`.
  defp fetch_sink(_key, _info, flow),
    do: if(ArchTest.Data.fetch?(flow.target) and flow.to == 2, do: {[Rules.step(flow)], true})

  @doc """
  Asserts that no GenServer in `subject` does I/O in `init/1`.

  I/O is the database, HTTP, the network, files or the operating system, directly or through the functions
  `init/1` calls. A supervisor starts its children one at a time and waits for each `init/1`, so slow or failing
  work there delays or stops the whole application. Return `{:ok, state, {:continue, term}}` and do the work in
  `handle_continue/2` instead. Starting processes, scheduling messages and reading configuration aren't I/O.
  """
  @spec no_work_in_init(ModuleSet.t(), keyword()) :: :ok
  def no_work_in_init(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, effects} = Rules.analyze(subject, opts)

    violations =
      for module <- modules,
          GenServer in Code.behaviours(code, module),
          {{^module, :init, 1}, info} <- Code.functions_of(code, module),
          {call, path} <- List.wrap(first_effect(info.calls, @work, effects)) do
        kind = Rules.kind(call.target, @work, effects)

        Rules.violation(code, "no_work_in_init", {module, :init, 1},
          line: call.line,
          callee: call.target,
          message:
            "#{@verbs[kind]} during init/1 through #{Rules.name(call.target, module)}" <>
              "#{Rules.reaching(path, call.target, module)}, so its supervisor waits until the work is done",
          fix:
            "return {:ok, state, {:continue, :load}} from init/1, and do the work in handle_continue/2"
        )
      end

    Rules.report(violations, "no_work_in_init")
  end

  # A query the target makes, with the path to it: the target itself, or what it reaches.
  defp query(target, effects) do
    cond do
      command?(target) -> nil
      Reach.seed(target) in @queries -> {Reach.seed(target), []}
      Reach.seed(target) != nil -> nil
      true -> Enum.find_value(@queries, &with_path(&1, effects[target]))
    end
  end

  defp with_path(kind, effects) do
    case effects do
      %{^kind => path} -> {kind, path}
      _ -> nil
    end
  end

  defp command?({_module, name, _arity}) do
    name = Atom.to_string(name)

    Enum.any?(
      @commands,
      &(name == &1 or String.starts_with?(name, [&1 <> "_", &1 <> "!", &1 <> "?"]))
    )
  end

  # The first call with one of `kinds` that leaves the core: to a seed, or to a function outside it.
  defp leaving(calls, kinds, core, effects) do
    calls
    |> Enum.reject(fn %{target: {module, _, _}} -> MapSet.member?(core, module) end)
    |> first_effect(kinds, effects)
  end

  defp first_effect(calls, kinds, effects) do
    calls
    |> Enum.sort_by(& &1.line)
    |> Enum.find_value(fn call ->
      cond do
        Reach.seed(call.target) in kinds ->
          {call, [Rules.step(call)]}

        kind = Enum.find(kinds, &Map.has_key?(effects[call.target] || %{}, &1)) ->
          {call, [Rules.step(call) | effects[call.target][kind]]}

        true ->
          nil
      end
    end)
  end

  defp query_fix(:http),
    do:
      "fetch what the loop needs with one request before it, such as an endpoint that takes all the ids"

  defp query_fix(_database),
    do:
      "load what the loop needs with one query before it, such as Repo.all with `where: x.id in ^ids`, or Repo.preload"
end
