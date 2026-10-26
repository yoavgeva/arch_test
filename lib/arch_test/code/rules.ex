defmodule ArchTest.Code.Rules do
  @moduledoc false
  # What the rules built on `ArchTest.Code` share: reading the code a subject reaches, naming functions in
  # messages, and building and reporting violations.

  alias ArchTest.{Assertions, Code, Collector, ModuleSet, Violation}
  alias ArchTest.Code.Effects

  # Kernel functions that compile to `:erlang` calls, named in messages as written.
  @kernel [:send, :spawn, :spawn_link, :spawn_monitor, :self, :exit]

  @doc false
  # The subject's modules, sorted, the code they reach, and its effects.
  @spec analyze(ModuleSet.t(), keyword()) :: {[module()], Code.t(), Effects.effects()}
  def analyze(subject, opts) do
    graph =
      Keyword.get_lazy(opts, :graph, fn ->
        Collector.build_graph(Keyword.get(opts, :app, :all), opts)
      end)

    modules = subject |> ModuleSet.resolve(graph) |> Enum.sort()
    code = Code.load(modules, opts)

    {modules, code, Effects.of(code)}
  end

  @doc false
  # The first of `kinds` that `target` is a seed of, or reaches.
  @spec kind(Code.key(), [Effects.kind()], Effects.effects()) :: Effects.kind() | nil
  def kind(target, kinds, effects) do
    Enum.find(kinds, &(Effects.seed(target) == &1 or Map.has_key?(effects[target] || %{}, &1)))
  end

  @doc false
  # A call that opens a transaction: Ecto.Multi.run, or transaction/transact on a repo, which declares the Ecto.Repo
  # behaviour or reaches Ecto.Repo.Transaction, as a facade over one does.
  @spec transaction?(Code.key(), Code.t(), Effects.effects()) :: boolean()
  def transaction?({Ecto.Multi, :run, _arity}, _code, _effects), do: true

  def transaction?({module, _name, _arity} = target, code, effects) do
    Ecto.Repo in Code.behaviours(code, module) or module == Ecto.Repo.Transaction or
      reaches_transaction?(effects[target][:db_write])
  end

  defp reaches_transaction?([_ | _] = path),
    do: path |> List.last() |> Map.fetch!(:target) |> elem(0) == Ecto.Repo.Transaction

  defp reaches_transaction?(_path), do: false

  @doc false
  # How a message names `target`, called from `caller`: `load/1` for the caller's own functions, `send/2` for
  # Kernel's, and `MyApp.Repo.get!/2` for the rest.
  @spec name(Code.key(), module()) :: String.t()
  def name({module, name, arity}, module), do: "#{name}/#{arity}"
  def name({:erlang, name, arity}, _caller) when name in @kernel, do: "#{name}/#{arity}"
  def name({module, name, arity}, _caller), do: "#{inspect(module)}.#{name}/#{arity}"

  @doc false
  @spec step(Code.call()) :: Effects.step()
  def step(call), do: %{target: call.target, line: call.line}

  @doc false
  # `, which reaches MyApp.Repo.get!/2` when a path's call reaches its effect through other functions.
  @spec reaching([Effects.step()], Code.key(), module()) :: String.t()
  def reaching(path, target, module) do
    case Effects.reached(path) do
      ^target -> ""
      reached -> ", which reaches #{name(reached, module)}"
    end
  end

  @doc false
  # A violation in `function`, at the `:line` of `details`, optionally about a `:callee`.
  @spec violation(Code.t(), String.t(), Code.key(), keyword()) :: Violation.t()
  def violation(code, rule, {module, name, arity}, details) do
    {callee, callee_function} =
      case Keyword.get(details, :callee) do
        {target, target_name, target_arity} -> {target, {target_name, target_arity}}
        nil -> {nil, nil}
      end

    %Violation{
      type: :custom,
      rule: rule,
      module: module,
      caller: module,
      caller_function: {name, arity},
      callee: callee,
      callee_function: callee_function,
      file: Code.file(code, module),
      line: Keyword.fetch!(details, :line),
      message: Keyword.fetch!(details, :message),
      fix: Keyword.fetch!(details, :fix)
    }
  end

  @doc false
  @spec report([Violation.t()], String.t()) :: :ok
  def report(violations, rule) do
    violations
    |> Enum.sort_by(&{&1.file, &1.line, &1.caller_function})
    |> Assertions.assert_no_violations_public(rule)
  end
end
