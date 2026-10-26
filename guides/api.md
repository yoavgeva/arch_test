# API

`ArchTest.API` checks what public functions take and return. Like `ArchTest.Effects`, it reads your code from the
BEAM files' debug info, after macro expansion. Callbacks, marked `@impl`, functions a macro defines, and generated
functions named `__name__` are skipped: their signatures aren't the module's choice.

```elixir
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
```

---

## 1. No flag arguments

A boolean that picks what a function does means the function does two things, and a call like `render(text, true)`
doesn't say which.

```elixir
# flagged
def render(text, html) when is_boolean(html) do
  if html, do: "<p>" <> text <> "</p>", else: String.trim(text)
end

# fixed
def render_html(text), do: "<p>" <> text <> "</p>"
def render_text(text), do: String.trim(text)
```

`no_flag_arguments/2` flags a public function's parameter when:

- it's a boolean: a spec types it `boolean()`, its default is `true` or `false`, a clause matches `true` or `false`
  there, or a guard checks `is_boolean/1`;
- and the function branches on it: clauses match both `true` and `false` there, or an `if`, `unless` or `case`
  tests it.

A parameter that clauses also match with `nil`, an optional boolean an encoder turns into data, passes. So do keyword
options, such as `html: true`, which name themselves.

---

## 2. Typed identifiers

Ids are integers or strings, so a call that swaps two of them runs, and reads or changes the wrong records.

```elixir
# flagged: transfer(to, from, amount) runs too
def transfer(from_account_id, to_account_id, amount), do: ...

# fixed: a swap fails to match
def transfer(%Account{} = from, %Account{} = to, amount), do: ...
```

`typed_identifiers/2` flags public functions taking two or more parameters named `id` or `*_id`. Take the records,
matching their structs, or name the identifiers in a keyword list. A single id, as `get_user!(id)` takes, can't be
swapped.

Most Elixir code passes ids around, so this rule isn't in `ArchTest.Recommended`: point it at the code where a mix-up
costs most, such as billing or permissions.

---

## 3. No stringly typed choices

Three strings matched in clause heads or a `case` are an atom in disguise: a typo such as `"expres"` compiles, and
nothing lists the choices.

```elixir
# flagged
def days("standard"), do: 5
def days("express"), do: 2
def days("overnight"), do: 1

# fixed: parse the string once, where it enters, and match atoms
def parse_speed("standard"), do: {:ok, :standard}
def parse_speed("express"), do: {:ok, :express}
def parse_speed("overnight"), do: {:ok, :overnight}
def parse_speed(_other), do: :error
```

`no_stringly_typed_choices/2` flags three or more distinct string literals in one function's clause heads, at one
position, or in one `case`. A parser, whose every choice returns an atom, `{:ok, atom}` or `:error`, passes, and so do
callbacks such as `handle_event/3`, whose event names are strings. Values stored as strings, such as a notification's
type, are what `Ecto.Enum` is for.

---

## 4. No alternative return types

From Elixir's [design anti-patterns](https://hexdocs.pm/elixir/design-anti-patterns.html): an option that changes
the kind of value a function returns makes every caller check which kind came back.

```elixir
# flagged
def parse(text, options \\ []) do
  {quantity, rest} = Integer.parse(text)
  if Keyword.get(options, :discard_rest, false), do: quantity, else: {quantity, rest}
end

# fixed
def parse(text), do: text |> Integer.parse() |> elem(0)
def parse_with_rest(text), do: Integer.parse(text)
```

`no_alternative_return_types/2` flags an `if` or `case` on an option, read with `Keyword.get/2,3`,
`Keyword.fetch/2`, `Keyword.fetch!/2` or `opts[:key]` from a parameter named `opts` or `options`, whose branches
return different kinds of value: a tuple, a list or a map, and something else. Errors, which any function may return,
calls, whose kind the code doesn't say, and a default for a missing option, as `opts[:limit] || 10`, don't count.
