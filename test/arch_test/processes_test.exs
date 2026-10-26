defmodule ArchTest.ProcessesTest do
  use ExUnit.Case, async: false

  alias ArchTest.{Assertions, CompiledFixture, ModuleSet, Processes}

  @directory Path.join(System.tmp_dir!(), "arch_test_processes_fixtures")

  setup_all do
    CompiledFixture.compile(@directory, [
      {"lib/process_fixture/cache.ex",
       """
       defmodule ProcessFixture.Cache do
         use GenServer

         def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
         def fetch(key), do: GenServer.call(__MODULE__, {:fetch, key})

         @impl true
         def init(state), do: {:ok, state}

         @impl true
         def handle_call({:fetch, key}, _from, state), do: {:reply, Map.get(state, key), state}

         @impl true
         def handle_cast({:put, key, value}, state), do: {:noreply, Map.put(state, key, value)}
       end
       """},
      {"lib/process_fixture/pricing.ex",
       """
       defmodule ProcessFixture.Pricing do
         alias ProcessFixture.Cache

         def price(item) do
           case GenServer.call(Cache, {:fetch, item}) do
             nil -> 0
             price -> price
           end
         end

         def remember(item, price), do: GenServer.cast(Cache, {:put, item, price})

         def cached(item), do: Cache.fetch(item)

         def ping, do: send(Cache, :ping)
       end
       """},
      {"lib/process_fixture/calculator.ex",
       """
       defmodule ProcessFixture.Calculator do
         use GenServer

         def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
         def add(a, b), do: GenServer.call(__MODULE__, {:add, a, b})

         @impl true
         def init(:ok), do: {:ok, %{}}

         @impl true
         def handle_call({:add, a, b}, _from, state), do: {:reply, a + b, state}
       end
       """},
      {"lib/process_fixture/counter.ex",
       """
       defmodule ProcessFixture.Counter do
         use GenServer

         @impl true
         def init(count), do: {:ok, count}

         @impl true
         def handle_call(:next, _from, count), do: {:reply, count, count + 1}
       end
       """},
      {"lib/process_fixture/log_writer.ex",
       """
       defmodule ProcessFixture.LogWriter do
         use GenServer

         @impl true
         def init(path), do: {:ok, path}

         @impl true
         def handle_cast({:log, line}, path) do
           File.write!(path, line, [:append])
           {:noreply, path}
         end
       end
       """},
      {"lib/process_fixture/client_owner.ex",
       """
       defmodule ProcessFixture.ClientOwner do
         use GenServer

         @impl true
         def init(url) do
           {:ok, client} = Agent.start_link(fn -> url end)
           {:ok, %{client: client}}
         end

         @impl true
         def handle_call(:client, _from, %{client: client} = state), do: {:reply, client, state}

         @impl true
         def terminate(_reason, %{client: client}), do: Agent.stop(client)
       end
       """},
      {"lib/process_fixture/owner_guard.ex",
       """
       defmodule ProcessFixture.OwnerGuard do
         use GenServer

         def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

         @impl true
         def init(owner), do: {:ok, %{owner: owner, monitor: Process.monitor(owner)}}

         @impl true
         def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{monitor: monitor} = state),
           do: {:stop, :normal, state}

         def handle_info(_message, state), do: {:noreply, state}
       end
       """},
      {"lib/process_fixture/connection.ex",
       """
       defmodule ProcessFixture.Connection do
         use GenServer

         def start_link(endpoint), do: GenServer.start_link(__MODULE__, endpoint)
         def start(endpoint), do: GenServer.start(__MODULE__, endpoint)

         @impl true
         def init(endpoint), do: {:ok, endpoint}

         @impl true
         def handle_call(:endpoint, _from, endpoint), do: {:reply, endpoint, endpoint}

         @impl true
         def handle_cast({:endpoint, endpoint}, _old), do: {:noreply, endpoint}
       end
       """},
      {"lib/process_fixture/notifier.ex",
       """
       defmodule ProcessFixture.Notifier do
         def notify(user), do: Task.start(fn -> deliver(user) end)

         def notify_all(users) do
           Task.Supervisor.start_child(ProcessFixture.TaskSupervisor, fn -> Enum.each(users, &deliver/1) end)
         end

         def watch, do: spawn(fn -> Process.sleep(:infinity) end)

         def start_cache, do: GenServer.start(ProcessFixture.Cache, %{})

         def run(fun), do: fun |> Task.async() |> Task.await()

         defp deliver(user), do: IO.puts(user)
       end
       """},
      {"lib/process_fixture/waits.ex",
       """
       defmodule ProcessFixture.Waits do
         def fetch(server, key), do: GenServer.call(server, {:fetch, key}, :infinity)
         def fetch_in_time(server, key), do: GenServer.call(server, {:fetch, key})

         def run_all(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(:infinity)

         def crawl(urls) do
           urls
           |> Task.async_stream(&String.upcase/1, timeout: :infinity, max_concurrency: 4)
           |> Enum.to_list()
         end

         def ask(pid) do
           send(pid, {:ping, self()})

           receive do
             :pong -> :ok
           end
         end

         def ask_in_time(pid) do
           send(pid, {:ping, self()})

           receive do
             :pong -> :ok
           after
             5_000 -> {:error, :timeout}
           end
         end

         def loop(state) do
           receive do
             {:put, value} ->
               loop(value)

             {:get, from} ->
               send(from, state)
               loop(state)
           end
         end

         def guard(worker, ref) do
           receive do
             {:result, ^worker, result} -> result
             {:DOWN, ^ref, :process, ^worker, reason} -> {:error, reason}
           end
         end

         def serve(state) do
           receive do
             message -> handle(state, message)
           end
         end

         defp handle(_state, {:put, value}), do: serve(value)
         defp handle(state, _message), do: serve(state)

         def connect(host), do: :gen_tcp.connect(host, 80, [:binary])
         def read(socket), do: :gen_tcp.recv(socket, 0)
         def read_in_time(socket), do: :gen_tcp.recv(socket, 0, 5_000)
         def get(url), do: :httpc.request(url)
         def get_in_time(url), do: :httpc.request(:get, {url, []}, [timeout: 5_000], [])
       end
       """}
    ])

    :ok
  end

  describe "processes_have_one_interface/2" do
    test "flags messages sent to a process from outside its module" do
      violations = capture(&Processes.processes_have_one_interface/2)

      message =
        &"sends ProcessFixture.Cache a message through #{&1}, outside ProcessFixture.Cache, so the messages it accepts are built in more than one module"

      assert Enum.map(violations, &{&1.module, &1.caller_function, &1.line, &1.message}) == [
               {ProcessFixture.Pricing, {:price, 1}, 5, message.("GenServer.call/2")},
               {ProcessFixture.Pricing, {:remember, 2}, 11, message.("GenServer.cast/2")},
               {ProcessFixture.Pricing, {:ping, 0}, 15, message.("send/2")}
             ]

      assert hd(violations).file == "lib/process_fixture/pricing.ex"

      assert hd(violations).fix ==
               "give ProcessFixture.Cache a function that sends the message, and call that function instead"
    end
  end

  describe "processes_hold_state/2" do
    test "flags a GenServer that only organizes code, and passes ones that hold state, do I/O, own a resource or monitor a process" do
      violations = capture(&Processes.processes_hold_state/2)

      assert Enum.map(violations, &{&1.module, &1.caller_function, &1.line, &1.message, &1.fix}) ==
               [
                 {ProcessFixture.Calculator, {:handle_call, 3}, 11,
                  "ProcessFixture.Calculator is a GenServer whose state never changes and whose callbacks touch " <>
                    "nothing outside it, so its callers wait in one queue for work they could do themselves",
                  "replace the process with plain functions that do the work, and call them directly"}
               ]
    end
  end

  describe "processes_are_supervised/2" do
    test "flags processes started outside a supervisor, and passes supervised, awaited and start functions" do
      violations = capture(&Processes.processes_are_supervised/2)

      message =
        &"starts a process with #{&1} that no supervisor watches, so its crash goes unnoticed and shutdown doesn't stop it"

      assert Enum.map(violations, &{&1.caller_function, &1.line, &1.message}) == [
               {{:notify, 1}, 2, message.("Task.start/1")},
               {{:watch, 0}, 8, message.("spawn/1")},
               {{:start_cache, 0}, 10, message.("GenServer.start/2")}
             ]

      assert hd(violations).fix ==
               "start it under a supervisor, such as Task.Supervisor.start_child/2, or add it to the supervision tree"
    end
  end

  describe "no_unbounded_waits/2" do
    test "flags waits with no limit, and passes ones with a timeout and a process's own receive loop" do
      violations =
        capture(&Processes.no_unbounded_waits/2)
        |> Enum.filter(&(&1.module == ProcessFixture.Waits))

      stuck =
        ": if the answer never comes, this process waits forever, and so does everything waiting on it"

      assert Enum.map(violations, &{&1.caller_function, &1.line, &1.message}) == [
               {{:fetch, 2}, 2, "waits for GenServer.call/3 with timeout :infinity" <> stuck},
               {{:run_all, 1}, 5, "waits for Task.await_many/2 with timeout :infinity" <> stuck},
               {{:crawl, 1}, 9,
                "waits for Task.async_stream/3 with `timeout: :infinity`" <> stuck},
               {{:ask, 1}, 16, "waits in a receive with no after" <> stuck},
               {{:connect, 1}, 58,
                "waits for :gen_tcp.connect/3, which has no timeout by default" <> stuck},
               {{:read, 1}, 59,
                "waits for :gen_tcp.recv/2, which has no timeout by default" <> stuck},
               {{:get, 1}, 61,
                "waits for :httpc.request/1, which has no timeout by default" <> stuck}
             ]

      assert Enum.map(violations, & &1.fix) |> Enum.uniq() == [
               "give it a timeout, and handle what happens when it passes",
               "add an after clause that gives up, and handle that"
             ]
    end
  end

  defp capture(rule) do
    subject = ModuleSet.new("ProcessFixture.**")

    Assertions.capture_violations(fn -> rule.(subject, paths: [@directory]) end)
  end
end
