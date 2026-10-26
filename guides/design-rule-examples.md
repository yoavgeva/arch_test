# Design Rule Examples

Every design rule of `ArchTest.Effects`, `ArchTest.Processes`, `ArchTest.API`, `ArchTest.TestCode` and
`ArchTest.Guardrails`, with
code it flags, marked `# ✗`, and under **Fixed** the files that change to fix it. The examples are a small `Shop` app
whose `Shop.Repo` is an Ecto repo. A test compiles every example and runs its rule on it, so they show what the rules
really do.

## Effects

### `no_queries_in_loops`

`ArchTest.Effects.no_queries_in_loops(modules_matching("Shop.**"))`

A query once per item turns a page of 50 orders into 51 round trips, even when the query is a call away.

```elixir
defmodule Shop.Accounts do
  alias Shop.Repo

  def get_user!(id), do: Repo.get!(Shop.User, id)
  def list_users(ids), do: Repo.all({Shop.User, ids})
end
```

```elixir
defmodule Shop.Orders do
  alias Shop.Accounts

  def with_users(orders) do
    # ✗ one query per order, through Accounts.get_user!/1
    Enum.map(orders, fn order -> {order, Accounts.get_user!(order.user_id)} end)
  end
end
```

<details><summary>Fixed</summary>

One query loads every user the orders need.

```elixir
defmodule Shop.Orders do
  alias Shop.Accounts

  def with_users(orders) do
    users = orders |> Enum.map(& &1.user_id) |> Accounts.list_users() |> Map.new(&{&1.id, &1})
    Enum.map(orders, fn order -> {order, users[order.user_id]} end)
  end
end
```

</details>

### `should_be_free_of_side_effects`

`ArchTest.Effects.should_be_free_of_side_effects(modules_matching("Shop.Pricing.**"))`

A functional core that reads the clock gives a different answer every day, so its tests can't pin one down.

```elixir
defmodule Shop.Pricing.Discounts do
  def weekend_discount(price) do
    # ✗ reads the clock
    if Date.day_of_week(Date.utc_today()) >= 6, do: price * 0.9, else: price
  end
end
```

<details><summary>Fixed</summary>

The core takes the date, and the code around it reads the clock.

```elixir
defmodule Shop.Pricing.Discounts do
  def weekend_discount(price, today) do
    if Date.day_of_week(today) >= 6, do: price * 0.9, else: price
  end
end
```

```elixir
defmodule Shop.Checkout do
  def price(item), do: Shop.Pricing.Discounts.weekend_discount(item.price, Date.utc_today())
end
```

</details>

### `no_work_in_init`

`ArchTest.Effects.no_work_in_init(modules_matching("Shop.**"))`

A supervisor waits for each child's `init/1`, so slow or failing I/O there holds up or stops the whole application.

```elixir
defmodule Shop.PriceCache do
  use GenServer

  def start_link(path), do: GenServer.start_link(__MODULE__, path, name: __MODULE__)

  @impl true
  # ✗ reads a file while its supervisor waits
  def init(path), do: {:ok, File.read!(path)}
end
```

<details><summary>Fixed</summary>

```elixir
defmodule Shop.PriceCache do
  use GenServer

  def start_link(path), do: GenServer.start_link(__MODULE__, path, name: __MODULE__)

  @impl true
  def init(path), do: {:ok, %{path: path}, {:continue, :load}}

  @impl true
  def handle_continue(:load, state), do: {:noreply, Map.put(state, :prices, File.read!(state.path))}
end
```

</details>

### `no_io_in_transactions`

`ArchTest.Effects.no_io_in_transactions(modules_matching("Shop.**"))`

A rollback can't take back an email, and the transaction holds its database connection while the mail server
answers.

