# Modulith / Bounded-Context Rules

A **modulith** is a monolith with well-defined internal boundaries — bounded contexts that own their data and expose a clean public API, but run in the same process and share the same database. ArchTest's modulith support enforces those boundaries at compile time so they can't erode silently.

Further reading: [Modular Monolith: A Primer (Kamil Grzybek)](https://www.kamilgrzybek.com/blog/posts/modular-monolith-primer)

---

## The core idea

Each bounded context (called a **slice**) has:

- A **public root module** — `MyApp.Orders` — the only entry point other contexts may call
- **Internals** — everything under it (`MyApp.Orders.Checkout`, `MyApp.Orders.Schema`, etc.) — off-limits to other contexts

This mirrors what the `Boundary` hex library does at compile time, but as ExUnit tests evaluated against bytecode.

---

## 1. Define slices

```elixir
define_slices(
  orders:    "MyApp.Orders",
  inventory: "MyApp.Inventory",
  accounts:  "MyApp.Accounts"
)
```

Each value is the **root namespace** of a context. ArchTest considers:
- `MyApp.Orders` itself — public API
- `MyApp.Orders.*` and deeper — internal implementation

---

## 2. Enforce isolation

```elixir
test "bounded contexts don't reach into each other's internals" do
  define_slices(
    orders:    "MyApp.Orders",
    inventory: "MyApp.Inventory",
    accounts:  "MyApp.Accounts"
  )
  |> enforce_isolation()
end
```

`enforce_isolation/1` forbids two things:
1. Any module calling **internals** of another slice (`MyApp.Orders.Checkout` calling `MyApp.Inventory.Repo`)
2. Any module calling another slice's **public root** without an explicit `allow_dependency`

### What a violation looks like

```
Architecture rule violated (enforce_isolation) — 2 violation(s):

  MyApp.Orders.Checkout → MyApp.Inventory.Repo
    :orders must not access internals of :inventory.
    Only MyApp.Inventory (public API) is accessible.

  MyApp.Orders.Service → MyApp.Inventory.Schema
    :orders must not access internals of :inventory.
    Only MyApp.Inventory (public API) is accessible.
```

---

## 3. Allow cross-context dependencies

Real applications need contexts to talk to each other. Use `allow_dependency/3` to grant that access explicitly:

```elixir
test "bounded contexts are isolated with permitted dependencies" do
  define_slices(
    orders:    "MyApp.Orders",
    inventory: "MyApp.Inventory",
    accounts:  "MyApp.Accounts"
  )
  |> allow_dependency(:orders, :accounts)      # orders may call MyApp.Accounts
  |> allow_dependency(:orders, :inventory)     # orders may call MyApp.Inventory
  |> enforce_isolation()
end
```

`allow_dependency(:orders, :accounts)` permits `:orders` to call `MyApp.Accounts` — the **public root only**. It still cannot touch `MyApp.Accounts.User`, `MyApp.Accounts.Repo`, or any other internal.

This makes the allowed dependency graph explicit and visible in version control.

---

## 4. Strict mode — zero cross-context dependencies

When contexts should be completely independent (e.g., plugin-style extensions, or core vs. plugins):

```elixir
test "plugins don't depend on each other" do
  define_slices(
    core:     "MyApp.Core",
    billing:  "MyApp.Billing",
    reporting: "MyApp.Reporting"
  )
  |> should_not_depend_on_each_other()
end
```

`should_not_depend_on_each_other/1` fails if any module in one slice calls any module in any other slice — public root included.

---

## 5. Cycle detection across contexts

Even with `allow_dependency` granted, you shouldn't have cycles between contexts:

```elixir
test "no circular context dependencies" do
  define_slices(
    orders:    "MyApp.Orders",
    inventory: "MyApp.Inventory",
    accounts:  "MyApp.Accounts"
  )
  |> should_be_free_of_cycles()
end
```

A cycle (`:orders` → `:inventory` → `:orders`) means the two contexts aren't really separate — they should be merged or redesigned.

---

## Recommended test structure

Combine isolation with cycle detection in a single test file:

```elixir
defmodule MyApp.BoundedContextTest do
  use ExUnit.Case
  use ArchTest

  @slices [
    orders:    "MyApp.Orders",
    inventory: "MyApp.Inventory",
    accounts:  "MyApp.Accounts",
    notifications: "MyApp.Notifications"
  ]

  test "contexts don't access each other's internals" do
    define_slices(@slices)
    |> allow_dependency(:orders, :accounts)
    |> allow_dependency(:orders, :inventory)
    |> allow_dependency(:notifications, :accounts)
    |> enforce_isolation()
  end

  test "no cycles between contexts" do
    define_slices(@slices) |> should_be_free_of_cycles()
  end
end
```

---

## Layered architecture inside a modulith

`define_slices` and `define_layers` compose naturally. Run one test for cross-context isolation and another for intra-context layer direction:

```elixir
test "cross-context isolation" do
  define_slices(orders: "MyApp.Orders", accounts: "MyApp.Accounts")
  |> allow_dependency(:orders, :accounts)
  |> enforce_isolation()
end

test "orders context internal layers" do
  define_layers(
    web:     "MyApp.Orders.Controllers.**",
    context: "MyApp.Orders.**",
    repo:    "MyApp.Orders.Repo.**"
  )
  |> enforce_direction()
end
```

---

## Next steps

- [Layered Architecture](layered-architecture.md) — enforce dependency direction within a context
- [Freezing](freezing.md) — when you have existing violations to baseline before enforcing
