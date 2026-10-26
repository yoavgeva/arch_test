# Effects

`ArchTest.Effects` checks what your code does to the outside world: the database, HTTP, the network, mail,
published messages, files, the console, other processes, the operating system, the clock, randomness and the
environment. It follows every call,
so `Orders.with_users/1` calling `Accounts.get_user!/1` once per order queries the database once per order, though
no `Repo` call appears in it. A check that reads one file at a time can't see that.

---

## 1. Rules

```elixir
defmodule MyApp.EffectsTest do
  use ExUnit.Case
  use ArchTest, app: :my_app
  use ArchTest.Effects

  test "no N+1 queries" do
    no_queries_in_loops(modules_matching("MyApp.**"), app: :my_app)
  end

  test "the pricing core is pure" do
    should_be_free_of_side_effects(modules_matching("MyApp.Pricing.**"), app: :my_app)
  end

  test "GenServers start fast" do
    no_work_in_init(modules_matching("MyApp.**"), app: :my_app)
  end

  test "transactions stay in the database" do
    no_io_in_transactions(modules_matching("MyApp.**"), app: :my_app)
  end

  test "writes are authorized" do
    writes_are_authorized(modules_matching("MyAppWeb.**"), app: :my_app, policy: MyApp.Policy)
  end

  test "private records are read by their owners" do
    reads_are_authorized(modules_matching("MyAppWeb.Account.**"), app: :my_app, policy: MyApp.Policy)
  end
end
```

Each violation names the file and line, the function, the path to the effect, and how to fix it:

```
  MyApp.Orders
    ✗ lib/my_app/orders.ex:5 MyApp.Orders.with_users/1
      queries the database once per item: Enum.map/2 calls MyApp.Accounts.get_user!/1, which reaches MyApp.Repo.get!/2
      → fix: load what the loop needs with one query before it, such as Repo.all with `where: x.id in ^ids`, or Repo.preload
```

They work with `ArchTest.Freeze` like any other rule, so existing violations can be frozen while new ones fail.

---

## 2. No queries in loops

`no_queries_in_loops/2` flags N+1: a query made once per item, which turns a page of 50 orders into 51 round trips.

```elixir
# flagged: one query per order, through a context function
def with_users(orders) do
  Enum.map(orders, fn order -> {order, Accounts.get_user!(order.user_id)} end)
end

# fixed: one query for all of them
def with_users(orders) do
  users = orders |> Enum.map(& &1.user_id) |> Accounts.list_users() |> Map.new(&{&1.id, &1})
  Enum.map(orders, fn order -> {order, users[order.user_id]} end)
end
```

- **A loop** is a function given to `Enum`, `Stream` or `Task.async_stream`, a function captured into one, as in
  `Enum.map(ids, &Accounts.get_user!/1)`, or a `for`: its body, its filters and its later generators. Functions
  that `Stream.resource/3`, `Stream.unfold/2`, `Stream.iterate/2` and `Stream.repeatedly/1` call run once per step
  they make up, such as a page of results, so they aren't loops here.
- **Once per item** means the call is given the item, or a value made from it, as `user_id` is in
  `user_id = order.user_id`.
- **A query** reads the database or makes an HTTP request, directly or through the functions it calls. Writes
  aren't queries, and neither are functions named for a change, such as `create_user/1`, `send_email/2` or
  `Req.post!/2`: a loop of commands is often what the code means to do. Raw SQL that writes is a write too, as
  `Repo.query!("UPDATE ...", params)` is, whether the statement is a string, an interpolated one, or built by a
  function of the module, as an `update_sql(table)` helper builds one.

---

## 3. Functional cores

`should_be_free_of_side_effects/2` keeps the modules you give it pure: functional core, imperative shell.

It reports each call that leaves the core and has an effect, once per function and kind of effect, at the call:
a call to a library such as `DateTime.utc_now/0`, or to a project function outside the core that has the effect.
Calls between core functions aren't reported, since the call that leaves the core already is.

```
✗ lib/my_app/pricing/calendar.ex:4 MyApp.Pricing.Calendar.weekend?/0
  reads the clock through Date.utc_today/0
  → fix: move the call out to the code that uses the functional core, and pass its result in as an argument
```

`allow:` lists effects the core may have, from `:database`, `:http`, `:network`, `:mail`, `:publish`, `:file`,
`:console`, `:system`, `:process`, `:clock`, `:random` and `:env`:

```elixir
should_be_free_of_side_effects(modules_matching("MyApp.Pricing.**"), app: :my_app, allow: [:clock])
```

---

## 4. No work in GenServer init

`no_work_in_init/2` flags a GenServer whose `init/1` does I/O — the database, HTTP, the network, files or the
operating system — directly or through what it calls. A supervisor starts its children one at a time and waits for
each `init/1`, so slow or failing work there delays or stops the whole application.

```elixir
# flagged
def init(path), do: {:ok, File.read!(path)}

# fixed
def init(path), do: {:ok, %{path: path}, {:continue, :load}}
def handle_continue(:load, state), do: {:noreply, Map.put(state, :prices, File.read!(state.path))}
```

Starting processes, scheduling messages and reading configuration aren't I/O.

---

## 5. No I/O in transactions

`no_io_in_transactions/2` flags a call inside a transaction that makes an HTTP request, uses the network, sends
email or publishes a message, directly or through what it calls. A rollback can't take back what went out: the
customer has the receipt for an order that was never saved, or subscribers heard about a change that didn't happen.
And the transaction holds its database connection while it waits on the other side, so a slow API drains the pool.

```elixir
# flagged
Repo.transaction(fn ->
  order = Repo.insert!(changeset)
  Mailer.deliver(receipt(order))
  order
end)

# fixed: send it after the commit
with {:ok, order} <- Repo.transaction(fn -> Repo.insert!(changeset) end) do
  Mailer.deliver(receipt(order))
  {:ok, order}
end
```

A transaction is a function given to a repo's `transaction/1,2` or `transact/1,2`, or to `Ecto.Multi.run/3,5`. When
the work must happen exactly once with the data, record it in the transaction, as an outbox row or an Oban job, and
do it after the commit.

---

## 6. Writes are authorized

`writes_are_authorized/2` flags an endpoint that writes to the database, directly or through what it calls, with
nothing tying the change to the user asking. Anyone who can reach it can change any record whose id they send: the
hole AI-written endpoints leave most.

```elixir
# flagged: cancels whichever order the id names
def cancel(conn, %{"id" => id}) do
  {:ok, order} = Orders.cancel_order(id)
  json(conn, order)
end

# fixed: the context scopes the change to the current user
def cancel(conn, %{"id" => id}) do
  {:ok, order} = Orders.cancel_order(conn.assigns.current_user, id)
  json(conn, order)
end
```

Endpoints are controller actions, a LiveView's or LiveComponent's `handle_event/3` and a channel's `handle_in/3`. A
write passes when:

- **it's made on behalf of the user asking**: the call that leads to it is given the current user, scope or auth
  subject, as `conn.assigns.current_user`, `socket.assigns.current_scope`, `conn.assigns.subject`,
  `Guardian.Plug.current_resource(conn)`, a `current_user(conn)` helper, or a value made from them, such as `user.id`.
  This is how Phoenix's scopes and most contexts authorize: the query only finds the user's own records. A record
  compared with the user's values counts too, as `post` does once `post.user_id == user.id` checks it, and so does the
  read that loaded it. A call given `conn` or `socket` is followed, since it can read the user from them;
- **it runs in a function given to a helper that reads the user first**, as one that checks the user's role and then
  runs the change does:

```elixir
def cancel(conn, %{"id" => id}) do
  with_own_order(conn, id, fn order -> Orders.cancel_order(order) end)
end

defp with_own_order(conn, id, fun) do
  order = Orders.get_order!(id)
  if order.user_id == conn.assigns.current_user.id, do: fun.(order), else: send_resp(conn, 403, "")
end
```

- **it's a LiveView event acting on a record the socket holds**, as `Posts.update_post(socket.assigns.post, attrs)`,
  and the LiveView's `mount/3` or `handle_params/3` loads its records for the user asking, as
  `Posts.get_user_post!(socket.assigns.current_user, id)` does, or the LiveComponent's `update/2` is given the user
  by its parent. A `mount/3` that loads the post for anyone leaves the event flagged;
- **every route to it is a GET or HEAD**: a request to read, so what it writes is bookkeeping, as a cache or a view
  count is;