```elixir
defmodule Shop.Orders do
  alias Shop.{Mailer, Repo}

  def place(order, payment) do
    Repo.transaction(fn ->
      placed = Repo.insert!(order)
      Repo.insert!(%{payment | order_id: placed.id})
      # ✗ sends the receipt before the order is committed, even if it rolls back
      Mailer.deliver(placed.email)
      placed
    end)
  end
end
```

<details><summary>Fixed</summary>

```elixir
defmodule Shop.Orders do
  alias Shop.{Mailer, Repo}

  def place(order, payment) do
    with {:ok, placed} <- Repo.transaction(fn -> save(order, payment) end),
         {:ok, _email} <- Mailer.deliver(placed.email) do
      {:ok, placed}
    end
  end

  defp save(order, payment) do
    placed = Repo.insert!(order)
    Repo.insert!(%{payment | order_id: placed.id})
    placed
  end
end
```

</details>

### `writes_are_authorized`

`ArchTest.Effects.writes_are_authorized(modules_matching("ShopWeb.**"))`

An endpoint that changes a record by the id it's sent lets anyone change anyone's record.

```elixir
defmodule ShopWeb.OrderController do
  use ShopWeb, :controller
  alias Shop.Orders

  # ✗ cancels whichever order the id names, whoever asks
  def cancel(conn, %{"id" => id}) do
    {:ok, order} = Orders.cancel_order(id)
    json(conn, order)
  end
end
```

```elixir
defmodule Shop.Orders do
  alias Shop.{Order, Repo}

  def cancel_order(id), do: Order |> Repo.get!(id) |> Order.cancel() |> Repo.update()
end
```

```elixir
defmodule Shop.Order do
  defstruct [:id, :user_id, :status]

  def cancel(order), do: %{order | status: :cancelled}
end
```

<details><summary>Fixed</summary>

```elixir
defmodule ShopWeb.OrderController do
  use ShopWeb, :controller
  alias Shop.Orders

  def cancel(conn, %{"id" => id}) do
    {:ok, order} = Orders.cancel_order(conn.assigns.current_user, id)
    json(conn, order)
  end
end
```

```elixir
defmodule Shop.Orders do
  alias Shop.{Order, Repo}

  def cancel_order(user, id),
    do: Order |> Repo.get_by!(id: id, user_id: user.id) |> Order.cancel() |> Repo.update()
end
```

</details>

## Processes

### `processes_have_one_interface`

`ArchTest.Processes.processes_have_one_interface(modules_matching("Shop.**"))`

When other modules build a process's messages, what it accepts is spread over all of them.

```elixir
defmodule Shop.Cache do
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:fetch, key}, _from, state), do: {:reply, Map.get(state, key), state}
end
```

```elixir
defmodule Shop.Pricing do
  # ✗ builds Shop.Cache's message
  def price(item), do: GenServer.call(Shop.Cache, {:fetch, item})
end
```

<details><summary>Fixed</summary>

```elixir
defmodule Shop.Cache do
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def fetch(key), do: GenServer.call(__MODULE__, {:fetch, key})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:fetch, key}, _from, state), do: {:reply, Map.get(state, key), state}
end
```

```elixir
defmodule Shop.Pricing do
  def price(item), do: Shop.Cache.fetch(item)
end
```

</details>

### `processes_hold_state`

`ArchTest.Processes.processes_hold_state(modules_matching("Shop.**"))`

A GenServer that only computes makes its callers wait in one queue for work they could do themselves.

```elixir
defmodule Shop.Calculator do
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def add(a, b), do: GenServer.call(__MODULE__, {:add, a, b})

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  # ✗ keeps its state and touches nothing: no reason to be a process
  def handle_call({:add, a, b}, _from, state), do: {:reply, a + b, state}
end
```

<details><summary>Fixed</summary>

```elixir
defmodule Shop.Calculator do
  def add(a, b), do: a + b
end
```

</details>

### `processes_are_supervised`

`ArchTest.Processes.processes_are_supervised(modules_matching("Shop.**"))`

Nothing notices when an unsupervised process crashes, and shutdown doesn't stop it.

