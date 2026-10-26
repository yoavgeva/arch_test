defmodule ArchTest.TestCode do
  @moduledoc """
  Rules about tests: that they test the module they're named after, mock only what does I/O, wait for results
  instead of sleeping, and don't change global state while other tests run.

  ExUnit compiles test files in memory as it runs them, so these rules read the `*_test.exs` files under
  `:test_paths` (default `["test"]`) from source, with aliases resolved. They check them against the production
  code, read from debug info as `ArchTest.Effects` does: which module a test is named after, and what a mocked
  module does.

  ## Usage

      defmodule MyApp.TestRulesTest do
        use ExUnit.Case
        use ArchTest, app: :my_app
        use ArchTest.TestCode

        test "tests use their subject" do
          tests_use_their_subject(modules_matching("MyApp.**"), app: :my_app)
        end

        test "tests mock only I/O" do
          tests_dont_mock_pure_modules(modules_matching("MyApp.**"), app: :my_app)
        end

        test "tests don't sleep" do
          tests_dont_sleep(modules_matching("MyApp.**"), app: :my_app)
        end

        test "async tests share no state" do
          async_tests_share_no_state(modules_matching("MyApp.**"), app: :my_app)
        end
      end

  The subject selects test modules by name, so `modules_matching("MyApp.**")` checks `MyApp.AccountsTest`.
  """

  alias ArchTest.{Code, ModuleSet, TestSource, Violation}
  alias ArchTest.Code.{Effects, Rules}

  @sleeps [{Process, :sleep}, {:timer, :sleep}]
  @global %{
    Application => [:put_env, :delete_env, :put_all_env],
    System => [:put_env, :delete_env],
    :persistent_term => [:put, :erase],
    Logger => [
      :configure,
      :configure_backend,
      :add_backend,
      :remove_backend,
      :put_module_level,
      :put_application_level,
      :delete_module_level,
      :delete_application_level
    ],
    :logger => [
      :set_primary_config,
      :update_primary_config,
      :add_handler,
      :remove_handler,
      :set_module_level
    ]
  }
  # Requests Phoenix's ConnTest, LiveViewTest and ChannelTest send through the endpoint or the socket, which reach
  # its controllers, live views and channels.
  @requests ~w(get post put patch delete head options dispatch live live_isolated subscribe_and_join join push)a
  @web ~r/Web\.|(Controller|Live|LiveView|Component|Channel|Plug|Socket)$/
  @mock_fix "use the real module, and mock only the ones that touch the database, the network or other services"

  @doc false
  defmacro __using__(_opts) do
    quote do
      import ArchTest.TestCode
    end
  end

  @doc """
  Asserts that each test module exercises the module it's named after: `MyApp.AccountsTest` uses
  `MyApp.Accounts`, and not only through mocks of it.

  A use is the module's name anywhere in the test, other than as the module a mock replaces, a call to one of
  its functions the test doesn't mock, a use of a module nested in it, as `MyApp.Billing.Invoice` is in
  `MyApp.Billing`, or code the test calls that reaches it: calls it, or names it, as a registry of rule modules
  does, directly or through the functions it calls. A test of a controller, live view or channel that sends requests through `Phoenix.ConnTest`,
  `Phoenix.LiveViewTest` or `Phoenix.ChannelTest` uses it too. Tests named after no module in scope are skipped.
  """
  @spec tests_use_their_subject(ModuleSet.t(), keyword()) :: :ok
  def tests_use_their_subject(%ModuleSet{} = subject, opts \\ []) do
    {tests, code, _effects, source} = analyze(subject, opts)
    index = Enum.group_by(Map.keys(code.functions), &elem(&1, 0))

    violations =
      for test <- tests,
          target = named_after(test.name),
          MapSet.member?(code.scope, target),
          usage = usage(test, target, {code, index}, source),
          usage != :uses do
        {verb, fix} =
          case usage do
            :mocks ->
              {"only mocks", "test the real #{inspect(target)}, and mock only what it calls"}

            :never ->
              {"never uses",
               "test #{inspect(target)} itself, or name the test after the module it tests"}
          end

        violation(test, "tests_use_their_subject", test.line,
          message:
            "#{inspect(test.name)} #{verb} #{inspect(target)}, the module it's named after",
          fix: fix
        )
      end

    Rules.report(violations, "tests_use_their_subject")
  end

  @doc """
  Asserts that tests mock only modules that do I/O.

  A mock is `Mimic.stub/3`, `Mimic.expect/3`, `Mock.with_mock/3` and the like on a project module, or a Mox mock
  declared with `Mox.defmock/2` for a behaviour. It's flagged when the function it replaces, or every
  implementation of the behaviour, touches nothing outside the code: a real one is as cheap to call, and a test of
  the mock checks nothing about the code.
  """
  @spec tests_dont_mock_pure_modules(ModuleSet.t(), keyword()) :: :ok
  def tests_dont_mock_pure_modules(%ModuleSet{} = subject, opts \\ []) do
    {tests, code, effects, source} = analyze(subject, opts)
    # Which functions call outside the code is the same for every mock, so it's found once.
    opaque = if Enum.any?(tests, &(&1.mocks != [])), do: opaque(code), else: MapSet.new()
    known = %{code: code, effects: effects, opaque: opaque}

    violations =
      for test <- tests,
          mock <- test.mocks,
          message <- List.wrap(pure_mock(mock, known, source)) do
        violation(test, "tests_dont_mock_pure_modules", mock.line,
          message:
            "#{mock.label} mocks #{message}, so the test checks the mock instead of the code",
          fix: @mock_fix
        )
      end

    Rules.report(violations, "tests_dont_mock_pure_modules")
  end

  @doc """
  Asserts that no test sleeps, with `Process.sleep/1` or `:timer.sleep/1`.

  A sleep long enough on a fast machine is too short on a slow one, and slows every run. Wait for what the test
  needs instead: `assert_receive/3` for a message, or a monitor's `:DOWN` message for a process to stop. Sleeps in a
  helper that retries itself, as an `assert_eventually` polling a condition does, pass, and so do sleeps in fakes a
  test file defines without tests of its own, which stand in for a slow dependency, and `Process.sleep(:infinity)`,
  which parks a process rather than waiting.
  """
  @spec tests_dont_sleep(ModuleSet.t(), keyword()) :: :ok
  def tests_dont_sleep(%ModuleSet{} = subject, opts \\ []) do
    {tests, _code, _effects, _source} = analyze(subject, opts)

    violations =
      for test <- tests,
          test.tests,
          %{target: {module, name, _arity} = target} = call <- test.calls,
          {module, name} in @sleeps and call.argument != :infinity and not call.callback,
          not retries?(test, call.label) do
        violation(test, "tests_dont_sleep", call.line,
          message:
            "#{call.label} sleeps with #{Rules.name(target, test.name)}, which is too short on a slow machine " <>
              "and slows every run",
          fix:
            "wait for what the test needs instead, with assert_receive or a monitor's :DOWN message"
        )
      end

    Rules.report(violations, "tests_dont_sleep")
  end

  @doc """
  Asserts that tests running async don't change global state.

  `Application.put_env/3`, `System.put_env/2`, `:persistent_term.put/2`, `Logger.configure/1` and the like change
  state every test sees, so in a module with `async: true` they make the tests running at the same time pass or
  fail by timing. Pass the value to the code under test instead, or make the module `async: false`.
  """
  @spec async_tests_share_no_state(ModuleSet.t(), keyword()) :: :ok
  def async_tests_share_no_state(%ModuleSet{} = subject, opts \\ []) do
    {tests, _code, _effects, source} = analyze(subject, opts)

    violations =
      for test <- tests,
          test.async,
          own = MapSet.new(for(other <- source.modules, other.file == test.file, do: other.name)),
          %{target: {module, name, _arity} = target} = call <- test.calls,
          name in Map.get(@global, module, []),
          not MapSet.member?(own, call.key_module) do
        violation(test, "async_tests_share_no_state", call.line,
          message:
            "#{call.label} changes global state with #{Rules.name(target, test.name)} in an async test, " <>
              "so tests running at the same time can see it",
          fix:
            "pass the value to the code under test instead, or make the test module async: false"
        )
      end

    Rules.report(violations, "async_tests_share_no_state")
  end

  # A helper that calls itself, retrying until a condition holds or it runs out of attempts.
  defp retries?(test, label) do
    case Regex.run(~r/^(\w+[?!]?)\/\d+$/, label) do
      [_, name] ->
        Enum.any?(test.calls, fn
          %{target: {:local, callee, _arity}, label: ^label} -> Atom.to_string(callee) == name
          _call -> false
        end)

      nil ->
        false
    end
  end

  defp analyze(subject, opts) do
    source = TestSource.load(opts)
    names = Map.new(source.modules, &{&1.name, []})
    selected = subject |> ModuleSet.resolve(names) |> MapSet.new()

    tests =
      source.modules |> Enum.filter(&MapSet.member?(selected, &1.name)) |> Enum.sort_by(& &1.file)

    code = Code.load_scope(opts)

    {tests, code, Effects.of(code), source}
  end

  defp named_after(test) do
    name = Atom.to_string(test)

    if String.ends_with?(name, "Test"),
      do: name |> String.replace_suffix("Test", "") |> String.to_atom()
  end

  # Whether a test uses `target`, only mocks it, or never names it.
  defp usage(test, target, graph, source) do
    mocked = for %{module: ^target, function: function} <- test.mocks, do: function

    cond do
      uses?(test, target, mocked, graph, source) -> :uses
      mocked != [] or Enum.any?(test.calls, &match?(%{target: {^target, _, _}}, &1)) -> :mocks
      true -> :never
    end
  end

  defp uses?(test, target, mocked, graph, source) do
    own = own_modules(test, source)

    target in test.references or real_call?(test, target, mocked) or nested?(test, target) or
      (Regex.match?(@web, inspect(target)) and requests?(test)) or
      Enum.any?(
        own,
        &(target in &1.references or Enum.any?(&1.calls, fn call -> calls?(call, target) end))
      ) or
      runs_task?(test, target) or
      exercised?(test, target, graph, source, own)
  end

  defp calls?(%{target: {module, _, _}}, target), do: module == target

  # The modules the test file defines that the test names, as a migration it runs is: their code runs too.
  defp own_modules(test, source) do
    for other <- source.modules,
        other.file == test.file and other.name != test.name,
        other.name in test.references or
          Enum.any?(test.calls, &match?(%{target: {module, _, _}} when module == other.name, &1)),
        do: other
  end

  # A Mix task the test runs by its name, as `Mix.Task.run("my_app.install", [])` does.
  defp runs_task?(test, target) do
    case inspect(target) do
      "Mix.Tasks." <> _ ->
        task = Mix.Task.task_name(target)

        case File.read(test.file) do
          {:ok, text} -> String.contains?(text, ~s("#{task}"))
          {:error, _reason} -> false
        end

      _other ->
        false
    end
  end

  # Code the test calls reaches the target: calls it, or names it, as a registry listing rule modules does, directly
  # or through the functions it calls, or through a test helper's calls.
  defp exercised?(test, target, {code, _index} = graph, source, own) do
    helpers =
      for module <- helper_modules(test),
          call <- Map.get(source.support, module, []),
          do: call

    start =
      for %{target: {module, _, _} = key} <-
            test.calls ++ helpers ++ Enum.flat_map(own, & &1.calls),
          module != target,
          Map.has_key?(code.functions, key),
          uniq: true,
          do: {key, true}

    reach(start, MapSet.new(start, &elem(&1, 0)), target, graph)
  end

  # The modules a test calls, and those it imports a function it calls from, as `findings(text)` is from
  # `import MyApp.Test.Linting, only: [findings: 1]`.
  defp helper_modules(test) do
    called = for %{target: {module, _, _}} <- test.calls, module != :local, do: module

    imported =
      for {module, only} <- test.imports,
          Enum.any?(test.calls, &imported?(&1, only)),
          do: module

    Enum.uniq(called ++ imported)
  end

  defp imported?(%{target: {:local, _name, _arity}}, nil), do: true
  defp imported?(%{target: {:local, name, arity}}, only), do: {name, arity} in only
  defp imported?(_call, _only), do: false

  # Follows calls, and once, from code reached by calls, into the functions of a module it names as a value, as a
  # step list `[decode: MyApp.Decode]` or a struct's default does: code that names a module may run it.
  defp reach([], _seen, _target, _graph), do: false

  defp reach([{key, follow_names?} | rest], seen, target, {code, index} = graph) do
    info = code.functions[key]

    # A behaviour is used through its implementations.
    if MapSet.member?(info.references, target) or target in Code.behaviours(code, elem(key, 0)) do
      true
    else
      called =
        for %{target: callee} <- info.calls,
            Map.has_key?(code.functions, callee),
            callee not in seen,
            uniq: true,
            do: {callee, follow_names?}

      named = if follow_names?, do: named_functions(info, index, seen), else: []

      next = Enum.uniq_by(called ++ named, &elem(&1, 0))
      reach(next ++ rest, Enum.into(next, seen, &elem(&1, 0)), target, graph)
    end
  end

  defp named_functions(info, index, seen) do
    for module <- info.references,
        callee <- Map.get(index, module, []),
        callee not in seen,
        uniq: true,
        do: {callee, false}
  end

  # A call to one of the target's functions the test doesn't replace with a mock.
  defp real_call?(test, target, mocked) do
    nil not in mocked and
      Enum.any?(test.calls, fn
        %{target: {^target, name, _arity}} -> name not in mocked
        _call -> false
      end)
  end

  # A module nested in the target, as `MyApp.Billing.Invoice` is in `MyApp.Billing`, stands for it.
  defp nested?(test, target) do
    prefix = Atom.to_string(target) <> "."
    called = for %{target: {module, _, _}} when is_atom(module) <- test.calls, do: module

    Enum.any?(test.references ++ called, &String.starts_with?(Atom.to_string(&1), prefix))
  end

  defp requests?(test),
    do: Enum.any?(test.calls, &match?(%{target: {:local, name, _}} when name in @requests, &1))

  # What a mock replaces, when that touches nothing outside the code: a Mox mock's behaviour, or a project module.
  defp pure_mock(%{module: module, function: function}, known, source) do
    case Map.fetch(source.mocks, module) do
      {:ok, behaviours} -> pure_behaviours(module, behaviours, function, known)
      :error -> pure_module(module, function, known)
    end
  end

  defp pure_behaviours(mock, behaviours, function, known) do
    implementations =
      for {implementation, info} <- known.code.modules,
          Enum.any?(behaviours, &(&1 in info.behaviours)),
          do: implementation

    if pure?(implementations, function, known) do
      "#{inspect(mock)}, whose #{Enum.map_join(behaviours, ", ", &inspect/1)} implementations touch nothing " <>
        "outside them"
    end
  end

  defp pure_module(module, function, known) do
    if MapSet.member?(known.code.scope, module) and pure?([module], function, known) do
      replaced = if function, do: "#{inspect(module)}.#{function}", else: inspect(module)
      "#{replaced}, which touches nothing outside it"
    end
  end

  defp pure?(modules, function, known) do
    functions =
      for module <- modules,
          {{^module, name, _arity} = key, info} <- Code.functions_of(known.code, module),
          info.kind == :def and not info.injected and (function == nil or name == function),
          do: key

    functions != [] and
      Enum.all?(
        functions,
        &(Map.get(known.effects, &1, %{}) == %{} and not MapSet.member?(known.opaque, &1))
      )
  end

  # The functions whose effects the code can't show: they call a library outside Elixir's and Erlang's own, as an
  # SDK such as `Shopify` is, or a module chosen at runtime, directly or through the project functions they call.
  defp opaque(code) do
    roots = standard_roots()

    standard =
      Map.new(
        for {_key, info} <- code.functions,
            %{target: {module, _, _}} <- info.calls,
            uniq: true,
            do: {module, standard?(module, code, roots)}
      )

    direct =
      for {key, info} <- code.functions,
          info.dynamic or
            Enum.any?(info.calls, fn %{target: {module, _, _}} ->
              not Map.fetch!(standard, module)
            end),
          into: MapSet.new(),
          do: key

    callers =
      for {caller, %{calls: calls}} <- code.functions, %{target: target} <- calls, reduce: %{} do
        acc -> Map.update(acc, target, [caller], &[caller | &1])
      end

    to_callers(MapSet.to_list(direct), direct, callers)
  end

  # Spreads a set of functions to everything that calls one, breadth-first through the callers.
  defp to_callers([], found, _callers), do: found

  defp to_callers([key | rest], found, callers) do
    next =
      for caller <- Map.get(callers, key, []),
          not MapSet.member?(found, caller),
          uniq: true,
          do: caller

    to_callers(next ++ rest, Enum.into(next, found), callers)
  end

  # A project module, or one of Elixir's or Erlang's own, whose effects are known.
  defp standard?(module, code, roots) do
    MapSet.member?(code.scope, module) or
      case :code.which(module) do
        :preloaded -> true
        path when is_list(path) -> String.starts_with?(List.to_string(path), roots)
        _missing -> false
      end
  end

  defp standard_roots do
    elixir = :elixir |> :code.lib_dir() |> List.to_string() |> Path.dirname()
    [List.to_string(:code.root_dir()), elixir]
  end

  defp violation(test, rule, line, details) do
    %Violation{
      type: :custom,
      rule: rule,
      module: test.name,
      caller: test.name,
      file: test.file,
      line: line,
      message: Keyword.fetch!(details, :message),
      fix: Keyword.fetch!(details, :fix)
    }
  end
end
