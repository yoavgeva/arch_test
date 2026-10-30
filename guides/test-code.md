# Test Code

`ArchTest.TestCode` checks your tests against your code. ExUnit compiles test files in memory as it runs them, so
nothing on disk holds their compiled code: these rules read the `*_test.exs` files under `:test_paths` (default
`["test"]`) from source, with aliases resolved, and check them against the production code, read from debug info as
`ArchTest.Effects` does.

```elixir
defmodule MyApp.TestRulesTest do
  use ExUnit.Case
  use ArchTest, app: :my_app
  use ArchTest.TestCode

  test "tests use their subject" do
    tests_use_their_subject(modules_matching("MyApp.**"), app: :my_app)
  end

  test "tests mock only I/O" do
    tests_dont_mock_pure_modules(modules_matching("MyApp.**"), app: :my_app)
  end

  test "tests don't sleep" do
    tests_dont_sleep(modules_matching("MyApp.**"), app: :my_app)
  end

  test "async tests share no state" do
    async_tests_share_no_state(modules_matching("MyApp.**"), app: :my_app)
  end
end
```

The subject selects test modules by name: `modules_matching("MyApp.**")` checks `MyApp.AccountsTest`.

---

## 1. Tests use their subject

A test named after a module that never uses it, or only mocks it, checks nothing about it.

```elixir
# flagged: Pricing is only ever the stub
test "totals" do
  stub(MyApp.Pricing, :total, fn _ -> 10 end)
  assert MyApp.Pricing.total([1, 2]) == 10
end
```

`tests_use_their_subject/2` counts as a use:

- the module's name anywhere in the test, `use` options included, other than as the module a mock replaces;
- a call to one of its functions the test doesn't mock, or to one of its macros, as a sigil is;
- a use of a module nested in it, as `MyApp.Billing.Invoice` is in `MyApp.Billing`;
- code the test calls, or a test helper it calls, that reaches the module: calls it, or names it, as a registry
  listing rule modules does, directly or through the functions it calls;
- a call to a protocol implemented for the module, or implemented in its file, as a mailer's
  `defimpl Swoosh.Email.Recipient` is;
- the `init/1` of a process the test starts with `start_supervised!/1`, and the children it names;
- for controllers, live views and channels, requests through `Phoenix.ConnTest` (`get/2`, `post/3`...),
  `Phoenix.LiveViewTest` (`live/2`), `Phoenix.ChannelTest` (`subscribe_and_join/3`) and PhoenixTest (`visit/2`).

Tests named after no module in scope are skipped.

---

## 2. Mock only I/O

A mock of code that touches nothing outside it replaces what's cheap and safe to run, and the test then checks the
mock. `tests_dont_mock_pure_modules/2` flags:

- `Mimic.stub/3`, `Mimic.expect/3`, `Mock.with_mock/3` and the like on a project function that touches nothing
  outside the code, directly or through what it calls;
- an `expect/3` on a Mox mock whose behaviour's implementations all touch nothing outside the code. Mox mocks are
  matched to their behaviours through the `Mox.defmock/2` calls in your test paths.

Mocks of code that reads the database, makes HTTP requests or uses the network pass.

---

## 3. No sleeping

A sleep long enough on a fast machine is too short on a slow one, and slows every run. `tests_dont_sleep/2` flags
`Process.sleep/1` and `:timer.sleep/1` in tests, setups and test helpers. It passes:

- a helper that retries itself, as an `assert_eventually` polling a condition with a short sleep does;
- fakes a test file defines without tests of their own, which stand in for a slow dependency;
- `Process.sleep(:infinity)`, which parks a process rather than waiting.

```elixir
# flagged
send(server, :refresh)
Process.sleep(100)
assert Cache.get(:key) == :fresh

# fixed: wait for the message that says it's done
send(server, {:refresh, self()})
assert_receive :refreshed
assert Cache.get(:key) == :fresh
```

---

## 4. Async tests share no state

`Application.put_env/3`, `System.put_env/2`, `:persistent_term.put/2`, `Logger.configure/1` and the like change
state every test sees. In a module with `async: true`, the tests running at the same time pass or fail by timing.
`async_tests_share_no_state/2` flags them in async test modules; pass the value to the code under test instead, or
make the module `async: false`.