- **or a policy is checked**: the endpoint, one of its controller's plugs, a pipeline every route to the action
  goes through, as `pipe_through :require_admin` does, or, for a LiveView's events, its own `on_mount` hooks or
  those of the `live_session` every route to it is in, calls `Bodyguard`, `Canada`, or a module given as `policy:`:

```elixir
writes_are_authorized(modules_matching("MyAppWeb.**"), app: :my_app,
  policy: [MyApp.Policy, MyAppWeb.Plugs.RequireAdmin])
```

Some endpoints are public by design: sign-up, log-in, password reset, webhooks verified by a signature. The secret in
the request is their check. Leave them out of the subject:

```elixir
modules_matching("MyAppWeb.**")
|> excluding(["MyAppWeb.UserSessionController", "MyAppWeb.UserRegistrationLive", "MyAppWeb.WebhookController"])
```

---

## 7. Reads are authorized

`reads_are_authorized/2` flags an endpoint that loads a record by a key the request sends, with nothing tying the read
to the user asking. Anyone signed in can then read anyone's record by changing the id in the URL.

```elixir
# flagged: shows whichever order the id names
def show(conn, %{"id" => id}), do: json(conn, Orders.get_order!(id))

# fixed: the context scopes the read to the current user
def show(conn, %{"id" => id}), do: json(conn, Orders.get_order!(conn.assigns.current_user, id))
```

It follows what the request sends — an action's, event's or message's params, a LiveView's URL params, a channel's
topic and payload — through the functions it's passed to, converted or not, as `String.to_integer(id)` is, into the
key of a repo's `get/2,3`, `get!/2,3`, `get_by/2,3` or `get_by!/2,3`. Endpoints are those `writes_are_authorized/2`
checks, and a LiveView's `mount/3` and `handle_params/3` and a channel's `join/3`. A read passes on the same terms as
a write, except that a GET route is a read like any other:

- the call that leads to it is given the user asking, or a record a LiveView loaded for them;
- it's made in a helper that reads the user, as one that loads an organization and then checks the user's role in
  it does;
- or a policy checks the endpoint.

Many records are public by design: published posts, packages, profiles. So this rule isn't in
`ArchTest.Recommended`: point it at the endpoints that show private data.

---

## 8. What counts as an effect

An effect is a call to a library that touches the outside world, or to a project function that makes one:

| Effect | Calls |
|---|---|
| database | Ecto repos (through `Ecto.Repo.Queryable`, `Ecto.Repo.Schema` and `Ecto.Adapters.SQL`), Postgrex, MyXQL, Redix, Mongo, Xandra |
| HTTP | `Req`, `Finch`, `HTTPoison`, `Tesla`, `Mint`, `:httpc`, `:hackney`, `:gun` |
| network | `:gen_tcp`, `:gen_udp`, `:ssl`, host name lookups |
| mail | `Swoosh.Mailer`, `Bamboo.Mailer`, `:gen_smtp_client` |
| publish | `Phoenix.PubSub` and endpoint broadcasts, `AMQP.Basic.publish/4`, `:brod` and `KafkaEx` produce |
| files | `File`, `:file`, `:filelib`, `Path.wildcard/2` |
| console | `IO.puts/1`, `IO.inspect/2`, `IO.gets/1`, `:io.format/2` and the like |
| system | `System.cmd/3`, `Port`, `:os.cmd/1` |
| process | `send/2`, `spawn`, `GenServer`, `Agent`, `Task`, `Registry`, `:ets`, `:persistent_term`, `Phoenix.PubSub.subscribe/2` |
| clock | `DateTime.utc_now/0`, `Date.utc_today/0`, `System.system_time/0` and the like |
| randomness | `:rand`, `:crypto.strong_rand_bytes/1`, `Enum.random/1`, `Ecto.UUID.generate/0` |
| environment | `System.get_env/1`, `Application.get_env/2` and the like |

Building a value isn't an effect: `Req.new/1`, `Finch.build/4` and `Ecto.Query.from/2` only describe a request or a
query.

The rules read your code from the BEAM files' debug info, after macro expansion, so aliases, imports, `use` and
module attributes are resolved. They follow calls into the modules of the app in scope — `app:`, `apps:` or
`paths:` — and treat calls into dependencies as effects only when the dependency is in the table above. A call
through a module held in a variable, as in `adapter.charge(order)`, isn't followed, since the code doesn't say
which module runs.
