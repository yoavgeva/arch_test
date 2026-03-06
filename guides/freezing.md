# Freezing (Gradual Adoption)

Adding architecture rules to an existing codebase almost always reveals violations. You can't fix them all on day one — but you also can't leave the rules permanently disabled. The **freeze** mechanism solves this: you baseline the current violations and fail only on *new* ones. The codebase can only improve, never regress.

---

## 1. The problem

You add a rule:

```elixir
test "domain doesn't depend on web" do
  modules_matching("MyApp.Domain.**")
  |> should_not_depend_on(modules_matching("MyApp.Web.**"))
end
```

It fails with 47 violations. You can't fix 47 violations today. You could comment the test out — but then new violations will go undetected.

---

## 2. The solution: freeze

Wrap the rule in `ArchTest.Freeze.freeze/2`:

```elixir
test "domain doesn't depend on web" do
  ArchTest.Freeze.freeze("domain_web_deps", fn ->
    modules_matching("MyApp.Domain.**")
    |> should_not_depend_on(modules_matching("MyApp.Web.**"))
  end)
end
```

On the first run with no baseline, all violations are reported as new and the test fails. That's expected — the next step is to establish the baseline.

---

## 3. Establish the baseline

Run once with the update flag:

```sh
ARCH_TEST_UPDATE_FREEZE=true mix test
```

This writes a file at `test/arch_test_violations/domain_web_deps.txt` listing every current violation. Commit that file to version control.

On all subsequent runs, the freeze mechanism:
1. Runs the assertion and collects all current violations
2. Reads the baseline from the file
3. Computes `current − baseline`
4. Fails only if there are new violations not in the baseline

The 47 existing violations are silently ignored. Any *new* violation — introduced in a PR — causes a failure.

---

## 4. Clean up violations over time

As you fix legacy violations, re-run with the update flag to shrink the baseline:

```sh
ARCH_TEST_UPDATE_FREEZE=true mix test
```

The baseline file now has fewer entries. Eventually you can delete it entirely and the rule will enforce with zero tolerance.

A smaller baseline file on each PR is a visible, trackable signal of architectural progress.

---

## 5. Configure the baseline directory

Default location: `test/arch_test_violations/`

To change it:

```elixir
# config/test.exs
config :arch_test, freeze_store: "test/arch_violations"
```

---

## 6. Multiple frozen rules

Each rule gets its own key and its own baseline file:

```elixir
test "web ↛ domain (freeze)" do
  ArchTest.Freeze.freeze("web_domain", fn ->
    modules_matching("MyApp.Web.**")
    |> should_not_depend_on(modules_matching("MyApp.Domain.**"))
  end)
end

test "no Manager modules (freeze)" do
  ArchTest.Freeze.freeze("no_managers", fn ->
    modules_matching("MyApp.**.*Manager") |> should_not_exist()
  end)
end
```

Files: `test/arch_test_violations/web_domain.txt`, `test/arch_test_violations/no_managers.txt`.

---

## 7. Recommended workflow

| Step | Command | Effect |
|------|---------|--------|
| First adoption | `ARCH_TEST_UPDATE_FREEZE=true mix test` | Writes baseline for all frozen rules |
| Normal CI | `mix test` | Fails on new violations only |
| After fixing violations | `ARCH_TEST_UPDATE_FREEZE=true mix test` | Shrinks baseline files |
| Rule fully clean | Delete the baseline file, remove `freeze` wrapper | Enforces at zero tolerance |

---

## How the freeze key is matched

Violations are compared as strings. The key format is `"CallerModule → CalleeModule"`. If a violation string appears in the baseline file, it is ignored. If it is not in the file, the test fails.

This means renaming a module *removes* it from the baseline and treats it as a new violation — which is correct, because the new name should not carry forward the old waiver.

---

## Next steps

- [Getting Started](getting-started.md) — basic dependency assertions without freezing
- [Modulith Rules](modulith-rules.md) — bounded-context isolation, a common place to start freezing