```elixir
defmodule Shop.Notifier do
  # ✗ nothing watches the task
  def notify(user), do: Task.start(fn -> deliver(user) end)

  defp deliver(user), do: IO.puts("Your order shipped, #{user}")
end
```

<details><summary>Fixed</summary>

```elixir
defmodule Shop.Notifier do
  def notify(user), do: Task.Supervisor.start_child(Shop.TaskSupervisor, fn -> deliver(user) end)

  defp deliver(user), do: IO.puts("Your order shipped, #{user}")
end
```

</details>

### `no_unbounded_waits`

`ArchTest.Processes.no_unbounded_waits(modules_matching("Shop.**"))`

One supplier that never answers holds up every price, and every request waiting for them.

```elixir
defmodule Shop.Prices do
  def fetch_all(suppliers) do
    suppliers
    # ✗ waits as long as the slowest supplier takes, forever if it hangs
    |> Task.async_stream(&Shop.Suppliers.price/1, timeout: :infinity)
    |> Enum.map(fn {:ok, price} -> price end)
  end
end
```

```elixir
defmodule Shop.Suppliers do
  def price(supplier), do: Req.get!(supplier.url).body
end
```

<details><summary>Fixed</summary>

```elixir
defmodule Shop.Prices do
  def fetch_all(suppliers) do
    suppliers
    |> Task.async_stream(&Shop.Suppliers.price/1, timeout: 5_000, on_timeout: :kill_task)
    |> Enum.flat_map(fn
      {:ok, price} -> [price]
      {:exit, :timeout} -> []
    end)
  end
end
```

</details>

## API

### `no_flag_arguments`

`ArchTest.API.no_flag_arguments(modules_matching("Shop.**"))`

A boolean that picks what a function does means it does two things, and a call like `render(text, true)` doesn't
say which.

```elixir
defmodule Shop.Receipt do
  # ✗ what does true mean at the call?
  def render(text, html) when is_boolean(html) do
    if html, do: "<p>" <> text <> "</p>", else: String.trim(text)
  end
end
```

<details><summary>Fixed</summary>

```elixir
defmodule Shop.Receipt do
  def render_html(text), do: "<p>" <> text <> "</p>"
  def render_text(text), do: String.trim(text)
end
```

</details>

### `typed_identifiers`

`ArchTest.API.typed_identifiers(modules_matching("Shop.**"))`

Two account ids are both integers, so a call that swaps them moves the money the wrong way.

```elixir
defmodule Shop.Transfers do
  alias Shop.Repo

  # ✗ transfer(to, from, amount) runs too
  def transfer(from_account_id, to_account_id, amount),
    do: Repo.insert({:transfer, from_account_id, to_account_id, amount})
end
```

<details><summary>Fixed</summary>

```elixir
defmodule Shop.Account do
  defstruct [:id, :balance]
end
```

```elixir
defmodule Shop.Transfers do
  alias Shop.{Account, Repo}

  def transfer(%Account{} = from, %Account{} = to, amount),
    do: Repo.insert({:transfer, from.id, to.id, amount})
end
```

</details>

### `no_stringly_typed_choices`

`ArchTest.API.no_stringly_typed_choices(modules_matching("Shop.**"))`

Three strings matched in a `case` are an atom in disguise: a typo compiles, and nothing lists the choices.

```elixir
defmodule Shop.Shipping do
  def days(speed) do
    # ✗ "expres" compiles too
    case speed do
      "standard" -> 5
      "express" -> 2
      "overnight" -> 1
    end
  end
end
```

<details><summary>Fixed</summary>

```elixir
defmodule Shop.Shipping do
  def parse_speed("standard"), do: {:ok, :standard}
  def parse_speed("express"), do: {:ok, :express}
  def parse_speed("overnight"), do: {:ok, :overnight}
  def parse_speed(_other), do: :error

  def days(:standard), do: 5
  def days(:express), do: 2
  def days(:overnight), do: 1
end
```

