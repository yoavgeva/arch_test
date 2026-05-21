# Migrating from 0.2 to 0.3

ArchTest 0.3 keeps the 0.2 DSL shape, but tightens correctness defaults. Most
projects can upgrade by changing the dependency, adding app scoping, and fixing
rules that were passing because their subject matched no modules.

---

## 1. Upgrade the dependency

```elixir
# mix.exs
defp deps do
  [
    {:arch_test, "~> 0.3", only: :test, runtime: false}
  ]
end
```

Then run:

```sh
mix deps.update arch_test
mix test
```

---

## 2. Scope each architecture test module

0.2 users often wrote:

```elixir
use ArchTest
```

Prefer this in 0.3:

```elixir
use ArchTest, app: :my_app
```

This scopes assertion, layer, onion, and modulith checks to the OTP app under
test. In umbrella projects, use the app for the code being checked:

```elixir
defmodule MyAppWeb.ArchTest do
  use ExUnit.Case
  use ArchTest, app: :my_app_web
end
```

`ArchTest.Conventions` helpers are plain functions, so pass scope options to
them explicitly:

```elixir
no_io_puts_in(modules_matching("MyApp.**"), app: :my_app)
no_dbg_in(modules_matching("MyApp.**"), app: :my_app)
```

---

## 3. Fix empty-subject failures

0.2 allowed many rules to pass when the subject matched zero modules. 0.3 fails
those rules by default because an empty subject usually means a typo:

```elixir
modules_matching("MyApp.Legacy.**")
|> should_not_depend_on(modules_matching("MyApp.NewCore.**"))
```

If `MyApp.Legacy.**` no longer exists, decide which case applies:

```elixir
# Typo or stale rule: fix/delete the pattern
modules_matching("MyApp.LegacyCode.**")

# Empty is intentional: say so
modules_matching("MyApp.Legacy.**")
|> should_not_depend_on(modules_matching("MyApp.NewCore.**"), allow_empty: true)
```

This applies to dependency, caller, naming, behaviour/protocol, attribute,
function, custom, and cycle assertions. `should_not_exist/2` is still naturally
allowed to pass when no forbidden modules exist. For count policies, prefer an
explicit count rule:

```elixir
modules_matching("MyApp.Legacy.**")
|> should_have_module_count(exactly: 0)
```

---

## 4. Refresh freeze baselines

0.3 freeze files use structured violation keys instead of rendered assertion
text. Existing 0.2 baseline files should be regenerated once after review:

```sh
ARCH_TEST_UPDATE_FREEZE=true mix test
git diff test/arch_test_violations
```

Keep explicit `rule_id:` values for long-lived baselines:

```elixir
use ArchTest, app: :my_app, freeze: true

test "legacy deps do not get worse" do
  modules_matching("MyApp.**")
  |> should_not_depend_on(modules_matching("MyApp.Legacy.**"),
    rule_id: "legacy_deps")
end
```

Empty-subject failures are not freezable. Fix the pattern or pass
`allow_empty: true`.

---

## 5. Check layer patterns

0.3 generators use safer non-overlapping defaults. If you copied old generated
layer rules, avoid broad middle layers that also match web or repo modules:

```elixir
# Avoid: context overlaps web/repo
define_layers(
  web: "MyApp.Web.**",
  context: "MyApp.**",
  repo: "MyApp.Repo.**"
)

# Prefer: each layer owns a distinct namespace
define_layers(
  web: "MyApp.Web.**",
  context: "MyApp.Context.**",
  repo: "MyApp.Repo.**"
)
```

If you intentionally allow one upward dependency, document it:

```elixir
define_layers(
  web: "MyApp.Web.**",
  context: "MyApp.Context.**"
)
|> allow_layer_dependency(:context, :web)
|> enforce_direction()
```

## 6. Code examples: common rewrites

### Test module scoping

Before:

```elixir
defmodule MyApp.ArchitectureTest do
  use ExUnit.Case, async: true
  use ArchTest

  test "contexts do not call web" do
    modules_matching("MyApp.**")
    |> should_not_depend_on(modules_matching("MyAppWeb.**"))
  end
end
```

After:

```elixir
defmodule MyApp.ArchitectureTest do
  use ExUnit.Case, async: true
  use ArchTest, app: :my_app

  test "contexts do not call web" do
    modules_matching("MyApp.**")
    |> should_not_depend_on(modules_matching("MyAppWeb.**"))
  end
end
```

### Convention helpers

Before:

```elixir
defmodule MyApp.ConventionsTest do
  use ExUnit.Case, async: true
  import ArchTest
  import ArchTest.Conventions

  test "debug helpers are not committed" do
    no_io_puts_in(modules_matching("MyApp.**"))
    no_dbg_in(modules_matching("MyApp.**"))
  end
end
```

After:

```elixir
defmodule MyApp.ConventionsTest do
  use ExUnit.Case, async: true
  import ArchTest
  import ArchTest.Conventions

  test "debug helpers are not committed" do
    no_io_puts_in(modules_matching("MyApp.**"), app: :my_app)
    no_dbg_in(modules_matching("MyApp.**"), app: :my_app)
  end
end
```

