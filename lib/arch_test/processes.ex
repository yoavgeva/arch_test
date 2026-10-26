defmodule ArchTest.Processes do
  @moduledoc """
  Rules about processes, from Elixir's [process-related anti-patterns](https://hexdocs.pm/elixir/process-anti-patterns.html):
  one module owns each process's messages, processes are there for runtime reasons, and long-lived processes run
  under a supervisor. And one more: no process waits forever.

  ## Usage

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

  Like `ArchTest.Effects`, they read the code from the BEAM files' debug info, after macro expansion.
  """

  alias ArchTest.{Code, ModuleSet}
  alias ArchTest.Code.Rules

  # Calls that send a process a message, with its name as their first argument.
  @messages [
    {GenServer, :call},
    {GenServer, :cast},
    {GenServer, :stop},
    {:gen_server, :call},
    {:gen_server, :cast},
    {Agent, :get},
    {Agent, :update},
    {Agent, :get_and_update},
    {Agent, :cast},
    {Agent, :stop},
    {:erlang, :send},
    {Process, :send},
    {Process, :send_after}
  ]

  # Calls that start a process nobody links to or supervises.
  @unsupervised [
    {:erlang, :spawn},
    {Process, :spawn},
    {:proc_lib, :spawn},
    {Task, :start},
    {GenServer, :start},
    {:gen_server, :start},
    {Agent, :start}
  ]

  @callbacks [{:handle_call, 3}, {:handle_cast, 2}, {:handle_info, 2}, {:handle_continue, 2}]

  # Functions that start or open a resource, such as a client library's `start_link/1` or `connect/1`.
  @starts [:start_link, :start, :connect, :open]

  @doc false
  defmacro __using__(_opts) do
    quote do
      import ArchTest.Processes
    end
  end

  @doc """
  Asserts that only a process's own module sends it messages: "scattered process interfaces".

  A call such as `GenServer.call(MyApp.Cache, {:fetch, key})`, `GenServer.cast/2`, an `Agent` call or `send/2` to a
  process named after a project module, made outside that module, spreads the messages the process accepts over
  every module that builds them. Give the module a function that sends the message, such as
  `MyApp.Cache.fetch/1`, and call that instead. Calls to a pid aren't checked, since the code doesn't say which
  process it is.
  """
  @spec processes_have_one_interface(ModuleSet.t(), keyword()) :: :ok
  def processes_have_one_interface(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, _effects} = Rules.analyze(subject, opts)

    violations =
      for module <- modules,
          {{^module, name, arity}, info} <- Code.functions_of(code, module),
          %{target: {callee, callee_name, _}, receiver: receiver} = call <- info.calls,
          {callee, callee_name} in @messages,
          receiver != module and MapSet.member?(code.scope, receiver) do
        Rules.violation(code, "processes_have_one_interface", {module, name, arity},
          line: call.line,
          callee: call.target,
          message:
            "sends #{inspect(receiver)} a message through #{Rules.name(call.target, module)}, " <>
              "outside #{inspect(receiver)}, so the messages it accepts are built in more than one module",
          fix:
            "give #{inspect(receiver)} a function that sends the message, and call that function instead"
        )
      end

    Rules.report(violations, "processes_have_one_interface")
  end

  @doc """
  Asserts that every GenServer in `subject` has a runtime reason to be a process: "code organization by process".

  A GenServer is flagged when every reply its callbacks return keeps the state they were given, and the callbacks
  touch nothing outside the process, directly or through what they call. Such a process only runs plain
  computations one caller at a time, so its callers queue up for work they could do themselves. Replace it with
  plain functions. A GenServer that changes its state, does I/O, schedules work, or owns a resource passes: one
  that starts or opens something in `init/1`, such as a client connection, or cleans up in `terminate/2`.
  """
  @spec processes_hold_state(ModuleSet.t(), keyword()) :: :ok
  def processes_hold_state(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, effects} = Rules.analyze(subject, opts)

    violations =
      for module <- modules,
          GenServer in Code.behaviours(code, module),
          callbacks = callbacks(code, module),
          {key, info} <-
            callbacks |> Enum.reject(fn {_key, info} -> info.injected end) |> Enum.take(1),
          Enum.all?(callbacks, fn {_key, info} -> info.state == :kept end),
          Enum.all?(callbacks, fn {key, _info} -> Map.get(effects, key, %{}) == %{} end),
          not owns_resource?(code, module, effects) do
        Rules.violation(code, "processes_hold_state", key,
          line: info.line,
          message:
            "#{inspect(module)} is a GenServer whose state never changes and whose callbacks touch nothing " <>
              "outside it, so its callers wait in one queue for work they could do themselves",
          fix: "replace the process with plain functions that do the work, and call them directly"
        )
      end

    Rules.report(violations, "processes_hold_state")
  end

  @doc """
  Asserts that no function in `subject` starts a process no supervisor watches: "unsupervised processes".

  `spawn/1`, `Task.start/1`, `GenServer.start/2` and `Agent.start/1` start a process that nothing links to, so
  when it crashes nobody notices, and when the application shuts down it keeps running. Start it under a
  supervisor instead, such as `Task.Supervisor.start_child/2` for a task, or add it to the supervision tree.
  `Task.async/1` with `Task.await/2` and the `start_link` functions are fine: the caller is linked and waits. So is
  a module's own `start` or `start_link` function, such as a library's `start/1` that calls `GenServer.start/2`: its
  caller decides how the process is supervised.
  """
  @spec processes_are_supervised(ModuleSet.t(), keyword()) :: :ok
  def processes_are_supervised(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, _effects} = Rules.analyze(subject, opts)

    violations =
      for module <- modules,
          {{^module, name, arity}, info} <- Code.functions_of(code, module),
          name not in [:start, :start_link],
          %{target: {callee, callee_name, _}} = call <- info.calls,
          {callee, callee_name} in @unsupervised do
        Rules.violation(code, "processes_are_supervised", {module, name, arity},
          line: call.line,
          callee: call.target,
          message:
            "starts a process with #{Rules.name(call.target, module)} that no supervisor watches, " <>
              "so its crash goes unnoticed and shutdown doesn't stop it",
          fix:
            "start it under a supervisor, such as Task.Supervisor.start_child/2, or add it to the supervision tree"
        )
      end

    Rules.report(violations, "processes_are_supervised")
  end

  @doc """
  Asserts that no function in `subject` waits with no limit.

  A wait with no limit turns a slow or dead process, server or peer into a stuck caller, and every process waiting
  on that caller gets stuck too. Flags:

  - `:infinity` given as a timeout: to `GenServer.call/3`, `Task.await/2`, `Task.await_many/2`, `Task.yield/2`,
    `Agent.get/3`, `:erpc.call/5` and the like, or as a keyword option named for a timeout, such as
    `Task.async_stream(items, fun, timeout: :infinity)` or `Req.get(url, receive_timeout: :infinity)`;
  - calls that wait with no limit unless given one: `:gen_tcp.connect/3`, `:gen_tcp.recv/2`, `:gen_udp.recv/2`,
    `:ssl.connect/2`, `:ssl.recv/2`, `:ssl.handshake/1`, and `:httpc.request/1,2,4` without a `timeout` HTTP option;
  - a `receive` with no `after`, or `after :infinity`. A process's own loop, whose clauses call the function again
    to wait for its next message, passes.

  `GenServer.call/2`, `Task.await/1`, Req, Finch and HTTPoison have default timeouts, and pass.
  """
  @spec no_unbounded_waits(ModuleSet.t(), keyword()) :: :ok
  def no_unbounded_waits(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, _effects} = Rules.analyze(subject, opts)

    violations =
      for module <- modules,
          {key, info} <- Code.functions_of(code, module),
          not info.injected,
          wait <- info.waits,
          not loops?(wait, key, code) do
        Rules.violation(code, "no_unbounded_waits", key,
          line: wait.line,
          callee: wait.target,
          message:
            waiting(wait, module) <>
              ": if the answer never comes, this process waits forever, and so does everything waiting on it",
          fix:
            if(wait.how == :receive,
              do: "add an after clause that gives up, and handle that",
              else: "give it a timeout, and handle what happens when it passes"
            )
        )
      end

    Rules.report(violations, "no_unbounded_waits")
  end

  # Whether a receive's clauses lead back to its function, through the module's functions: a process's loop.
  defp loops?(%{how: :receive, next: next}, key, code),
    do: leads_to?(next, MapSet.new(next), key, code)

  defp loops?(_wait, _key, _code), do: false

  defp leads_to?([], _seen, _key, _code), do: false
  defp leads_to?([key | _rest], _seen, key, _code), do: true

  defp leads_to?([{module, _, _} = current | rest], seen, key, code) do
    next =
      for %{target: {^module, _, _} = target} <- code.functions[current].calls,
          Map.has_key?(code.functions, target),
          not MapSet.member?(seen, target),
          uniq: true,
          do: target

    leads_to?(rest ++ next, Enum.into(next, seen), key, code)
  end

  defp waiting(%{how: :receive}, _module), do: "waits in a receive with no after"

  defp waiting(%{how: :infinity, target: target}, module),
    do: "waits for #{Rules.name(target, module)} with timeout :infinity"

  defp waiting(%{how: :option, target: target, option: option}, module),
    do: "waits for #{Rules.name(target, module)} with `#{option}: :infinity`"

  defp waiting(%{how: :default, target: target}, module),
    do: "waits for #{Rules.name(target, module)}, which has no timeout by default"

  # A process that starts or opens something in init/1, or cleans up in its own terminate/2, owns that resource's
  # lifetime: a runtime reason to be a process, as a GenServer holding a client connection is.
  defp owns_resource?(code, module, effects) do
    init = Map.get(code.functions, {module, :init, 1}, %{calls: []})
    terminate = Map.get(code.functions, {module, :terminate, 2})

    (terminate != nil and not terminate.injected) or
      Map.get(effects, {module, :init, 1}, %{}) != %{} or
      Enum.any?(init.calls, fn %{target: {_module, name, _arity}} -> name in @starts end)
  end

  # The module's handle_call/3, handle_cast/2, handle_info/2 and handle_continue/2, by line, those `use GenServer`
  # defines included: their replies count too.
  defp callbacks(code, module) do
    code
    |> Code.functions_of(module)
    |> Enum.filter(fn {{_module, name, arity}, _info} -> {name, arity} in @callbacks end)
    |> Enum.sort_by(fn {_key, info} -> info.line end)
  end
end
