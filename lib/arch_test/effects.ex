defmodule ArchTest.Effects do
  @moduledoc """
  Rules about what code does to the outside world: the database, HTTP, the network, files, the console, other
  processes, the operating system, the clock, randomness and the environment.

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
      end

  Each violation names the file and line, the path to the effect, and how to fix it.

  ## What counts

  An effect is a call to a library that touches the outside world, such as `Ecto.Repo.Queryable` (behind every Ecto
  repo), `Req`, `Finch`, `HTTPoison`, `Tesla`, `:httpc`, `File`, `IO.puts/1`, `System.cmd/3`, `GenServer.call/2`,
  `DateTime.utc_now/0`, `:rand` or `System.get_env/1`, or a call to a project function that has one. Building a
  value, as `Req.new/1` or `Ecto.Query.from/2` do, isn't an effect. Calls through a module held in a variable aren't
  followed, since the code doesn't say which module runs.
  """

  alias ArchTest.{Code, ModuleSet}
  alias ArchTest.Code.Effects, as: Reach
  alias ArchTest.Code.Rules

  @queries [:db_read, :http]
  @work [:db_read, :db_write, :http, :network, :file, :system]
  @groups [
    database: [:db_read, :db_write],
    http: [:http],
    network: [:network],
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
               schedule write store persist destroy archive mark set add append push register subscribe)

  @doc false
  defmacro __using__(_opts) do
    quote do
      import ArchTest.Effects
    end
  end

  @doc """
  Asserts that no function in `subject` makes a query once per item: N+1.

  A query reads the database or makes an HTTP request, directly or through the functions it calls, and isn't
  named for a change, as `create_user/1` or `Req.post!/2` are. It counts when it runs once per item of a loop: in a
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
          call.per_item,
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
