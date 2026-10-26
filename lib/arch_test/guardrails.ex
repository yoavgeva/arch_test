defmodule ArchTest.Guardrails do
  @moduledoc """
  Rules against shortcuts that get a build green without doing the work: warnings silenced instead of fixed,
  functions that stand in for code nobody wrote, private functions made public so tests can call them, and errors
  turned into `nil` so nothing crashes. AI agents take these shortcuts to finish a task, and they pass review at a
  glance.

  ## Usage

      defmodule MyApp.GuardrailsTest do
        use ExUnit.Case
        use ArchTest, app: :my_app
        use ArchTest.Guardrails

        test "no suppressions" do
          no_suppressions(modules_matching("MyApp.**"), app: :my_app)
        end

        test "no stubs" do
          no_stubs(modules_matching("MyApp.**"), app: :my_app)
        end

        test "nothing is public only for tests" do
          no_functions_only_tests_call(modules_matching("MyApp.**"), app: :my_app)
        end

        test "errors reach their callers" do
          no_swallowed_errors(modules_matching("MyApp.**"), app: :my_app)
        end
      end
  """

  alias ArchTest.{Code, ModuleSet, TestSource, Violation}
  alias ArchTest.Code.{Errors, Rules}
  alias Elixir.Code.Typespec

  @comments [
    credo: ~r/^#\s*credo:disable/,
    sobelow: ~r/^#\s*sobelow_skip/,
    coveralls: ~r/^#\s*coveralls-ignore/
  ]

  # Functions supervisors and frameworks call by convention, through a child spec rather than the code.
  @conventional [:child_spec, :start_link]
  # Effects whose errors a caller needs to know about.
  @outside [:db_read, :db_write, :http, :network, :mail, :publish, :file, :system]
  # Functions that release something: their errors leave nothing to recover.
  @releases [
    :close,
    :stop,
    :shutdown,
    :cancel,
    :terminate_child,
    :unlink,
    :demonitor,
    :disconnect
  ]

  @doc false
  defmacro __using__(_opts) do
    quote do
      import ArchTest.Guardrails
    end
  end

  @doc """
  Asserts that no source of `subject`, or of its tests, silences a tool instead of fixing what it reports.

  Flags `# credo:disable-...` comments, `# sobelow_skip`, `# coveralls-ignore-...`, `@dialyzer` attributes that turn
  warnings off, such as `{:nowarn_function, ...}` or `:no_return`, and `@compile` options such as
  `{:no_warn_undefined, ...}`. Mentions in docs and strings don't count.

  ## Options

  - `:allow` — tools whose suppressions the project accepts, from `:credo`, `:sobelow`, `:coveralls`,
    `:dialyzer` and `:compile`
  """
  @spec no_suppressions(ModuleSet.t(), keyword()) :: :ok
  def no_suppressions(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, _effects} = Rules.analyze(subject, opts)
    allowed = Keyword.get(opts, :allow, [])

    files =
      for(module <- modules, file = Code.file(code, module), file != nil, do: {file, module}) ++
        for test <- tests(subject, opts), do: {test.file, test.name}

    violations =
      for {file, owner} <- Enum.uniq_by(files, &elem(&1, 0)),
          own?(file),
          {module, line, text} <- suppressions(file, allowed) do
        %Violation{
          type: :custom,
          rule: "no_suppressions",
          module: module || owner,
          caller: module || owner,
          file: file,
          line: line,
          message: "#{text} silences a warning instead of fixing it",
          fix: "fix what the tool reports instead of silencing it"
        }
      end

    Rules.report(violations, "no_suppressions")
  end

  @doc """
  Asserts that no function in `subject` swallows errors from the outside world, so its callers can't tell it failed.

  Flags, when the error comes from the database, HTTP, the network, files, mail, publishing or the operating system,
  directly or through the functions the code calls:

  - a catch-all handler whose result looks like success: `rescue _ -> nil`, a `catch` of anything, or a `case` or
    `with`-`else` clause matching any `{:error, _}`, or anything beside an `{:ok, _}` clause, that raises nothing
    and returns a literal, such as `nil`, `[]`, `:ok` or `{:ok, default}`, even when it logs the error first;
  - a call that can return `{:error, _}`, its result thrown away: a statement in a block, or the value of a
    function given to `Enum.each/2`. An explicit `_ = call` says it's ignored on purpose, and passes.

  It passes:

  - handlers of specific errors, such as `rescue Ecto.NoResultsError -> nil` or `{:error, :not_found} -> nil`;
  - errors passed on: in the result, as `{:stop, reason}` is, or given to a call other than a log, as
    `mark_failed(job, reason)` is; and results that say it failed, such as `:failed`;
  - errors of code that touches nothing outside it, such as a parser's `{:error, _}` for bad input;
  - predicates, functions named with `?`, answering `false`, as `match?({:ok, _}, call)` does;
  - releases: errors from `close`, `stop`, `shutdown`, `cancel` and the like, which have nothing to recover;
  - Mix tasks, which report to the person running them.
  """
  @spec no_swallowed_errors(ModuleSet.t(), keyword()) :: :ok
  def no_swallowed_errors(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, effects} = Rules.analyze(subject, opts)

    outside = %{
      returning: Errors.returning(code),
      dynamic: Errors.reaching_dynamic(code),
      effects: effects
    }

    fails? = &fails_outside?(&1, &2, outside)

    violations =
      for module <- modules,
          Mix.Task not in Code.behaviours(code, module),
          {key, info} <- Code.functions_of(code, module),
          not info.injected,
          violation <- swallowed(code, key, info, fails?) ++ ignored(code, key, info, fails?),
          do: violation

    Rules.report(violations, "no_swallowed_errors")
  end

  @doc """
  Asserts that no function in `subject` is a stub: one whose every clause only raises an error saying it isn't
  written yet, such as `raise "not implemented"` or a message with `TODO`, or only returns `:not_implemented` or
  `{:error, :not_implemented}`.
  """
  @spec no_stubs(ModuleSet.t(), keyword()) :: :ok
  def no_stubs(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, _effects} = Rules.analyze(subject, opts)

    violations =
      for module <- modules,
          {key, info} <- Code.functions_of(code, module),
          info.stub != nil and not info.injected do
        Rules.violation(code, "no_stubs", key,
          line: info.line,
          message: "is a stub: it only #{info.stub}",
          fix: "implement it, or remove it until something needs it"
        )
      end

    Rules.report(violations, "no_stubs")
  end

  @doc """
  Asserts that no function in `subject` is public only so tests can call it.

  A public function marked `@doc false` that no code in scope calls, but tests do, was most likely made public to
  test it, which ties the tests to the module's internals. Test it through the functions that use it, or move it
  into a module of its own whose API both the code and the tests use. The callbacks of a module's behaviours, with
  `@impl` or without, and `child_spec/1` and `start_link`, are skipped: frameworks and supervisors call them. A
  module whose behaviours' callbacks can't be read is skipped too.
  """
  @spec no_functions_only_tests_call(ModuleSet.t(), keyword()) :: :ok
  def no_functions_only_tests_call(%ModuleSet{} = subject, opts \\ []) do
    {modules, _code, _effects} = Rules.analyze(subject, opts)
    code = Code.load_scope(opts)
    called = called_by_code(code)

    tested =
      for test <- TestSource.load(opts).modules,
          %{target: target} <- test.calls,
          into: MapSet.new(),
          do: target

    violations =
      for module <- modules,
          %{hidden: hidden, impls: impls, behaviours: behaviours} <-
            List.wrap(code.modules[module]),
          {:ok, callbacks} <- [callbacks(behaviours, code)],
          {{^module, name, arity} = key, info} <- Code.functions_of(code, module),
          info.kind == :def and not info.injected and name not in @conventional,
          MapSet.member?(hidden, {name, arity}),
          not MapSet.member?(impls, {name, arity}) and
            not MapSet.member?(callbacks, {name, arity}),
          MapSet.member?(tested, key) and not MapSet.member?(called, key) do
        Rules.violation(code, "no_functions_only_tests_call", key,
          line: info.line,
          message: "is public only for tests: it's marked @doc false, and only tests call it",
          fix:
            "test it through the functions that use it, and make it private, " <>
              "or move it into a module of its own that both code and tests use"
        )
      end

    Rules.report(violations, "no_functions_only_tests_call")
  end

  # Only the project's own sources: not a dependency's, as a module a dependency's macro generates points to.
  defp own?(file) do
    Path.type(file) != :absolute and not String.starts_with?(file, ["deps/", "_build/"])
  end

  # The callbacks of every behaviour a module declares, from the behaviour's own BEAM file: the project's, read with
  # the code, or a dependency's, on the code path.
  defp callbacks(behaviours, code) do
    Enum.reduce_while(behaviours, {:ok, MapSet.new()}, fn behaviour, {:ok, acc} ->
      case callbacks_of(behaviour, code) do
        {:ok, callbacks} -> {:cont, {:ok, MapSet.union(acc, callbacks)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp callbacks_of(behaviour, code) do
    case code.modules do
      %{^behaviour => %{callbacks: callbacks}} ->
        {:ok, callbacks}

      _ ->
        with {:ok, callbacks} <- Typespec.fetch_callbacks(behaviour),
             do: {:ok, MapSet.new(callbacks, &elem(&1, 0))}
    end
  end

  # A handler is judged when what it handles can fail in the outside world: a call in the try, or the case's subject
  # or a with's right side that can return `{:error, _}`. A parse that returns `{:error, _}` for bad input, and a
  # default for it, isn't a failure hidden; neither is a predicate's `false`.
  defp swallowed(code, {_module, name, _arity} = key, info, fails?) do
    for %{line: line, handler: handler, returns: returns, sources: sources} <- info.swallows,
        Enum.any?(sources, &fails?.(&1, handler)),
        not (returns == "false" and String.ends_with?(Atom.to_string(name), "?")) do
      {message, fix} =
        case handler do
          :rescue ->
            {"rescues every exception and returns #{returns}",
             "rescue only the exceptions you expect and let the rest raise, or return {:error, reason}"}

          :catch ->
            {"catches everything thrown and returns #{returns}",
             "catch only what you expect and let the rest through, or return {:error, reason}"}

          :error ->
            {"turns any {:error, _} into #{returns}",
             "return the error, or handle only the reasons you expect"}
        end

      Rules.violation(code, "no_swallowed_errors", key,
        line: line,
        message: message <> ", so callers can't tell it failed",
        fix: fix
      )
    end
  end

  defp ignored(code, {module, _, _} = key, info, fails?) do
    for {target, line} <- info.discards, fails?.(target, :error) do
      Rules.violation(code, "no_swallowed_errors", key,
        line: line,
        callee: target,
        message: "ignores the {:error, _} that #{Rules.name(target, module)} can return",
        fix: "match the result, and handle or return the error"
      )
    end
  end

  # Whether a call can fail in the outside world, other than in releasing something: it raises or, for an error
  # handler, returns `{:error, _}`, and reaches I/O, or a module chosen at runtime, which may be anything.
  defp fails_outside?({:dynamic, name, _arity}, handler, _outside),
    do: handler != :error and name not in @releases

  defp fails_outside?({_module, name, _arity} = target, handler, outside) do
    name not in @releases and
      (handler != :error or Errors.returns_error?(target, outside.returning)) and
      (Rules.kind(target, @outside, outside.effects) != nil or
         MapSet.member?(outside.dynamic, target))
  end

  defp tests(subject, opts) do
    source = TestSource.load(opts)

    selected =
      subject |> ModuleSet.resolve(Map.new(source.modules, &{&1.name, []})) |> MapSet.new()

    Enum.filter(source.modules, &MapSet.member?(selected, &1.name))
  end

  # Every function some other function in scope calls.
  defp called_by_code(code) do
    for {caller, info} <- code.functions,
        %{target: target} <- info.calls,
        target != caller,
        into: MapSet.new(),
        do: target
  end

  # The suppressions in a source file, as `{module, line, text}`: the module is the innermost one around the line.
  defp suppressions(file, allowed) do
    source = File.read!(file)

    case Elixir.Code.string_to_quoted_with_comments(source, file: file, token_metadata: true) do
      {:ok, ast, comments} ->
        lines = String.split(source, "\n")
        ranges = module_ranges(ast, nil, [])

        (comment_suppressions(comments, allowed) ++ attribute_suppressions(ast, lines, allowed))
        |> Enum.map(fn {line, text} -> {module_at(ranges, line), line, text} end)

      {:error, _reason} ->
        []
    end
  end

  defp comment_suppressions(comments, allowed) do
    for %{line: line, text: text} <- comments,
        {tool, pattern} <- @comments,
        tool not in allowed and Regex.match?(pattern, text),
        do: {line, String.trim(text)}
  end

  defp attribute_suppressions(ast, lines, allowed) do
    ast
    |> Macro.prewalk([], fn
      {:@, meta, [{tool, _, [value]}]} = node, acc when tool in [:dialyzer, :compile] ->
        if tool not in allowed and silences?(tool, value),
          do: {node, [meta[:line] | acc]},
          else: {node, acc}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.map(&{&1, lines |> Enum.at(&1 - 1, "") |> String.trim()})
  end

  # `@dialyzer` options that turn warnings off start with `no`, as `:no_return` and `:nowarn_function` do, and
  # `@compile` ones with `no_warn` or `nowarn`, as `:no_warn_undefined` does.
  defp silences?(tool, value) do
    pattern = if tool == :dialyzer, do: ~r/^no/, else: ~r/^no_?warn/

    value
    |> Macro.prewalk([], fn
      atom, acc when is_atom(atom) -> {atom, [atom | acc]}
      node, acc -> {node, acc}
    end)
    |> elem(1)
    |> Enum.any?(&Regex.match?(pattern, Atom.to_string(&1)))
  end

  # Each `defmodule` with the lines it spans, innermost last.
  defp module_ranges({:defmodule, meta, [{:__aliases__, _, segments}, [do: body]]}, parent, acc) do
    module = if parent, do: Module.concat([parent | segments]), else: Module.concat(segments)
    last = get_in(meta, [:end, :line]) || meta[:line]
    module_ranges(body, module, [{module, meta[:line], last} | acc])
  end

  defp module_ranges({_form, _meta, args}, parent, acc) when is_list(args),
    do: module_ranges(args, parent, acc)

  defp module_ranges(list, parent, acc) when is_list(list),
    do: Enum.reduce(list, acc, &module_ranges(&1, parent, &2))

  defp module_ranges({left, right}, parent, acc),
    do: module_ranges(right, parent, module_ranges(left, parent, acc))

  defp module_ranges(_leaf, _parent, acc), do: acc

  defp module_at(ranges, line) do
    Enum.find_value(ranges, fn {module, first, last} ->
      if line >= first and line <= last, do: module
    end)
  end
end
