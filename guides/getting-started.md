# Getting Started with ArchTest

ArchTest is an ArchUnit-inspired architecture testing library for Elixir. You write ordinary ExUnit tests that assert structural rules about your codebase — dependency direction, naming conventions, bounded-context isolation, cycle freedom — and get clear, actionable failures when those rules are broken.

Everything works from compiled BEAM bytecode via OTP's `:xref`. No source parsing, no reflection hacks. If it compiled, ArchTest can analyse it.

---

## 1. Add the dependency

```elixir
# mix.exs
defp deps do
  [
    {:arch_test, "~> 0.2", only: :test, runtime: false}
  ]
end
```

```sh
mix deps.get
```

---

## 2. Create your architecture test file

If you use [Igniter](https://hex.pm/packages/igniter), you can scaffold a file instantly:

| Command | What it generates |
|---------|-------------------|
| `mix igniter.install arch_test` | Basic arch test file with a cycle check |
| `mix arch_test.gen.phoenix` | Opinionated Phoenix setup — layers + naming + conventions ([Phoenix directory structure](https://hexdocs.pm/phoenix/directory_structure.html) · [N-tier architecture](https://en.wikipedia.org/wiki/Multitier_architecture)) |
| `mix arch_test.gen.layers` | [Classic web → context → repo layers](layered-architecture.md) ([N-tier architecture](https://en.wikipedia.org/wiki/Multitier_architecture)) |
| `mix arch_test.gen.onion` | [Onion / hexagonal rings](layered-architecture.md#onion--hexagonal-architecture) ([Onion Architecture](https://jeffreypalermo.com/2008/07/the-onion-architecture-part-1/) · [Hexagonal / Ports & Adapters](https://alistair.cockburn.us/hexagonal-architecture/)) |
| `mix arch_test.gen.modulith` | [Bounded-context slice isolation](modulith-rules.md) ([Modular Monolith Primer](https://www.kamilgrzybek.com/blog/posts/modular-monolith-primer)) |
| `mix arch_test.gen.naming` | Naming rules — no Managers, schema namespace placement |
| `mix arch_test.gen.conventions` | Code hygiene — no `IO.puts`, `dbg`, bare `raise` |
| `mix arch_test.gen.freeze` | [Freeze baseline for gradual adoption](freezing.md) |

Add Igniter as a dev dependency first: `{:igniter, "~> 0.7", only: [:dev, :test], runtime: false}`.

Or write the file by hand:

```elixir
# test/architecture_test.exs
defmodule MyApp.ArchitectureTest do
  use ExUnit.Case
  use ArchTest

  test "services don't call repos directly" do
    modules_matching("MyApp.**.*Service")
    |> should_not_depend_on(modules_matching("MyApp.**.*Repo"))
  end

  test "no Manager modules exist" do
    modules_matching("MyApp.**.*Manager") |> should_not_exist()
  end

  test "no circular dependencies" do
    modules_matching("MyApp.**") |> should_be_free_of_cycles()
  end
end
```

Run with `mix test`. Each `test` block is a standalone ExUnit test — you get normal pass/fail output and clear violation messages on failure.

---

## 3. How it works

On the first architecture test in a suite, ArchTest builds a dependency graph using OTP's `:xref` by scanning all loaded BEAM files. The graph is cached in `:persistent_term` for the rest of the test run, so subsequent tests add no overhead.

Rules are evaluated against the graph and any violations surface as assertion failures with a full list of offending dependencies:

```
  1) test services don't call repos directly (MyApp.ArchitectureTest)
     Architecture rule violated (should_not_depend_on) — 2 violation(s):

       MyApp.Accounts.RegistrationService → MyApp.Accounts.UserRepo
         MyApp.**.*Service must not depend on MyApp.**.*Repo

       MyApp.Orders.CheckoutService → MyApp.Orders.OrderRepo
         MyApp.**.*Service must not depend on MyApp.**.*Repo
```

---

## 4. Select modules

The DSL starts with a module set — a selection of modules from your app.

```elixir
# All descendants of a namespace
modules_matching("MyApp.Orders.**")

# Only direct children
modules_matching("MyApp.Orders.*")

# Last segment matches a glob
modules_matching("**.*Service")        # ends with Service
modules_matching("**.*Service*")       # contains Service anywhere

# Shorthand for "MyApp.Orders.*"
modules_in("MyApp.Orders")

# Everything
all_modules()

# Custom predicate
modules_satisfying(fn mod ->
  function_exported?(mod, :__schema__, 1)
end)
```

### Composing sets

```elixir
# Exclude
modules_matching("MyApp.**")
|> excluding("MyApp.Web.*")

# Union
modules_matching("**.*Service")
|> union(modules_matching("**.*View"))

# Intersection
modules_matching("MyApp.**")
|> intersection(modules_matching("**.*Schema"))
```

---

## 5. Assert dependency rules

Pipe a module set into an assertion:

```elixir
# Forbid a dependency
modules_matching("MyApp.Domain.**")
|> should_not_depend_on(modules_matching("MyApp.Web.**"))

# Allowlist (anything outside the set is forbidden)
modules_matching("MyApp.Web.**")
|> should_only_depend_on(modules_matching("MyApp.Domain.**"))

# Reverse direction — restrict who may call something
modules_matching("MyApp.Repo")
|> should_only_be_called_by(modules_matching("MyApp.Domain.**"))

# Transitive closure
modules_matching("MyApp.Domain.**")
|> should_not_transitively_depend_on(modules_matching("Ecto.**"))

# No cycles
modules_matching("MyApp.**") |> should_be_free_of_cycles()
```

---

## 6. Assert naming conventions

```elixir
# No modules with this name pattern should exist
modules_matching("MyApp.**.*Manager") |> should_not_exist()

# All modules must live under a namespace
modules_satisfying(fn m -> function_exported?(m, :__schema__, 1) end)
|> should_reside_under("MyApp.**.Schemas")

# All module names must match a glob
modules_matching("MyApp.Web.**")
|> should_have_name_matching("**.*Controller")

# Count constraint
modules_matching("MyApp.**.*God")
|> should_have_module_count(max: 0)
```

---

## 7. Scope to one app (umbrella projects)

```elixir
use ArchTest, app: :my_app
```

This filters all module sets to only include modules belonging to `:my_app`.

---

## Next steps

- [Layered Architecture](layered-architecture.md) — enforce layer direction or onion rules with `define_layers/1` and `define_onion/1`
- [Modulith Rules](modulith-rules.md) — bounded-context isolation with `define_slices/1`
- [Freezing](freezing.md) — adopt gradually by baselining existing violations
- `ArchTest.Conventions` — check for `IO.puts`, `dbg`, bare `raise`, and missing docs
- `ArchTest.Metrics` — measure coupling, instability, and distance from the main sequence
