defmodule ArchTest.TestSource do
  @moduledoc false
  # A project's tests, read from source: ExUnit compiles test files in memory as it runs them, so nothing on disk
  # holds their code. Each test module comes with what its code calls and references, with aliases resolved, the
  # mocks it sets up, whether it runs async, and the test or setup each call is in. `Mox.defmock/2` declarations
  # anywhere in the test paths map each Mox mock to the behaviours it stands for.

  defstruct modules: [], mocks: %{}, support: %{}

  @type call :: %{
          target: {module() | :local, atom(), arity()},
          line: pos_integer() | nil,
          label: String.t(),
          argument: atom() | integer() | nil,
          key_module: module() | nil,
          callback: boolean()
        }
  @type mock :: %{
          module: module(),
          function: atom() | nil,
          line: pos_integer() | nil,
          label: String.t()
        }
  @type test_module :: %{
          name: module(),
          file: String.t(),
          line: pos_integer() | nil,
          async: boolean(),
          tests: boolean(),
          calls: [call()],
          references: [module()],
          mocks: [mock()],
          imports: [{module(), [{atom(), arity()}] | nil}]
        }
  @type t :: %__MODULE__{
          modules: [test_module()],
          mocks: %{module() => [module()]},
          support: %{module() => [call()]}
        }

  # Mimic's, Mox's and Mock's functions that replace a module's functions, and the argument that names it.
  @mocking %{
    stub: 0,
    expect: 0,
    reject: 0,
    stub_with: 0,
    copy: 0,
    with_mock: 0,
    test_with_mock: 1
  }
  @mock_libraries [Mimic, Mox, Mock]

  @doc false
  # The test modules in the `*_test.exs` files under `opts[:test_paths]` (default `["test"]`), and the Mox mocks
  # declared in any file there.
  @spec load(keyword()) :: t()
  def load(opts) do
    files =
      opts
      |> Keyword.get(:test_paths, ["test"])
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.{ex,exs}")))
      |> Enum.uniq()
      |> Enum.sort()

    parsed = Enum.map(files, &read/1)

    {tests, support} =
      Enum.split_with(parsed, fn {file, _modules, _mocks} ->
        String.ends_with?(file, "_test.exs")
      end)

    %__MODULE__{
      modules: for({_file, modules, _mocks} <- tests, module <- modules, do: module),
      mocks: parsed |> Enum.flat_map(&elem(&1, 2)) |> Map.new(),
      # Helpers in the test paths, such as `test/support` modules a test calls, with what they call.
      support:
        for(
          {_file, modules, _mocks} <- support,
          module <- modules,
          into: %{},
          do: {module.name, module.calls}
        )
    }
  end

  defp read(file) do
    source = File.read!(file)
    cache_key = {__MODULE__, file, :erlang.md5(source)}

    case :persistent_term.get(cache_key, :not_found) do
      :not_found ->
        result = parse(file, source)
        :persistent_term.put(cache_key, result)
        result

      result ->
        result
    end
  end

  defp parse(file, source) do
    case Code.string_to_quoted(source, file: file) do
      {:ok, ast} ->
        state = walk(ast, new_state(file, nil, nil))
        {file, Enum.reverse(state.done), state.defmocks}

      {:error, _reason} ->
        {file, [], []}
    end
  end

  defp new_state(file, module, line) do
    %{
      file: file,
      module: module,
      line: line,
      aliases: %{},
      label: "the test module",
      async: false,
      tests: false,
      calls: [],
      references: [],
      mocks: [],
      imports: [],
      callback: false,
      done: [],
      defmocks: []
    }
  end

  defp walk({:defmodule, meta, [name, [do: body]]}, state) do
    module = resolve(name, state)
    inner = walk(body, %{new_state(state.file, module, meta[:line]) | aliases: state.aliases})

    %{
      state
      | done: [finish(inner) | inner.done ++ state.done],
        defmocks: inner.defmocks ++ state.defmocks
    }
  end

  defp walk({:alias, _, [target | options]}, state),
    do: %{state | aliases: aliases(target, options, state)}

  defp walk({:use, _, [target | options]}, state) do
    async = options |> List.flatten() |> Keyword.get(:async, false) == true

    %{
      state
      | async: state.async or async,
        references: [resolve(target, state) | state.references]
    }
  end

  # An import, with the functions its `only:` names, or `nil` when it names none.
  defp walk({:import, _, [target | options]}, state) do
    module = resolve(target, state)
    only = options |> List.flatten() |> Keyword.get(:only)
    only = if is_list(only), do: only

    %{state | references: [module | state.references], imports: [{module, only} | state.imports]}
  end

  defp walk({:test, _, [name | rest]}, state) when is_binary(name),
    do: labelled(rest, ~s(test "#{name}"), %{state | tests: true})

  defp walk({setup, _, args}, state) when setup in [:setup, :setup_all],
    do: labelled(args, "#{setup}", state)

  defp walk({kind, _, [head | body]}, state) when kind in [:def, :defp] do
    {name, args} = head(head)
    labelled(body, "#{label(name)}/#{length(args)}", state)
  end

  defp walk({:fn, _, clauses}, state),
    do: %{walk(clauses, %{state | callback: true}) | callback: state.callback}

  # A HEEx template's remote components, as `<MyAppWeb.Components.badge />`, name their modules.
  defp walk({:sigil_H, _, [{:<<>>, _, parts} | _]}, state) do
    named =
      for part <- parts,
          is_binary(part),
          [_, path] <- Regex.scan(~r/<\.?((?:[A-Z]\w*\.)+)[a-z_]\w*/, part),
          segments =
            path |> String.trim_trailing(".") |> String.split(".") |> Enum.map(&String.to_atom/1),
          do: resolve({:__aliases__, [], segments}, state)

    %{state | references: named ++ state.references}
  end

  defp walk({:|>, _, [left, right]}, state), do: call(right, 1, walk(left, state))

  defp walk({:&, _, [{:/, _, [{{:., _, [target, name]}, _, []}, arity]}]}, state)
       when is_integer(arity) do
    case module_of(target, state) do
      nil -> state
      module -> add_call(state, {module, name, arity}, nil)
    end
  end

  defp walk({{:., _, [_target, name]}, _, args} = node, state)
       when is_atom(name) and is_list(args),
       do: call(node, 0, state)

  defp walk({name, _, args} = node, state)
       when is_atom(name) and is_list(args) and name != :__aliases__,
       do: call(node, 0, state)

  defp walk({:__aliases__, _, _} = alias, state),
    do: %{state | references: [resolve(alias, state) | state.references]}

  defp walk({form, _meta, args}, state) when is_list(args), do: walk(args, walk(form, state))
  defp walk({left, right}, state), do: walk(right, walk(left, state))
  defp walk(list, state) when is_list(list), do: Enum.reduce(list, state, &walk/2)
  defp walk(_leaf, state), do: state

  defp labelled(ast, label, state), do: %{walk(ast, %{state | label: label}) | label: state.label}

  # A name the code computes, as `def unquote(verb)(conn)` does, is labelled as written.
  defp label(name) when is_atom(name), do: name
  defp label({:unquote, _, [name]}) when is_atom(name), do: name
  defp label(name), do: Macro.to_string(name)

  defp head({:when, _, [head | _guards]}), do: head(head)
  defp head({name, _, args}) when is_list(args), do: {name, args}
  defp head({name, _, _context}), do: {name, []}

  # A call, given `extra` arguments by a pipe: what it calls, the mocks it sets up, and what its arguments use.
  defp call({{:., meta, [target, name]}, _, args}, extra, state) when is_list(args) do
    case module_of(target, state) do
      nil ->
        walk(args, walk(target, state))

      Mox when name == :defmock ->
        defmock(args, state)

      module ->
        state = add_call(state, {module, name, length(args) + extra}, meta[:line], args)

        if module in @mock_libraries,
          do: mocking(name, args, meta, state),
          else: walk_args(args, module, state)
    end
  end

  defp call({name, meta, args}, extra, state) when is_atom(name) and is_list(args) do
    state = add_call(state, {:local, name, length(args) + extra}, meta[:line])
    mocking(name, args, meta, state)
  end

  defp call(other, _extra, state), do: walk(other, state)

  # The module a mocking call names, recorded as a mock rather than a use of it.
  defp mocking(name, args, meta, state) do
    with {:ok, position} <- Map.fetch(@mocking, name),
         {:__aliases__, _, _} = target <- Enum.at(args, position) do
      function =
        case Enum.at(args, position + 1) do
          name when is_atom(name) -> name
          _other -> nil
        end

      mock = %{
        module: resolve(target, state),
        function: function,
        line: meta[:line],
        label: state.label
      }

      walk(List.delete_at(args, position), %{state | mocks: [mock | state.mocks]})
    else
      _ -> walk_args(args, :local, state)
    end
  end

  # A function the test makes runs as a callback, in a fake, a server or another process, rather than in the test's
  # own flow, unless it's given to `Enum` or `Stream`, which run it right there.
  defp walk_args(args, module, state) do
    Enum.reduce(args, state, fn
      {:fn, _, clauses}, acc when module in [Enum, Stream] -> walk(clauses, acc)
      arg, acc -> walk(arg, acc)
    end)
  end

  # The module a key names, as `{Step, :version}` and `Step` do: state a test file's own module owns.
  defp key_module([{:__aliases__, _, _} = alias | _], state), do: resolve(alias, state)
  defp key_module([{{:__aliases__, _, _} = alias, _} | _], state), do: resolve(alias, state)

  defp key_module([{:{}, _, [{:__aliases__, _, _} = alias | _]} | _], state),
    do: resolve(alias, state)

  defp key_module(_args, _state), do: nil

  defp defmock([name, options], state) when is_list(options) do
    behaviours = options |> Keyword.get(:for, []) |> List.wrap() |> Enum.map(&resolve(&1, state))
    %{state | defmocks: [{resolve(name, state), behaviours} | state.defmocks]}
  end

  defp defmock(_args, state), do: state

  # A call, with its first argument when that's a literal atom or number, such as the `:infinity` of a sleep that
  # parks a process.
  defp add_call(state, target, line, args \\ []) do
    argument =
      case args do
        [first | _] when is_atom(first) or is_integer(first) -> first
        _ -> nil
      end

    call = %{
      target: target,
      line: line,
      label: state.label,
      argument: argument,
      key_module: key_module(args, state),
      callback: state.callback
    }

    %{state | calls: [call | state.calls]}
  end

  defp finish(state) do
    %{
      name: state.module,
      file: state.file,
      line: state.line,
      async: state.async,
      tests: state.tests,
      calls: Enum.reverse(state.calls),
      references: state.references |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      mocks: Enum.reverse(state.mocks),
      imports: Enum.reject(state.imports, &is_nil(elem(&1, 0)))
    }
  end

  defp aliases({{:., _, [base, :{}]}, _, children}, _options, state) do
    base = resolve(base, state)

    Enum.reduce(children, state.aliases, fn {:__aliases__, _, segments}, acc ->
      Map.put(acc, List.last(segments), Module.concat([base | segments]))
    end)
  end

  defp aliases({:__aliases__, _, segments} = target, options, state) do
    as =
      case options |> List.flatten() |> Keyword.get(:as) do
        {:__aliases__, _, [as]} -> as
        _ -> List.last(segments)
      end

    Map.put(state.aliases, as, resolve(target, state))
  end

  defp aliases(_target, _options, state), do: state.aliases

  defp module_of(target, _state) when is_atom(target), do: target
  defp module_of({:__MODULE__, _, _}, state), do: state.module
  defp module_of({:__aliases__, _, _} = target, state), do: resolve(target, state)
  defp module_of(_target, _state), do: nil

  defp resolve({:__aliases__, _, [{:__MODULE__, _, _} | rest]}, state),
    do: Module.concat([state.module | rest])

  defp resolve({:__aliases__, _, [first | rest]}, state) when is_atom(first) do
    case Map.fetch(state.aliases, first) do
      {:ok, module} -> Module.concat([module | rest])
      :error -> Module.concat([first | rest])
    end
  end

  defp resolve({:__MODULE__, _, _}, state), do: state.module
  defp resolve(atom, _state) when is_atom(atom), do: atom
  defp resolve(_other, _state), do: nil
end
