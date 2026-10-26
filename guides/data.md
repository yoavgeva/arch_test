# Data

`ArchTest.Data` checks how code treats stored data: who may set which fields, what concurrent writes do to them, what
type money is stored as, and how many rows a request loads. Like `ArchTest.Effects`, it reads your code from the BEAM
files' debug info, after macro expansion, and follows every call: a controller action reaches the changeset its
context builds.

```elixir
defmodule MyApp.DataTest do
  use ExUnit.Case
  use ArchTest, app: :my_app
  use ArchTest.Data

  test "requests can't set privileged fields" do
    no_mass_assignment(modules_matching("MyAppWeb.**"), app: :my_app, policy: MyApp.Policy)
  end

  test "no lost updates" do
    no_lost_updates(modules_matching("MyApp.**"), app: :my_app)
  end

  test "money isn't a float" do
    no_float_money(modules_matching("MyApp.**"), app: :my_app)
  end

  test "pages don't load whole tables" do
    no_unbounded_queries(modules_matching("MyAppWeb.**"), app: :my_app)
  end
end
```

---

## 1. No mass assignment

A changeset that casts `role` from the params lets any user who adds `user[role]=admin` to a form make themselves an
admin, though the endpoint only changes their own account.

```elixir
# flagged: the params reach a cast of :role
def update(conn, %{"user" => params}) do
  {:ok, user} = Accounts.update_user(conn.assigns.current_user, params)
  json(conn, user)
end

def changeset(user, attrs), do: cast(user, attrs, [:email, :name, :role])

# fixed: the user's changeset leaves :role out; an admin's sets it
def changeset(user, attrs), do: cast(user, attrs, [:email, :name])
def role_changeset(user, role), do: change(user, role: role)
```

`no_mass_assignment/2` follows the params of each controller action, LiveView or LiveComponent event and channel
message, through the functions they're passed to, into `Ecto.Changeset.cast/3,4`. It flags a cast that takes a
privileged field from them:

- one that grants access: `role`, `roles`, `admin`, `is_admin`, `superuser`, `super_admin`, `staff`, `permissions`;
- one that names an owner: `user_id`, `owner_id`, `account_id`, `organization_id`, `org_id`, `team_id`,
  `tenant_id`;
- one that records a check the server makes: `verified`, `email_verified`, `verified_at`, `confirmed`,
  `confirmed_at`, `approved`, `hashed_password`, `password_hash`.

Only the params map itself counts, or a map inside it, as `params["user"]` is. A map the code builds, as
`%{user_id: user.id, note: params["note"]}`, holds the keys the code chose. Keys the code puts, merges in or drops on
the way, as `Map.put(params, "user_id", user.id)` and `Map.drop(params, ["approved"])` do, are the code's too. And
the changeset must be saved: a changeset built only to show a form's errors, as a `"validate"` event's is, sets
nothing.

A change a policy checks passes, as `ArchTest.Effects.writes_are_authorized/2` reads one: the endpoint, its
controller's plugs, its router pipelines or its `live_session` hooks call a module given as `policy:`. So does a
change made in a function given to a helper that checks the user first, as
`with_admin(conn, fn -> Accounts.set_role(user, params) end)` does. Passing the current user doesn't count: a user
changing their own record is the case this rule is about.

---

## 2. No lost updates

Two requests at once both read the same stock, both write their own result, and one sale is lost.

```elixir
# flagged: stock is computed from the value read before the write
def sell(product, quantity), do: product |> change(stock: product.stock - quantity) |> Repo.update()

# fixed: the database computes it
def sell(product, quantity), do: Repo.update_all(where(Product, id: ^product.id), inc: [stock: -quantity])
```

`no_lost_updates/2` flags `change/2`, `cast/3`, `put_change/3` and `force_change/3` setting a field from the old value
of the same field: arithmetic, `Decimal` arithmetic and `++`, as `post.views + 1` and `list.tags ++ [tag]` are.
Formatting a string, as `"New " <> post.title` does, isn't counting.
A value made from other records, such as a position between two neighbours, isn't one. It's flagged when the function,
or one that calls it, writes to the database, and the row isn't locked:

- with `Ecto.Changeset.optimistic_lock/3`, which makes the second write fail instead;
- or with `lock: "FOR UPDATE"` in a query the function, or its caller, makes or calls, inside a transaction it opens
  around the work, itself or through a helper it gives the work to. A lock taken outside a transaction ends with the
  read that takes it, and the message says so.

---

## 3. No float money

`0.1 + 0.2` is `0.30000000000000004`, so float totals drift by fractions of a cent.

```elixir
# flagged
field :total_price, :float

# fixed
field :total_price, :decimal
field :total_price_cents, :integer
```

`no_float_money/2` flags an Ecto schema's `:float` field, or a struct field that defaults to a float, when its name
names an amount of money: `price`, `amount`, `cost`, `fee`, `balance`, `salary`, `tax`, `revenue`, `budget`,
`payment`, `refund`, `payout`, `wage`, `subtotal`, `cents` and the like, anywhere in the name. A name that makes it a
ratio or count, as `tax_rate`, `fee_percent` and `price_count` do, passes.

---

## 4. No unbounded queries

A page that loads every row is fast with a hundred products and times out with a million.

```elixir
# flagged
def index(conn, _params), do: json(conn, Repo.all(Product))

# fixed
def index(conn, %{"page" => page}) do
  page = String.to_integer(page)
  json(conn, Product |> limit(50) |> offset(^((page - 1) * 50)) |> Repo.all())
end
```

`no_unbounded_queries/2` flags an endpoint that reaches, directly or through what it calls, a repo's `all/1,2` given
a schema, or a query with no `where`, `limit` or aggregate, such as `count(p.id)`, and no join on a pinned value, as
`join: m in assoc(p, :memberships), on: m.project_id == ^project.id` is, which filters as a `where` does. Endpoints are controller actions,
a LiveView's `mount/3`, `handle_params/3` and `handle_event/3`, a LiveComponent's `handle_event/3`, and a channel's
`join/3` and `handle_in/3`. A query a function is given, or one another function builds, isn't known, so it isn't
counted.

A table that stays small, such as a list of countries, can stay whole: leave its endpoint out of the subject. For that
reason this rule isn't in `ArchTest.Recommended`.
