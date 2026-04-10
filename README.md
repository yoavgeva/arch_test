# ArchTest

[![CI](https://github.com/yoavgeva/arch_test/actions/workflows/ci.yml/badge.svg)](https://github.com/yoavgeva/arch_test/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/arch_test.svg)](https://hex.pm/packages/arch_test)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/arch_test)

Architecture rules as tests. Enforced from bytecode.

| Assertion | What it checks |
|-----------|----------------|
| `should_not_depend_on` | No direct dependency on a module set |
| `should_only_depend_on` | All dependencies must be in an allowlist |
| `should_not_be_called_by` | Restrict who may call a module set |
| `should_only_be_called_by` | Only these callers are allowed |
| `should_not_transitively_depend_on` | No transitive path to a module set |
| `should_be_free_of_cycles` | No circular dependencies |
| `should_not_exist` | No modules matching a pattern should exist |
| `should_reside_under` | Modules must live under a namespace |
| `should_have_name_matching` | Module names must match a glob |
| `should_have_module_count` | Enforce min/max module counts |
| `define_layers` + `enforce_direction` | Classic layered architecture |
| `define_onion` + `enforce_onion_rules` | Onion / hexagonal architecture |
| `define_slices` + `enforce_isolation` | Modulith bounded-context isolation |
| `ArchTest.Conventions` | Ban `IO.puts`, `dbg`, bare `raise`, and more |
| `ArchTest.Metrics` | Coupling, instability, distance from main sequence |
| `ArchTest.Freeze` | Baseline violations for gradual adoption |

---

## The missing piece

Elixir has excellent tools for code quality. But there's a gap:

| Tool | What it enforces |
|------|-----------------|
| **Credo** | Style, readability, code smells within a file |
| **Boundary** | Cross-context calls at compile time (compiler warnings) |
| **Dialyzer** | Type correctness |
| **ArchTest** | Structural rules across your whole codebase — in tests |

**Credo** tells you a function is too long. It doesn't tell you that your domain layer is calling your web layer.

**Boundary** gives you compile-time warnings when a module crosses a declared boundary. It's powerful, but it requires annotating every module with `use Boundary`, it runs at compile time (so violations block your build), and it's scoped to the boundaries you explicitly declare. You can't easily ask "do any Services depend on Repos?" or "does anything in Domain transitively reach Phoenix?" without writing boundary declarations for all of it.

**ArchTest** is a test library. Rules live in ExUnit tests. You write them in plain Elixir, run them with `mix test`, and get structured failure output listing every violation. You can express rules Boundary can't — transitive dependencies, glob-based module selection, coupling metrics, naming conventions, cycle detection across arbitrary module sets — without touching production code at all.

For most teams, **ArchTest alone is enough**. You get bounded-context isolation, dependency direction, naming policies, convention checks, and metrics — all in ExUnit, with no changes to production code. If you later want compile-time enforcement on top of test-time enforcement, the two compose naturally: Boundary for hard build-time API guards, ArchTest for everything else.

---

## Installation

```elixir
# mix.exs
def deps do
  [
    {:arch_test, "~> 0.2", only: :test, runtime: false}
  ]
end
```

---

## Igniter tasks

If you use [Igniter](https://hex.pm/packages/igniter), ArchTest provides generators for common setup patterns:

| Command | What it generates |
|---------|-------------------|
| `mix igniter.install arch_test` | Basic arch test file with a cycle check |
| `mix arch_test.gen.phoenix` | Opinionated Phoenix setup — layers + naming + conventions ([Phoenix directory structure](https://hexdocs.pm/phoenix/directory_structure.html) · [N-tier architecture](https://en.wikipedia.org/wiki/Multitier_architecture)) |
| `mix arch_test.gen.layers` | [Classic web → context → repo layers](guides/layered-architecture.md) ([N-tier architecture](https://en.wikipedia.org/wiki/Multitier_architecture)) |
| `mix arch_test.gen.onion` | [Onion / hexagonal rings](guides/layered-architecture.md#onion--hexagonal-architecture) ([Onion Architecture](https://jeffreypalermo.com/2008/07/the-onion-architecture-part-1/) · [Hexagonal / Ports & Adapters](https://alistair.cockburn.us/hexagonal-architecture/)) |
| `mix arch_test.gen.modulith` | [Bounded-context slice isolation](guides/modulith-rules.md) ([Modular Monolith Primer](https://www.kamilgrzybek.com/blog/posts/modular-monolith-primer)) |
| `mix arch_test.gen.naming` | Naming rules — no Managers, schema namespace placement |
| `mix arch_test.gen.conventions` | Code hygiene — no `IO.puts`, `dbg`, bare `raise` |
| `mix arch_test.gen.freeze` | [Freeze baseline for gradual adoption](guides/freezing.md) |

Add Igniter as a dev dependency to use these:

```elixir
{:igniter, "~> 0.7", only: [:dev, :test], runtime: false}
```

---

## Quick start

```elixir
defmodule MyApp.ArchTest do
  use ExUnit.Case
  use ArchTest

  test "services don't call repos directly" do
    modules_matching("MyApp.**.*Service")
    |> should_not_depend_on(modules_matching("MyApp.**.*Repo"))
  end

  test "no Manager modules exist" do
    modules_matching("MyApp.**.*Manager") |> should_not_exist()
  end

  test "repo is only called by the domain layer" do
    modules_matching("MyApp.Repo")
    |> should_only_be_called_by(modules_matching("MyApp.Domain.**"))
  end

  test "no circular dependencies" do
    modules_matching("MyApp.**") |> should_be_free_of_cycles()
  end
end
```

Violations produce clear, actionable output:

```
  1) test services don't call repos directly (MyApp.ArchTest)
     Architecture rule violated (should_not_depend_on) — 2 violation(s):

       MyApp.Accounts.RegistrationService → MyApp.Accounts.UserRepo
         MyApp.**.*Service must not depend on MyApp.**.*Repo

       MyApp.Orders.CheckoutService → MyApp.Orders.OrderRepo
         MyApp.**.*Service must not depend on MyApp.**.*Repo
```

---

## Module selection

```elixir
modules_matching("MyApp.Orders.*")       # direct children only
modules_matching("MyApp.Orders.**")      # all descendants
modules_matching("**.*Service")          # last segment ends with "Service"
modules_matching("**.*Service*")         # last segment contains "Service"

modules_in("MyApp.Orders")              # shorthand for "MyApp.Orders.*"
all_modules()                           # everything in the app

modules_satisfying(fn mod ->
  function_exported?(mod, :__schema__, 1)
end)

# Composition
modules_matching("MyApp.**") |> excluding("MyApp.Web.*")
modules_matching("**.*Service") |> union(modules_matching("**.*View"))
modules_matching("MyApp.**") |> intersection(modules_matching("**.*Schema"))
```

---

## Dependency assertions

```elixir
# Forbid a dependency
modules_matching("MyApp.Domain.**")
|> should_not_depend_on(modules_matching("MyApp.Web.**"))

# Allowlist — anything outside the set is forbidden
modules_matching("MyApp.Web.**")
|> should_only_depend_on(modules_matching("MyApp.Domain.**"))

# Caller restriction
modules_matching("MyApp.Repo")
|> should_only_be_called_by(modules_matching("MyApp.Domain.**"))

# Transitive closure
modules_matching("MyApp.Domain.**")
|> should_not_transitively_depend_on(modules_matching("Ecto.**"))

# Cycles
modules_matching("MyApp.**") |> should_be_free_of_cycles()
```

---

## Layered architecture

```elixir
# Classic layers (top to bottom — each layer may only depend on layers below)
define_layers(
  web:     "MyApp.Web.**",
  context: "MyApp.**",
  repo:    "MyApp.Repo.**"
)
|> enforce_direction()

# Onion / hexagonal (innermost first — dependencies point inward only)
define_onion(
  domain:      "MyApp.Domain.**",
  application: "MyApp.Application.**",
  adapters:    "MyApp.Adapters.**",
  web:         "MyApp.Web.**"
)
|> enforce_onion_rules()
```

---

## Modulith / bounded-context isolation

```elixir
define_slices(
  orders:    "MyApp.Orders",
  inventory: "MyApp.Inventory",
  accounts:  "MyApp.Accounts"
)
|> allow_dependency(:orders, :accounts)
|> enforce_isolation()

# Strict: zero cross-context dependencies
define_slices(
  core:    "MyApp.Core",
  plugins: "MyApp.Plugins"
)
|> should_not_depend_on_each_other()
```

---

## Naming conventions

```elixir
modules_matching("MyApp.**.*Manager") |> should_not_exist()

modules_satisfying(fn m -> function_exported?(m, :__schema__, 1) end)
|> should_reside_under("MyApp.**.Schemas")

modules_matching("MyApp.Web.**")
|> should_have_name_matching("**.*Controller")

modules_matching("MyApp.**.*God")
|> should_have_module_count(max: 0)
```

---

## Code conventions

```elixir
defmodule MyApp.ConventionsTest do
  use ExUnit.Case
  use ArchTest
  use ArchTest.Conventions

  test "no IO.puts in production code" do
    no_io_puts_in(modules_matching("MyApp.**"))
  end

  test "no dbg calls left in" do
    no_dbg_in(modules_matching("MyApp.**"))
  end

  test "no Application.get_env in the domain" do
    no_application_get_env_in(modules_matching("MyApp.Domain.**"))
  end

  test "no bare raise strings" do
    no_raise_string_in(modules_matching("MyApp.**"))
  end

  test "domain doesn't import the web framework" do
    no_plug_in(modules_matching("MyApp.Domain.**"))
  end

  test "all public functions are documented" do
    all_public_functions_documented(modules_matching("MyApp.**"))
  end
end
```

---

## Coupling metrics

```elixir
alias ArchTest.Metrics

test "Orders context is reasonably stable" do
  assert Metrics.instability("MyApp.Orders") < 0.5
end

test "domain is close to the main sequence" do
  metrics = Metrics.martin("MyApp.Domain.**")
  # %{MyApp.Domain.Order => %{instability: 0.2, abstractness: 0.5, distance: 0.3}, ...}

  Enum.each(metrics, fn {mod, m} ->
    assert m.distance < 0.5, "#{mod} is too far from the main sequence (D=#{m.distance})"
  end)
end
```

---

## Violation freeze (gradual adoption)

When introducing ArchTest to an existing codebase, freeze current violations and only fail on new ones:

```elixir
test "legacy dependencies being cleaned up" do
  ArchTest.Freeze.freeze("legacy_deps", fn ->
    modules_matching("MyApp.**")
    |> should_not_depend_on(modules_matching("MyApp.Legacy.**"))
  end)
end
```

```sh
# Establish the baseline
ARCH_TEST_UPDATE_FREEZE=true mix test
```

Baselines are stored in `test/arch_test_violations/`. Commit them to version control. Re-run with the flag after fixing violations to shrink the baseline. Delete the file when the rule is clean.

---

## Umbrella projects

```elixir
use ArchTest, app: :my_app
```

---

## Pattern reference

| Pattern | Matches |
|---------|---------|
| `"MyApp.Orders"` | Exact match only |
| `"MyApp.Orders.*"` | Direct children (`MyApp.Orders.Order`) |
| `"MyApp.Orders.**"` | All descendants at any depth |
| `"**.*Service"` | Any module whose last segment ends with `Service` |
| `"**.*Service*"` | Any module whose last segment contains `Service` |
| `"MyApp.**.*Repo"` | Under `MyApp`, last segment ends with `Repo` |
| `"**"` | All modules |

---

## License

MIT — see [LICENSE](LICENSE).
