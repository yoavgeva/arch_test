defmodule ArchTest.API do
  @moduledoc """
  Rules about what public functions take and return: no booleans that pick what a function does, no identifiers a
  call can swap, no choices spelled as strings, and no options that change the kind of value returned. They read
  the code from the BEAM files' debug info, after macro expansion, as `ArchTest.Effects` does.

  ## Usage

      defmodule MyApp.APITest do
        use ExUnit.Case
        use ArchTest, app: :my_app
        use ArchTest.API

        test "no flag arguments" do
          no_flag_arguments(modules_matching("MyApp.**"), app: :my_app)
        end

        test "identifiers can't be swapped" do
          typed_identifiers(modules_matching("MyApp.Billing.**"), app: :my_app)
        end

        test "choices are atoms" do
          no_stringly_typed_choices(modules_matching("MyApp.**"), app: :my_app)
        end

        test "options don't change what a function returns" do
          no_alternative_return_types(modules_matching("MyApp.**"), app: :my_app)
        end
      end

  Callbacks, with `@impl`, and functions a macro defines are skipped: their signatures aren't the module's choice.
  """

  alias ArchTest.{Code, ModuleSet}
  alias ArchTest.Code.Rules

  @doc false
  defmacro __using__(_opts) do
    quote do
      import ArchTest.API
    end
  end

  @doc """
  Asserts that no public function in `subject` takes a boolean that picks what it does.

  A parameter is a flag when the function branches on it, with clauses matching `true` and `false` or an `if`,
  `unless` or `case` on it, and it's a boolean: a spec types it `boolean()`, its default is `true` or `false`, a
  clause matches `true` or `false` there, or a guard checks `is_boolean/1`. A call such as `render(text, true)`
  doesn't say what `true` means, and the function does two things. Keyword options, such as `html: true`, name
  themselves, and pass.
  """
  @spec no_flag_arguments(ModuleSet.t(), keyword()) :: :ok
  def no_flag_arguments(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, _effects} = Rules.analyze(subject, opts)

    violations =
      for module <- modules,
          {key, info} <- public(code, module),
          flag <- info.signature.flags do
        named = if flag.name, do: "`#{flag.name}`, a boolean", else: "a boolean"

        Rules.violation(code, "no_flag_arguments", key,
          line: flag.line,
          message:
            "takes #{named} that picks what it does: a call passing true or false doesn't say which",
          fix:
            "split it into one function for each thing it does, named for it, or take an atom that names the choice"
        )
      end

    Rules.report(violations, "no_flag_arguments")
  end

  @doc """
  Asserts that no public function in `subject` takes more than one identifier as separate parameters.

  Parameters named `id` or `*_id`, such as `transfer(from_account_id, to_account_id, amount)`, are all integers or
  strings, so a call that swaps two of them runs, and reads or changes the wrong records. Take the records instead,
  matching their structs, so a swap fails, or name the identifiers in a keyword list. A single identifier, as
  `get_user!(id)` takes, can't be swapped, and passes.

  Most Elixir code passes identifiers around, so point this rule at the code where a mix-up costs most, such as
  billing or permissions.
  """
  @spec typed_identifiers(ModuleSet.t(), keyword()) :: :ok
  def typed_identifiers(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, _effects} = Rules.analyze(subject, opts)

    violations =
      for module <- modules,
          {key, info} <- public(code, module),
          ids = Enum.filter(info.signature.params, &identifier?/1),
          length(ids) > 1 do
        Rules.violation(code, "typed_identifiers", key,
          line: info.line,
          message:
            "takes #{joined(ids)}, identifiers of one type: a call that swaps them runs, " <>
              "and reads or changes the wrong records",
          fix:
            "take the records, as `#{record(hd(ids))}` does, or name the identifiers in a keyword list"
        )
      end

    Rules.report(violations, "typed_identifiers")
  end

  @doc """
  Asserts that no function in `subject` chooses between three or more string literals.

  Clauses matching `"standard"`, `"express"` and `"overnight"`, or a `case` with those strings, are an atom in
  disguise: a typo such as `"expres"` compiles, and nothing lists the choices. Turn the string into an atom where it
  enters the code, in one function, and match atoms everywhere else. That function, whose every choice returns an
  atom, `{:ok, atom}` or `:error`, passes, and so do callbacks such as `handle_event/3`, whose events are strings.
  """
  @spec no_stringly_typed_choices(ModuleSet.t(), keyword()) :: :ok
  def no_stringly_typed_choices(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, _effects} = Rules.analyze(subject, opts)

    violations =
      for module <- modules,
          {key, info} <- written(code, module),
          choice <- info.signature.choices do
        Rules.violation(code, "no_stringly_typed_choices", key,
          line: choice.line,
          message:
            "chooses between #{listed(choice.strings)}: a typo compiles, and nothing lists the choices",
          fix:
            "turn the string into an atom where it enters the code, in one function, and match atoms everywhere else"
        )
      end

    Rules.report(violations, "no_stringly_typed_choices")
  end

  @doc """
  Asserts that no function in `subject` returns a different kind of value depending on an option.

  From Elixir's [design anti-patterns](https://hexdocs.pm/elixir/design-anti-patterns.html): an `if` or `case` on an
  option read from a keyword parameter, as `Keyword.get(opts, :discard_rest)` or `opts[:raw]`, whose branches return
  values of different kinds, such as a bare value and a tuple. Callers can't rely on what the function returns
  without knowing its options. Split it into one function for each kind of value. Errors, which any function may
  return, and calls, whose kind the code doesn't say, don't count.
  """
  @spec no_alternative_return_types(ModuleSet.t(), keyword()) :: :ok
  def no_alternative_return_types(%ModuleSet{} = subject, opts \\ []) do
    {modules, code, _effects} = Rules.analyze(subject, opts)

    violations =
      for module <- modules,
          {key, info} <- written(code, module),
          alternative <- info.signature.alternatives do
        Rules.violation(code, "no_alternative_return_types", key,
          line: alternative.line,
          message:
            "returns a different kind of value depending on its #{inspect(alternative.option)} option, so callers " <>
              "can't rely on what it returns",
          fix: "split it into one function for each kind of value it returns, named for it"
        )
      end

    Rules.report(violations, "no_alternative_return_types")
  end

  # The functions the module's authors wrote: not injected by a macro, not generated, as `__match_route__/3` and other
  # functions named `__name__` are, and not callbacks.
  defp written(code, module) do
    impls = get_in(code.modules, [module, :impls]) || MapSet.new()

    for {{^module, name, arity} = key, info} <- Code.functions_of(code, module),
        not info.injected,
        not String.starts_with?(Atom.to_string(name), "__"),
        not MapSet.member?(impls, {name, arity}),
        do: {key, info}
  end

  defp public(code, module),
    do: Enum.filter(written(code, module), fn {_key, info} -> info.kind == :def end)

  defp identifier?(nil), do: false

  defp identifier?(name) do
    name = Atom.to_string(name)
    name == "id" or String.ends_with?(name, "_id")
  end

  # `%Account{} = account` for `from_account_id`: the record the identifier names.
  defp record(id) do
    case id
         |> Atom.to_string()
         |> String.replace_suffix("_id", "")
         |> String.split("_")
         |> List.last() do
      "id" -> "%Record{} = record"
      noun -> "%#{Macro.camelize(noun)}{} = #{noun}"
    end
  end

  defp joined(names) do
    {init, [last]} = Enum.split(names, -1)
    Enum.join(init, ", ") <> " and #{last}"
  end

  defp listed(strings) do
    {shown, rest} = Enum.split(strings, 3)
    quoted = Enum.map(shown, &inspect/1)
    more = if rest == [], do: "", else: " and #{length(rest)} more"

    case quoted do
      [a, b, c] when more == "" -> "#{a}, #{b} and #{c}"
      _ -> Enum.join(quoted, ", ") <> more
    end
  end
end