</details>

### `no_alternative_return_types`

`ArchTest.API.no_alternative_return_types(modules_matching("Shop.**"))`

A function whose options change what it returns makes every caller check which kind of value came back.

```elixir
defmodule Shop.Quantity do
  def parse(text, options \\ []) do
    {quantity, rest} = Integer.parse(text)
    # ✗ an integer, or a tuple, depending on an option
    if Keyword.get(options, :discard_rest, false), do: quantity, else: {quantity, rest}
  end
end
```

<details><summary>Fixed</summary>

```elixir
defmodule Shop.Quantity do
  def parse(text) do
    {quantity, _rest} = Integer.parse(text)
    quantity
  end

  def parse_with_rest(text), do: Integer.parse(text)
end
```

</details>

## Test code

### `tests_use_their_subject`

`ArchTest.TestCode.tests_use_their_subject(modules_matching("Shop.**"))`

A test of a module that only calls a stub of it checks nothing about the module.

```elixir
defmodule Shop.Pricing do
  def total(prices), do: Enum.sum(prices)
end
```

```elixir
defmodule Shop.PricingTest do
  use ExUnit.Case, async: true

  test "totals" do
    Mimic.stub(Shop.Pricing, :total, fn _prices -> 3 end)
    # ✗ calls the stub, not Shop.Pricing
    assert Shop.Pricing.total([1, 2]) == 3
  end
end
```

<details><summary>Fixed</summary>

```elixir
defmodule Shop.PricingTest do
  use ExUnit.Case, async: true

  test "totals" do
    assert Shop.Pricing.total([1, 2]) == 3
  end
end
```

</details>

### `tests_dont_mock_pure_modules`

`ArchTest.TestCode.tests_dont_mock_pure_modules(modules_matching("Shop.**"))`

A mock of code that touches nothing outside it replaces what's as cheap to run, and the test then checks the mock.

```elixir
defmodule Shop.Pricing do
  def total(prices), do: Enum.sum(prices)
end
```

```elixir
defmodule Shop.Checkout do
  def pay(prices), do: {:charged, Shop.Pricing.total(prices)}
end
```

```elixir
defmodule Shop.CheckoutTest do
  use ExUnit.Case, async: true

  test "charges the total" do
    # ✗ Shop.Pricing.total/1 is as cheap to run as its stub
    Mimic.stub(Shop.Pricing, :total, fn _prices -> 3 end)
    assert Shop.Checkout.pay([1, 2]) == {:charged, 3}
  end
end
```

<details><summary>Fixed</summary>

```elixir
defmodule Shop.CheckoutTest do
  use ExUnit.Case, async: true

  test "charges the total" do
    assert Shop.Checkout.pay([1, 2]) == {:charged, 3}
  end
end
```

</details>

### `tests_dont_sleep`

`ArchTest.TestCode.tests_dont_sleep(modules_matching("Shop.**"))`

A sleep long enough on a fast machine is too short on a slow one, and slows every run.

```elixir
defmodule Shop.Mailer do
  def deliver_later(recipient), do: Task.start(fn -> send(recipient, :delivered) end)
end
```

```elixir
defmodule Shop.MailerTest do
  use ExUnit.Case, async: true

  test "delivers in the background" do
    Shop.Mailer.deliver_later(self())
    # ✗ too short on a slow machine, too long on a fast one
    Process.sleep(100)
    assert_received :delivered
  end
end
```

<details><summary>Fixed</summary>

```elixir
defmodule Shop.MailerTest do
  use ExUnit.Case, async: true

  test "delivers in the background" do
    Shop.Mailer.deliver_later(self())
    assert_receive :delivered
  end
end
```

</details>

### `async_tests_share_no_state`

`ArchTest.TestCode.async_tests_share_no_state(modules_matching("Shop.**"))`

Application config is global, so an async test that changes it changes it for the tests running beside it.

