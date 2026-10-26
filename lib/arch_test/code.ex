defmodule ArchTest.Code do
  @moduledoc false
  # A project's compiled Elixir code, read from the `:elixir_v1` debug info of its BEAM files: every function's
  # calls, with the loop each one runs in, and each module's behaviours and source file. Debug info holds the
  # code after macro expansion, with aliases and imports resolved, so `Repo.get!(User, id)` is a call to
  # `MyApp.Repo.get!/2`. Reading starts at the modules a rule checks and follows their calls into the other
  # modules in scope, so a rule reads only the code it can reach.

  alias ArchTest.Code.Walker
  alias ArchTest.Collector

  defstruct modules: %{}, functions: %{}

  @type key :: {module(), atom(), arity()}
  @type call :: %{
          target: key(),
          line: pos_integer() | nil,
          loop: String.t() | nil,
          per_item: boolean()
        }
  @type function_info :: %{kind: :def | :defp, line: pos_integer() | nil, calls: [call()]}
  @type module_info :: %{file: String.t() | nil, behaviours: [module()]}
  @type t :: %__MODULE__{
          modules: %{module() => module_info()},
          functions: %{key() => function_info()}
        }

  @doc false
  # Reads `modules` and every module in scope their calls reach. The scope is the `:paths`, `:apps` or `:app` in
  # `opts`, or else the ebin directories that hold `modules`.
  @spec load([module()], keyword()) :: t()
  def load(modules, opts) do
    reach(modules, beams_in_scope(modules, opts), %__MODULE__{})
  end

  @doc false
  # The module's functions, sorted, as `{key, function_info}` pairs.
  @spec functions_of(t(), module()) :: [{key(), function_info()}]
  def functions_of(%__MODULE__{functions: functions}, module) do
    functions
    |> Enum.filter(fn {{owner, _name, _arity}, _info} -> owner == module end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc false
  @spec behaviours(t(), module()) :: [module()]
  def behaviours(%__MODULE__{modules: modules}, module) do
    modules |> Map.get(module, %{behaviours: []}) |> Map.fetch!(:behaviours)
  end

  @doc false
  # The module's source file, relative to the working directory when it lies inside it.
  @spec file(t(), module()) :: String.t() | nil
  def file(%__MODULE__{modules: modules}, module) do
    case modules do
      %{^module => %{file: file}} when is_binary(file) -> Path.relative_to_cwd(file)
      _ -> nil
    end
  end

  defp reach([], _beams, code), do: code

  defp reach([module | rest], beams, code) do
    with false <- Map.has_key?(code.modules, module),
         {:ok, beam} <- Map.fetch(beams, module),
         {:ok, read} <- read(module, beam) do
      reached =
        for {_key, info} <- read.functions, %{target: {target, _, _}} <- info.calls, do: target

      reach(Enum.uniq(reached) ++ rest, beams, add(code, module, read))
    else
      _ -> reach(rest, beams, code)
    end
  end

  defp add(code, module, read) do
    %{
      code
      | modules: Map.put(code.modules, module, Map.take(read, [:file, :behaviours])),
        functions: Map.merge(code.functions, read.functions)
    }
  end

  defp beams_in_scope(modules, opts) do
    app = Keyword.get(opts, :app, :all)

    directories =
      if app == :all and not Keyword.has_key?(opts, :paths) and not Keyword.has_key?(opts, :apps) do
        modules
        |> Enum.map(&:code.which/1)
        |> Enum.filter(&is_list/1)
        |> Enum.map(&Path.dirname/1)
        |> Enum.uniq()
      else
        Collector.beam_paths(app, opts)
      end

    for directory <- directories, file <- beam_files(directory), into: %{} do
      {file |> Path.basename(".beam") |> String.to_atom(), Path.join(directory, file)}
    end
  end

  defp beam_files(directory) do
    case File.ls(directory) do
      {:ok, files} -> Enum.filter(files, &String.ends_with?(&1, ".beam"))
      {:error, _} -> []
    end
  end

  # Reading a module is cached by the content of its BEAM file, so every rule in a test run reads it once.
  defp read(module, beam) do
    binary = File.read!(beam)
    cache_key = {__MODULE__, module, :erlang.md5(binary)}

    case :persistent_term.get(cache_key, :not_found) do
      :not_found ->
        result = read_binary(module, binary)
        :persistent_term.put(cache_key, result)
        result

      result ->
        result
    end
  end

  defp read_binary(module, binary) do
    with {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(binary, [:debug_info]),
         {:ok, info} <- backend.debug_info(:elixir_v1, module, data, []) do
      {:ok,
       %{
         file: info.file,
         behaviours: behaviours_in(binary),
         functions: functions(module, info.definitions)
       }}
    else
      _ -> :error
    end
  end

  defp behaviours_in(binary) do
    case :beam_lib.chunks(binary, [:attributes]) do
      {:ok, {_module, [attributes: attributes]}} ->
        for {name, values} <- attributes,
            name in [:behaviour, :behavior],
            value <- values,
            do: value

      _ ->
        []
    end
  end

  defp functions(module, definitions) do
    locals =
      for {{name, arity}, kind, _meta, _clauses} <- definitions,
          kind in [:def, :defp],
          into: MapSet.new(),
          do: {name, arity}

    for {{name, arity}, kind, meta, clauses} <- definitions, kind in [:def, :defp], into: %{} do
      {{module, name, arity},
       %{kind: kind, line: meta[:line], calls: Walker.calls(clauses, module, locals)}}
    end
  end
end