### Optional or deleted namespaces

Before:

```elixir
modules_matching("MyApp.Legacy.**")
|> should_not_depend_on(modules_matching("MyApp.Core.**"))
```

After, if the namespace is optional:

```elixir
modules_matching("MyApp.Legacy.**")
|> should_not_depend_on(modules_matching("MyApp.Core.**"), allow_empty: true)
```

After, if the namespace should stay deleted:

```elixir
modules_matching("MyApp.Legacy.**")
|> should_have_module_count(exactly: 0)
```

### Freeze baselines

Before:

```elixir
test "legacy dependencies do not get worse" do
  ArchTest.Freeze.freeze("legacy_deps", fn ->
    modules_matching("MyApp.**")
    |> should_not_depend_on(modules_matching("MyApp.Legacy.**"))
  end)
end
```

After:

```elixir
defmodule MyApp.LegacyArchTest do
  use ExUnit.Case, async: true
  use ArchTest, app: :my_app, freeze: true

  test "legacy dependencies do not get worse" do
    modules_matching("MyApp.**")
    |> should_not_depend_on(modules_matching("MyApp.Legacy.**"),
      rule_id: "legacy_deps")
  end
end
```

### Layer rules

Before:

```elixir
define_layers(
  web: "MyAppWeb.**",
  context: "MyApp.**",
  repo: "MyApp.Repo.**"
)
|> enforce_direction()
```

After:

```elixir
define_layers(
  web: "MyAppWeb.**",
  context: "MyApp.Context.**",
  repo: "MyApp.Repo.**"
)
|> enforce_direction()
```

If you need a known exception, make it explicit:

```elixir
define_layers(
  web: "MyAppWeb.**",
  context: "MyApp.Context.**",
  repo: "MyApp.Repo.**"
)
|> allow_layer_dependency(:context, :web)
|> enforce_direction()
```

### Modulith slices

Before:

```elixir
define_slices(
  orders: "MyApp.Orders",
  accounts: "MyApp.Accounts",
  inventory: "MyApp.Inventory"
)
|> enforce_isolation()
```

After, when slices follow namespace roots:

```elixir
define_slices_by("MyApp.(*)", app: :my_app,
  except: ["MyApp.Application", "MyApp.Repo"])
|> allow_dependency(:orders, :accounts)
|> enforce_isolation()
```

Add a slice-cycle check when slices should form an acyclic dependency graph:

```elixir
define_slices_by("MyApp.(*)", app: :my_app,
  except: ["MyApp.Application", "MyApp.Repo"])
|> should_be_free_of_cycles()
```

### Reusable custom rules

Before:

```elixir
violations =
  for {caller, deps} <- ArchTest.Collector.build_graph(:my_app),
      caller |> Atom.to_string() |> String.starts_with?("Elixir.MyAppWeb."),
      dep <- deps,
      dep |> Atom.to_string() |> String.ends_with?("Repo") do
    ArchTest.Violation.forbidden_dep(caller, dep, "web must call contexts")
  end

ArchTest.assert_no_violations_public(violations, "web must not call repos")
```

After:

```elixir
ArchTest.Rule.new("web must not call repos", fn graph ->
  for {caller, deps} <- graph,
      caller |> Atom.to_string() |> String.starts_with?("Elixir.MyAppWeb."),
      dep <- deps,
      dep |> Atom.to_string() |> String.ends_with?("Repo") do
    ArchTest.Violation.forbidden_dep(caller, dep, "web must call contexts")
  end
end)
|> ArchTest.Rule.ignore(callee: "MyApp.LegacyRepo")
|> ArchTest.Rule.freeze("web_repo_rule")
|> ArchTest.Rule.assert(app: :my_app)
```

---

## 7. Optional 0.3 improvements

After tests pass, consider adopting the new features:

- `define_slices_by/2` to discover modulith slices from namespaces.
- `should_be_free_of_cycles/2` on modulith slice definitions.
- `ArchTest.Collector.calls/2` for function-level call-site rules.
- `ArchTest.Rule` for reusable, ignorable, freezable custom rules.
- `ArchTest.PlantUML.enforce/2` to keep component diagrams honest.
- `ArchTest.Metrics.afferent/2`, `efferent/2`, `fan_in/2`, `fan_out/2`, and
  `dependency_depth/2`.

See [Advanced Rules](advanced-rules.md) for examples.

---

## Recommended upgrade checklist

1. Bump dependency to `~> 0.3`.
2. Add `use ArchTest, app: :your_app` to architecture test modules.
3. Pass `app:` to `ArchTest.Conventions` helpers.
4. Run `mix test`.
5. Fix typoed empty patterns or add `allow_empty: true` where intentional.
6. Regenerate freeze baselines with `ARCH_TEST_UPDATE_FREEZE=true mix test`.
7. Review generated baseline diffs.
8. Run `mix format --check-formatted`, `mix compile --warnings-as-errors`, and
   `mix test` in CI.
