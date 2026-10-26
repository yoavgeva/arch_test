# Processes

`ArchTest.Processes` checks three of Elixir's
[process-related anti-patterns](https://hexdocs.pm/elixir/process-anti-patterns.html), and that no process waits
forever. Like `ArchTest.Effects`, it
reads your code from the BEAM files' debug info, after macro expansion, so aliases and `use GenServer` are resolved.

```elixir
defmodule MyApp.ProcessesTest do
  use ExUnit.Case
  use ArchTest, app: :my_app
  use ArchTest.Processes

  test "each process has one interface" do
    processes_have_one_interface(modules_matching("MyApp.**"), app: :my_app)
  end

  test "GenServers hold state or do I/O" do
    processes_hold_state(modules_matching("MyApp.**"), app: :my_app)
  end

  test "processes are supervised" do
    processes_are_supervised(modules_matching("MyApp.**"), app: :my_app)
  end

  test "waits have limits" do
    no_unbounded_waits(modules_matching("MyApp.**"), app: :my_app)
  end
end
```

---

## 1. One interface per process

"Scattered process interfaces": when other modules build a process's messages themselves, the messages it accepts
are spread over every module that sends one, and changing them means finding them all.

```elixir
# flagged: Pricing builds MyApp.Cache's messages
def price(item), do: GenServer.call(MyApp.Cache, {:fetch, item})

# fixed: MyApp.Cache owns them
def price(item), do: MyApp.Cache.fetch(item)
```

`processes_have_one_interface/2` flags `GenServer.call/2,3`, `GenServer.cast/2`, `GenServer.stop/1`, the `Agent`
functions and `send/2` to a process named after a project module, made outside that module. Calls to a pid aren't
checked, since the code doesn't say which process it is.

---

## 2. A reason to be a process

"Code organization by process": a GenServer used only to group functions makes every caller wait in its queue,
one at a time, for work they could do themselves.

```elixir
# flagged
def handle_call({:add, a, b}, _from, state), do: {:reply, a + b, state}

# fixed: a plain function
def add(a, b), do: a + b
```

`processes_hold_state/2` flags a GenServer when every reply its callbacks return keeps the state they were given,
and the callbacks touch nothing outside the process, directly or through what they call. It passes a GenServer
that:

- changes its state, as a counter or a cache does;
- does I/O in its callbacks, serializing access to a file, a port or an API;
- owns a resource: starts or opens something in `init/1`, such as a client connection, or monitors a process
  there, or cleans up in its own `terminate/2`.

---

## 3. Supervised processes

"Unsupervised processes": a process nothing links to goes unnoticed when it crashes, and keeps running when the
application shuts down.

```elixir
# flagged
def notify(user), do: Task.start(fn -> deliver(user) end)

# fixed
def notify(user), do: Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> deliver(user) end)
```

`processes_are_supervised/2` flags `spawn/1,3`, `Process.spawn/2,4`, `Task.start/1,3`, `GenServer.start/2,3` and
`Agent.start/1,2`. `Task.async/1` with `Task.await/2` and the `start_link` functions are fine: the caller is linked
to the process and waits for it, or a supervisor starts it. So is a module's own `start` or `start_link` function,
such as a library's `start/1` calling `GenServer.start/2`: its caller decides how the process is supervised.

---

## 4. Waits have limits

A wait with no limit turns a slow or dead process, server or peer into a stuck caller, and everything waiting on the
caller gets stuck too.

```elixir
# flagged
suppliers |> Task.async_stream(&price/1, timeout: :infinity) |> Enum.map(fn {:ok, price} -> price end)

# fixed
suppliers
|> Task.async_stream(&price/1, timeout: 5_000, on_timeout: :kill_task)
|> Enum.flat_map(fn {:ok, price} -> [price]; {:exit, :timeout} -> [] end)
```

`no_unbounded_waits/2` flags:

- `:infinity` given as a timeout: to `GenServer.call/3`, `Task.await/2`, `Task.await_many/2`, `Task.yield/2`,
  `Agent.get/3`, `:erpc.call/5` and the like, or as an option named for a timeout, such as `timeout: :infinity` or
  `receive_timeout: :infinity`;
- calls that wait forever unless given a limit: `:gen_tcp.connect/3`, `:gen_tcp.recv/2`, `:ssl.recv/2`,
  `:ssl.handshake/1`, and `:httpc.request/1,2,4` without a `timeout` HTTP option;
- a `receive` with no `after`.

It passes a `receive` that also takes the `:DOWN` of the process it waits on, as `GenServer.call/2` does, and a
process's own loop, whose clauses call back into it to wait for the next message. `GenServer.call/2`, `Task.await/1`,
Req, Finch and HTTPoison have default timeouts.
