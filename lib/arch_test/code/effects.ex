defmodule ArchTest.Code.Effects do
  @moduledoc false
  # What each function does to the outside world, directly or through the functions it calls. A seed is a library
  # call that touches it, such as `Ecto.Repo.Queryable.all/3`, `Req.get!/2` or `DateTime.utc_now/0`; a function has
  # an effect when one of its calls is a seed, or a project function with that effect. Each effect comes with the
  # shortest path to its seed, found breadth-first from the seeds, so a report names the same path on every run.

  alias ArchTest.Code

  @type kind ::
          :db_read
          | :db_write
          | :http
          | :network
          | :mail
          | :publish
          | :file
          | :console
          | :system
          | :process
          | :clock
          | :random
          | :env
  @type step :: %{target: Code.key(), line: pos_integer() | nil}
  @type effects :: %{Code.key() => %{kind() => [step()]}}

  @kinds [
    :db_read,
    :db_write,
    :http,
    :network,
    :mail,
    :publish,
    :file,
    :console,
    :system,
    :process,
    :clock,
    :random,
    :env
  ]

  # Libraries whose every function is a seed of one kind.
  @module_seeds %{
    Ecto.Repo.Queryable => :db_read,
    Ecto.Repo.Preloader => :db_read,
    Ecto.Repo.Schema => :db_write,
    Ecto.Repo.Transaction => :db_write,
    Ecto.Adapters.SQL => :db_read,
    Postgrex => :db_read,
    MyXQL => :db_read,
    Exqlite.Sqlite3 => :db_read,
    Redix => :db_read,
    Mongo => :db_read,
    Xandra => :db_read,
    :epgsql => :db_read,
    :httpc => :http,
    :hackney => :http,
    :gun => :http,
    :gen_tcp => :network,
    :gen_udp => :network,
    File => :file,
    :file => :file,
    :filelib => :file,
    :rand => :random,
    :random => :random,
    Agent => :process,
    Task.Supervisor => :process,
    DynamicSupervisor => :process,
    Registry => :process,
    :ets => :process,
    :persistent_term => :process,
    :global => :process,
    :pg => :process,
    Port => :system,
    :gen_smtp_client => :mail
  }

  # Seeds that are only some of a library's functions: the rest build values, as `Req.new/1` does.
  @function_seeds %{
    Ecto.Repo.Queryable => %{delete_all: :db_write, update_all: :db_write},
    # `in_transaction?/1` asks the process, not the database.
    Ecto.Repo.Transaction => {~w(transaction transact rollback)a, :db_write},
    Req =>
      {~w(request request! get get! post post! put put! patch patch! delete delete! head head! run run!)a,
       :http},
    Finch => {~w(request request! stream stream_while async_request)a, :http},
    HTTPoison =>
      {~w(request request! get get! post post! put put! patch patch! delete delete! head head! options options!)a,
       :http},
    HTTPoison.Base => {~w(request)a, :http},
    Tesla =>
      {~w(request request! get get! post post! put put! patch patch! delete delete! head head! options options! execute run)a,
       :http},
    Mint.HTTP => {~w(connect request)a, :http},
    Mint.HTTP1 => {~w(connect request)a, :http},
    Mint.HTTP2 => {~w(connect request)a, :http},
    :inet => {~w(getaddr getaddrs gethostbyname)a, :network},
    # Starting the ssl application isn't I/O; connecting and talking are.
    :ssl => {~w(connect send recv handshake listen transport_accept close shutdown)a, :network},
    Path => {~w(wildcard)a, :file},
    IO => {~w(puts write inspect warn binwrite gets read getn binread)a, :console},
    :io => {~w(format fwrite put_chars write nl read get_line get_chars)a, :console},
    System => %{
      cmd: :system,
      shell: :system,
      halt: :system,
      stop: :system,
      restart: :system,
      system_time: :clock,
      os_time: :clock,
      monotonic_time: :clock,
      get_env: :env,
      fetch_env: :env,
      fetch_env!: :env,
      argv: :env
    },
    :os => %{
      cmd: :system,
      timestamp: :clock,
      system_time: :clock,
      perf_counter: :clock,
      getenv: :env
    },
    :erlang => %{
      open_port: :system,
      halt: :system,
      send: :process,
      spawn: :process,
      spawn_link: :process,
      spawn_monitor: :process,
      spawn_opt: :process,
      register: :process,
      unregister: :process,
      # What Process.monitor/1, Process.link/1 and their opposites compile to.
      monitor: :process,
      demonitor: :process,
      link: :process,
      unlink: :process,
      put: :process,
      # What Process.send_after/3 compiles to, and timers, which schedule work for the process.
      send_after: :process,
      start_timer: :process,
      # Registrations that make the runtime send the process events.
      system_monitor: :process,
      trace: :process,
      monitor_node: :process,
      system_time: :clock,
      monotonic_time: :clock,
      timestamp: :clock,
      now: :clock,
      universaltime: :clock,
      localtime: :clock
    },
    :net_kernel => %{monitor_nodes: :process},
    GenServer => {~w(call cast multi_call abcast start start_link stop reply)a, :process},
    Supervisor =>
      {~w(start_link start_child terminate_child restart_child delete_child)a, :process},
    Task =>
      {~w(async start start_link await await_many yield yield_many async_stream)a, :process},
    Process =>
      {~w(send send_after sleep register unregister exit monitor link spawn put flag)a, :process},
    :timer => %{
      sleep: :process,
      send_after: :process,
      send_interval: :process,
      apply_after: :process,
      tc: :clock
    },
    Phoenix.PubSub => %{
      broadcast: :publish,
      broadcast!: :publish,
      broadcast_from: :publish,
      broadcast_from!: :publish,
      local_broadcast: :publish,
      local_broadcast_from: :publish,
      direct_broadcast: :publish,
      direct_broadcast!: :publish,
      subscribe: :process,
      unsubscribe: :process
    },
    # What an endpoint's broadcast/3 and a channel's broadcast!/3 call.
    Phoenix.Channel.Server =>
      {~w(broadcast broadcast! broadcast_from broadcast_from! local_broadcast local_broadcast_from)a,
       :publish},
    Swoosh.Mailer => {~w(deliver deliver! deliver_many)a, :mail},
    Bamboo.Mailer => {~w(deliver_now deliver_now! deliver_later deliver_later!)a, :mail},
    AMQP.Basic => {~w(publish)a, :publish},
    :brod => {~w(produce produce_sync produce_sync_offset)a, :publish},
    KafkaEx => {~w(produce)a, :publish},
    DateTime => {~w(utc_now now now!)a, :clock},
    NaiveDateTime => {~w(utc_now local_now)a, :clock},
    Date => {~w(utc_today)a, :clock},
    Time => {~w(utc_now)a, :clock},
    :calendar => {~w(local_time universal_time)a, :clock},
    :crypto => {~w(strong_rand_bytes rand_uniform rand_seed)a, :random},
    Enum => {~w(random shuffle take_random)a, :random},
    Ecto.UUID => {~w(generate bingenerate autogenerate)a, :random},
    UUID => {~w(uuid1 uuid4)a, :random},
    Application => {~w(get_env fetch_env fetch_env! get_all_env)a, :env},
    :application => {~w(get_env)a, :env},
    :init => {~w(get_argument)a, :env}
  }

  @doc false
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc false
  # The kind of outside world `target` touches, if it is a seed.
  @spec seed(Code.key()) :: kind() | nil
  def seed({module, name, _arity}) do
    case Map.get(@function_seeds, module) do
      %{^name => kind} -> kind
      {names, kind} -> if name in names, do: kind
      _ -> Map.get(@module_seeds, module)
    end
  end

  @doc false
  @spec of(Code.t()) :: effects()
  def of(%Code{functions: functions}) do
    keys = functions |> Map.keys() |> Enum.sort()
    callers = callers(keys, functions)

    Enum.reduce(@kinds, %{}, fn kind, effects ->
      start =
        for key <- keys,
            path <- [direct(functions[key], kind, effects)],
            path != nil,
            do: {key, path}

      effects = Enum.reduce(start, effects, fn {key, path}, acc -> put(acc, key, kind, path) end)
      spread(Enum.map(start, &elem(&1, 0)), kind, callers, effects)
    end)
  end

  @doc false
  # Every function that `found?` holds for, or that calls one through project functions, with the shortest path
  # there: the calls that lead to it, empty for the function itself.
  @spec paths(Code.t(), (Code.key(), Code.function_info() -> boolean())) :: %{
          Code.key() => [step()]
        }
  def paths(%Code{functions: functions}, found?) do
    keys = functions |> Map.keys() |> Enum.sort()
    start = Enum.filter(keys, &found?.(&1, functions[&1]))
    found = Map.new(start, &{&1, %{found: []}})

    start
    |> spread(:found, callers(keys, functions), found)
    |> Map.new(fn {key, %{found: path}} -> {key, path} end)
  end

  @doc false
  # Which parameters of each function flow into a sink, as an id given to `Repo.get!/2` does, through the calls it
  # makes with them, until no more are found. Each comes with the path from the function's call there, and what the
  # flow carries. A search's `sink` takes a function, its info and one of its flows, and returns `{path, carried}`
  # when the flow ends in a sink; `extend` takes a flow into a function found before and what that one carries, and
  # returns what the flow carries, or nil when nothing reaches the sink that way; flows `passes?` rejects don't count.
  @type search :: %{
          sink: (Code.key(), Code.function_info(), map() -> {[step()], term()} | nil),
          extend: (map(), term() -> term() | nil),
          passes?: (Code.key(), Code.function_info(), map() -> boolean())
        }
  @spec flowing(Code.t(), search()) :: %{Code.key() => %{non_neg_integer() => {[step()], term()}}}
  def flowing(%Code{functions: functions}, search) do
    keys = functions |> Map.keys() |> Enum.sort()
    flowing(keys, functions, search, %{})
  end

  defp flowing(keys, functions, search, found) do
    next =
      Enum.reduce(keys, found, fn key, acc ->
        info = functions[key]

        info.flows
        |> Enum.sort_by(& &1.line)
        |> Enum.reduce(acc, &found_flow(key, info, &1, &2, search))
      end)

    if next == found, do: found, else: flowing(keys, functions, search, next)
  end

  defp found_flow(key, info, flow, found, search) do
    with false <- Map.has_key?(Map.get(found, key, %{}), flow.from),
         {path, carried} <- reaches(key, info, flow, found, search) do
      Map.update(
        found,
        key,
        %{flow.from => {path, carried}},
        &Map.put(&1, flow.from, {path, carried})
      )
    else
      _ -> found
    end
  end

  defp reaches(key, info, flow, found, search) do
    with true <- search.passes?.(key, info, flow) do
      search.sink.(key, info, flow) || through(found, flow, search)
    end
  end

  defp through(found, flow, search) do
    with {path, carried} <- get_in(found, [flow.target, flow.to]),
         carried when carried != nil <- search.extend.(flow, carried) do
      {[step(flow) | path], carried}
    end
  end

  @doc false
  # The first of a function's flows, by line, from one of `positions` into a sink, or into a function `found` says
  # leads to one: the call, the path from it, and what the flow carries.
  @spec first_flow(Code.key(), Code.function_info(), [non_neg_integer()], map(), search()) ::
          {step(), [step()], term()} | nil
  def first_flow(key, info, positions, found, search) do
    info.flows
    |> Enum.sort_by(& &1.line)
    |> Enum.find_value(fn flow ->
      with true <- flow.from in positions,
           {path, carried} <- reaches(key, info, flow, found, search) do
        {step(flow), path, carried}
      else
        _ -> nil
      end
    end)
  end

  @doc false
  # The first of `calls`, by line, to a function in `paths`, with the path from that call to what it leads to.
  @spec first_path([Code.call()], %{Code.key() => [step()]}) :: {Code.call(), [step()]} | nil
  def first_path(calls, paths) do
    calls
    |> Enum.sort_by(& &1.line)
    |> Enum.find_value(fn call ->
      case Map.fetch(paths, call.target) do
        {:ok, path} -> {call, [step(call) | path]}
        :error -> nil
      end
    end)
  end

  @doc false
  # The function a path is reported as reaching: its seed, or, when the seed is the inside of a library that projects
  # reach through a module of their own, such as an Ecto repo, the first of that module's functions on the path.
  @spec reached([step()]) :: Code.key()
  def reached(path) do
    [seed | before] = path |> Enum.map(& &1.target) |> Enum.reverse()

    case {internal?(seed), before} do
      {true, [{module, _, _} = last | rest]} ->
        rest |> Enum.take_while(&(elem(&1, 0) == module)) |> List.last() || last

      _ ->
        seed
    end
  end

  defp internal?({module, _name, _arity}),
    do:
      module in [Ecto.Adapters.SQL] or
        String.starts_with?(Atom.to_string(module), "Elixir.Ecto.Repo.")

  # A function's own effect of `kind`, with its path: its first call that's a seed of it. Raw SQL that writes, as
  # `Repo.query!("UPDATE ...", params)` runs, is a write wherever it leads, since database reads are found first.
  defp direct(info, kind, effects) do
    info.calls
    |> Enum.sort_by(& &1.line)
    |> Enum.find_value(&direct_path(&1, kind, effects))
  end

  defp direct_path(%{writes_sql: true}, :db_read, _effects), do: nil

  defp direct_path(%{writes_sql: true} = call, :db_write, effects) do
    cond do
      seed(call.target) in [:db_read, :db_write] -> [step(call)]
      path = effects[call.target][:db_read] -> [step(call) | path]
      true -> nil
    end
  end

  defp direct_path(call, kind, _effects), do: if(seed(call.target) == kind, do: [step(call)])

  # Each project function's callers, in the order of their keys and then of their calls' lines.
  defp callers(keys, functions) do
    found =
      for caller <- keys,
          call <- Enum.sort_by(functions[caller].calls, & &1.line),
          call.target != caller and Map.has_key?(functions, call.target),
          reduce: %{} do
        acc -> Map.update(acc, call.target, [{caller, call}], &[{caller, call} | &1])
      end

    Map.new(found, fn {callee, callers} -> {callee, Enum.reverse(callers)} end)
  end

  defp spread([], _kind, _callers, effects), do: effects

  defp spread(queue, kind, callers, effects) do
    {next, effects} =
      Enum.reduce(queue, {[], effects}, fn callee, acc ->
        reach_callers(callee, kind, callers, acc)
      end)

    spread(Enum.reverse(next), kind, callers, effects)
  end

  defp reach_callers(callee, kind, callers, {next, effects}) do
    path = effects[callee][kind]

    callers
    |> Map.get(callee, [])
    |> Enum.reject(fn {_caller, call} -> kind == :db_read and call.writes_sql end)
    |> Enum.reduce({next, effects}, fn {caller, call}, {queue, acc} ->
      if Map.has_key?(Map.get(acc, caller, %{}), kind),
        do: {queue, acc},
        else: {[caller | queue], put(acc, caller, kind, [step(call) | path])}
    end)
  end

  defp put(effects, key, kind, path),
    do: Map.update(effects, key, %{kind => path}, &Map.put(&1, kind, path))

  defp step(call), do: %{target: call.target, line: call.line}
end
