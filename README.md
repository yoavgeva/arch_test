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
| `ArchTest.Collector.calls/2` | Function-level call metadata with file/line |
| `ArchTest.Rule` | Reusable rules with ignore and freeze support |
| `ArchTest.PlantUML` | Check actual dependencies against component diagrams |

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
    {:arch_test, "~> 0.3", only: :test, runtime: false}
  ]
end
```

Upgrading from 0.2? See the [0.3 migration guide](guides/migrating-to-0.3.md)
for the checklist and before/after examples.

---

## Igniter tasks

If you use [Igniter](https://hex.pm/packages/igniter), ArchTest provides generators for common setup patterns:

| Command | What it generates |
|---------|-------------------|
| `mix igniter.install arch_test` / `mix arch_test.install` | Basic arch test file with a cycle check |
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

Generated files use `use ArchTest, app: :your_app` so `all_modules/0`,
layers, onion rules, modulith rules, and assertions inspect the app under test
instead of every loaded dependency. Treat generators as a safe starting point:
edit the generated patterns to match your real namespaces.

---

## Quick start

```elixir
defmodule MyApp.ArchTest do
  use ExUnit.Case
  use ArchTest, app: :my_app

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
  context: "MyApp.Context.**",
  repo:    "MyApp.Repo.**"
)
|> enforce_direction()

# Scoped exception, when one dependency is intentionally allowed
define_layers(
  web:     "MyApp.Web.**",
  context: "MyApp.Context.**",
  repo:    "MyApp.Repo.**"
)
|> allow_layer_dependency(:context, :web)
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

# Auto-discover slices from one captured namespace segment
define_slices_by("MyApp.(*)", app: :my_app,
  except: ["MyApp.Application", "MyApp.Repo"])
|> enforce_isolation()

# Detect cycles between slices
define_slices(
  orders:    "MyApp.Orders",
  inventory: "MyApp.Inventory",
  accounts:  "MyApp.Accounts"
)
|> should_be_free_of_cycles()
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
|> should_have_module_count(at_most: 0)
```

---

## Code conventions

```elixir
defmodule MyApp.ConventionsTest do
  use ExUnit.Case
  use ArchTest, app: :my_app
  use ArchTest.Conventions

  test "no IO.puts in production code" do
    no_io_puts_in(modules_matching("MyApp.**"), app: :my_app)
  end

  test "no dbg calls left in" do
    no_dbg_in(modules_matching("MyApp.**"), app: :my_app)
  end

  test "no Application.get_env in the domain" do
    no_application_get_env_in(modules_matching("MyApp.Domain.**"), app: :my_app)
  end

  test "no bare raise strings" do
    no_raise_string_in(modules_matching("MyApp.**"), app: :my_app)
  end

  test "domain doesn't import the web framework" do
    no_plug_in(modules_matching("MyApp.Domain.**"), app: :my_app)
  end

  test "all public functions are documented" do
    all_public_functions_documented(modules_matching("MyApp.**"), app: :my_app)
  end
end
```

`ArchTest.Conventions` helpers are plain functions, so pass `app: :my_app` to
keep convention checks scoped like the rest of your architecture tests.

---

## Coupling metrics

```elixir
alias ArchTest.Metrics

test "Orders context is reasonably stable" do
  assert Metrics.instability("MyApp.Orders") < 0.5
  assert Metrics.afferent("MyApp.Orders") >= Metrics.efferent("MyApp.Orders")
end

test "domain is close to the main sequence" do
  metrics = Metrics.martin("MyApp.Domain.**")
  # %{MyApp.Domain.Order => %{instability: 0.2, abstractness: 0.5, distance: 0.3}, ...}

  Enum.each(metrics, fn {mod, m} ->
    assert m.distance < 0.5, "#{mod} is too far from the main sequence (D=#{m.distance})"
  end)
end
```

`Metrics.coupling("MyApp.Orders")` treats the namespace root and descendants as
one package. Pass a module atom, such as `MyApp.Orders`, when you want exact
single-module coupling. `Metrics.martin/2` returns per-module metrics for every
module matched by the pattern.

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

## App scoping, empty matches, and freeze

Scope rules to the app under test:

```elixir
use ArchTest, app: :my_app
```

This option is automatically forwarded to assertions, layers, onion rules, and
modulith checks.

Rules now fail when the subject pattern matches zero modules. This catches typoed
patterns:

```elixir
modules_matching("MyApp.Legacy.**")
|> should_not_depend_on(modules_matching("MyApp.NewCore.**"), allow_empty: true)
```

For gradual adoption, you can auto-freeze all assertions in a module:

```elixir
use ArchTest, app: :my_app, freeze: true

test "legacy deps must not get worse" do
  modules_matching("MyApp.**")
  |> should_not_depend_on(modules_matching("MyApp.Legacy.**"),
    rule_id: "legacy_deps")
end
```

Run with `ARCH_TEST_UPDATE_FREEZE=true mix test` to create/update baselines.
Auto-generated freeze IDs include rule arguments plus scope options such as
`:app`, `:apps`, `:paths`, `:include`, and `:exclude`. Use an explicit
`rule_id:` for long-lived rules whose baseline filename should stay stable.

## Advanced APIs

Import filters:

```elixir
ArchTest.Collector.build_graph(:my_app,
  include: ["MyApp.**"],
  exclude: ["MyApp.TestSupport.**"])
```

Filters keep the returned graph closed: excluded modules are removed as keys and
as dependency edges.
The same `:graph`, `:app`, `:apps`, `:paths`, `:include`, and `:exclude`
options are accepted by assertions, metrics, reusable rules, layers, onion
rules, modulith rules, convention helpers, and PlantUML enforcement.

Function-level call metadata:

```elixir
ArchTest.Collector.calls(:my_app)
# [%ArchTest.Call{caller_module: ..., caller_function: ..., callee_module: ..., file: ..., line: ...}]
```

Call metadata applies the same include/exclude filters to callers and callees and
omits compiler-generated metadata calls. Remote function captures and static
`apply(Module, :function, args)` calls are reported when debug info exposes them.

Captured slices:

```elixir
define_slices_by("MyApp.(*)", app: :my_app,
  except: ["MyApp.Application", "MyApp.Repo"])
|> enforce_isolation()
```

Descendant modules also create a slice root, so `MyApp.Orders.Checkout` is enough
to discover `orders: "MyApp.Orders"`. You can put a wildcard before the capture,
such as `"MyApp.*.(*)"`; the captured segment still becomes the slice root.

Reusable rules:

```elixir
ArchTest.Rule.new("web must not call repos", fn graph -> [] end)
|> ArchTest.Rule.ignore(callee: "MyApp.LegacyRepo")
|> ArchTest.Rule.freeze("web_repo_rule")
|> ArchTest.Rule.assert(app: :my_app)
```

PlantUML conformance:

```elixir
ArchTest.PlantUML.enforce("docs/components.puml",
  app: :my_app,
  slices: [orders: "MyApp.Orders", accounts: "MyApp.Accounts"])
```

PlantUML line comments (`'` or `//`) and block comments (`/' ... '/`) are
ignored, so commented-out edges do not accidentally allow dependencies.

See [Advanced Rules](guides/advanced-rules.md) for full examples.

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