```elixir
defmodule Shop.Currency do
  def default, do: Application.get_env(:shop, :currency, "USD")
end
```

```elixir
defmodule Shop.CurrencyTest do
  use ExUnit.Case, async: true

  test "uses the configured currency" do
    # ✗ every test running now sees EUR
    Application.put_env(:shop, :currency, "EUR")
    assert Shop.Currency.default() == "EUR"
  end
end
```

<details><summary>Fixed</summary>

The configuration is passed in, so the test chooses it.

```elixir
defmodule Shop.Currency do
  def default(config \\ Application.get_all_env(:shop)), do: Keyword.get(config, :currency, "USD")
end
```

```elixir
defmodule Shop.CurrencyTest do
  use ExUnit.Case, async: true

  test "uses the configured currency" do
    assert Shop.Currency.default(currency: "EUR") == "EUR"
  end
end
```

</details>

## Guardrails

### `no_suppressions`

`ArchTest.Guardrails.no_suppressions(modules_matching("Shop.**"))`

A silenced warning stays a problem; AI agents silence them to get a build green.

```elixir
defmodule Shop.Report do
  # ✗ silences Credo instead of fixing the function
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  def line(order, user, item, price, tax, discount, shipping, currency, note) do
    Enum.join([order, user, item, price, tax, discount, shipping, currency, note], ",")
  end
end
```

<details><summary>Fixed</summary>

```elixir
defmodule Shop.Report do
  def line(row), do: Enum.join([row.order, row.user, row.item, row.price, row.currency], ",")
end
```

</details>

### `no_stubs`

`ArchTest.Guardrails.no_stubs(modules_matching("Shop.**"))`

A stub compiles and passes review at a glance, and does nothing.

```elixir
defmodule Shop.Refunds do
  # ✗ stands in for code nobody wrote
  def refund(_order), do: raise("not implemented yet")
end
```

<details><summary>Fixed</summary>

```elixir
defmodule Shop.Refunds do
  def refund(order), do: {:refunded, order.total}
end
```

</details>

### `no_functions_only_tests_call`

`ArchTest.Guardrails.no_functions_only_tests_call(modules_matching("Shop.**"))`

A function made public so a test can reach it ties the test to the module's internals.

```elixir
defmodule Shop.Cart do
  def total(prices), do: prices |> Enum.map(&with_tax/1) |> Enum.sum()

  # ✗ public only so the test can call it
  @doc false
  def round_cents(amount), do: round(amount * 100) / 100

  defp with_tax(price), do: price * 1.2
end
```

```elixir
defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  test "rounds to the cent" do
    assert Shop.Cart.round_cents(1.234) == 1.23
  end
end
```

<details><summary>Fixed</summary>

The test checks what the cart offers its callers.

```elixir
defmodule Shop.Cart do
  def total(prices), do: prices |> Enum.map(&with_tax/1) |> Enum.sum() |> round_cents()

  defp with_tax(price), do: price * 1.2
  defp round_cents(amount), do: round(amount * 100) / 100
end
```

```elixir
defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  test "totals with tax, to the cent" do
    assert Shop.Cart.total([1.01]) == 1.21
  end
end
```

</details>

### `no_swallowed_errors`

`ArchTest.Guardrails.no_swallowed_errors(modules_matching("Shop.**"))`

A failure turned into `nil` looks like an answer: a rate service that's down reads as a currency with no rate.

```elixir
defmodule Shop.Rates do
  def fetch(currency) do
    case Req.get("https://rates.example.com/" <> currency) do
      {:ok, response} -> response.body
      # ✗ the caller can't tell a failed request from a missing rate
      {:error, _reason} -> nil
    end
  end
end
```

<details><summary>Fixed</summary>

```elixir
defmodule Shop.Rates do
  def fetch(currency) do
    with {:ok, response} <- Req.get("https://rates.example.com/" <> currency) do
      {:ok, response.body}
    end
  end
end
```

</details>
