# Layered Architecture

ArchTest ships two built-in patterns for layered architectures: **classic layers** (each layer depends only on layers below it) and **onion / hexagonal** (dependencies point inward toward the domain core).

Both are defined by naming the layers and calling an enforcement function. The library does the rest.

Further reading: [N-tier architecture (Wikipedia)](https://en.wikipedia.org/wiki/Multitier_architecture) · [Onion Architecture (Jeffrey Palermo)](https://jeffreypalermo.com/2008/07/the-onion-architecture-part-1/) · [Hexagonal / Ports & Adapters (Alistair Cockburn)](https://alistair.cockburn.us/hexagonal-architecture/)

---

## Classic layered architecture

Layers are declared from **top** (most user-facing) to **bottom** (most infrastructural). A layer may depend on any layer below it; a layer depending on one above it is a violation.

```elixir
test "architecture layers are respected" do
  define_layers(
    web:     "MyApp.Web.**",
    context: "MyApp.Context.**",
    repo:    "MyApp.Repo.**"
  )
  |> enforce_direction()
end
```

With this definition:
- `web` may depend on `context` and `repo`
- `context` may depend on `repo`
- `repo` may not depend on `context` or `web`
- `context` may not depend on `web`

### Reading violation output

```
Architecture rule violated (enforce_direction) — 1 violation(s):

  MyApp.Orders.OrderContext → MyApp.Web.Router
    layer :context must not depend on layer :web
```

---

## Onion / hexagonal architecture

Onion layers are declared from **innermost** (domain core, no external dependencies) to **outermost** (adapters, HTTP, databases). Dependencies must point **inward only** — outer rings may call inner rings, never the reverse.

```elixir
test "onion architecture is respected" do
  define_onion(
    domain:      "MyApp.Domain.**",
    application: "MyApp.Application.**",
    adapters:    "MyApp.Adapters.**",
    web:         "MyApp.Web.**"
  )
  |> enforce_onion_rules()
end
```

With this definition:
- `domain` may not depend on anything else declared here
- `application` may depend on `domain`
- `adapters` may depend on `application` and `domain`
- `web` may depend on `adapters`, `application`, and `domain`

This maps directly to the dependency rule: *inner rings are always stable; outer rings are allowed to be unstable*.

---

## Fine-grained control

Both `define_layers/1` and `define_onion/1` return a struct you can refine before enforcement.

### Allow specific cross-layer calls

```elixir
define_layers(
  web:     "MyApp.Web.**",
  context: "MyApp.Context.**",
  repo:    "MyApp.Repo.**"
)
|> allow_layer_dependency(:context, :web)   # context may call web (exception)
|> enforce_direction()
```

### Forbid specific cross-layer calls explicitly

```elixir
define_layers(
  web:     "MyApp.Web.**",
  context: "MyApp.Context.**",
  repo:    "MyApp.Repo.**"
)
|> layer_may_not_depend_on(:context, [:web])
|> enforce_direction()
```

---

## Excluding test/support modules

Often you want to exclude test helpers from the layer check:

```elixir
define_layers(
  web:     "MyApp.Web.**",
  context: "MyApp.Context.**",
  repo:    "MyApp.Repo.**"
)
|> enforce_direction()
```

If your test modules live under `MyApp.Test.**`, they won't match any of the
three layer patterns above and will be ignored automatically. Keep layer
patterns non-overlapping where possible; if support modules overlap production
namespaces, move them under a support namespace or use collector filters such as
`exclude: ["MyApp.TestSupport.**"]` when enforcing the rule.

---

## Umbrella: scope to one app

Prefer setting the app once in the test module:

```elixir
use ArchTest, app: :my_app
```

Then `define_layers/1`, `define_onion/1`, and their enforcement helpers use
that app automatically. For one-off checks without `use ArchTest`, call
`for_app/2` explicitly:

```elixir
define_layers(
  web:     "MyApp.Web.**",
  context: "MyApp.Context.**",
  repo:    "MyApp.Repo.**"
)
|> ArchTest.Layers.for_app(:my_app)
|> enforce_direction()
```

---

## Which pattern should I use?

| Situation | Pattern |
|-----------|---------|
| Classic MVC / Phoenix (web → context → repo) | `define_layers` + `enforce_direction` |
| DDD with rich domain model, ports and adapters | `define_onion` + `enforce_onion_rules` |
| Mostly flat but want to ban a specific upward dep | `modules_matching` + `should_not_depend_on` |

For many Phoenix applications, a three-layer rule (`web → context → repo`) is the most practical starting point. Add more layers only when your codebase genuinely has more tiers.

---

## Next steps

- [Modulith Rules](modulith-rules.md) — when you have distinct bounded contexts that also need isolation from each other
- [Getting Started](getting-started.md) — module selection and basic dependency assertions
