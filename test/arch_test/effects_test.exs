defmodule ArchTest.EffectsTest do
  use ExUnit.Case, async: false

  alias ArchTest.{Assertions, CompiledFixture, Effects, ModuleSet}

  @directory Path.join(System.tmp_dir!(), "arch_test_effects_fixtures")
  @orders "lib/effects_fixture/orders.ex"
  @core "lib/effects_fixture/core.ex"
  @servers "lib/effects_fixture/servers.ex"
  @billing "lib/effects_fixture/billing.ex"
  @query_fix "load what the loop needs with one query before it, such as Repo.all with `where: x.id in ^ids`, " <>
               "or Repo.preload"

  setup_all do
    CompiledFixture.compile(@directory, [
      {"lib/effects_fixture/repo.ex",
       """
       defmodule EffectsFixture.Repo do
         @compile {:no_warn_undefined, [Ecto.Repo.Queryable, Ecto.Repo.Schema, Ecto.Repo.Transaction, Ecto.Adapters.SQL]}

         def all(queryable, opts \\\\ []), do: Ecto.Repo.Queryable.all(__MODULE__, queryable, opts)
         def get!(queryable, id, opts \\\\ []), do: Ecto.Repo.Queryable.get!(__MODULE__, queryable, id, opts)
         def insert(struct, opts \\\\ []), do: Ecto.Repo.Schema.insert(__MODULE__, struct, opts)
         def query!(sql, params), do: Ecto.Adapters.SQL.query!(__MODULE__, sql, params)
         def transaction(fun, opts \\\\ []), do: Ecto.Repo.Transaction.transaction(__MODULE__, fun, opts)
       end
       """},
      {"lib/effects_fixture/accounts.ex",
       """
       defmodule EffectsFixture.Accounts do
         alias EffectsFixture.Repo

         def get_user!(id), do: Repo.get!(:users, id)
         def list_users(ids), do: Repo.all({:users, ids})
         def create_user(attrs), do: Repo.insert(attrs)
         def display_name(user), do: String.upcase(user.name)
       end
       """},
      {@orders,
       """
       defmodule EffectsFixture.Orders do
         alias EffectsFixture.{Accounts, Repo}

         def with_users(orders) do
           Enum.map(orders, fn order -> {order, Accounts.get_user!(order.user_id)} end)
         end

         def users(ids), do: Enum.map(ids, &Accounts.get_user!/1)

         def owners(orders) do
           for order <- orders do
             user_id = order.user_id
             Repo.get!(:users, user_id)
           end
         end

         def touch_all(ids), do: Enum.each(ids, fn id -> load(id) end)

         def totals(ids) do
           Enum.reduce(ids, 0, fn id, sum -> sum + Accounts.get_user!(id).balance end)
         end

         def fetch_all(urls), do: Enum.map(urls, fn url -> :httpc.request(url) end)

         def streamed(ids), do: ids |> Stream.map(&Accounts.get_user!/1) |> Enum.to_list()

         def with_users_batched(orders) do
           users = Accounts.list_users(Enum.map(orders, & &1.user_id))
           Enum.map(orders, fn order -> {order, Map.get(users, order.user_id)} end)
         end

         def names(users), do: Enum.map(users, &Accounts.display_name/1)

         def import_users(rows), do: Enum.each(rows, &Accounts.create_user/1)

         def count, do: length(Repo.all(:orders))

         def lines(orders), do: for(order <- orders, line <- Repo.all({:lines, order.id}), do: line)

         def pages(query) do
           Stream.resource(fn -> 0 end, fn page -> {Repo.all({query, page}), page + 1} end, fn _page -> :ok end)
         end

         @bump_sql "UPDATE counts SET n = n + 1 WHERE id = $1"
         def bump(rows), do: Enum.each(rows, fn row -> Repo.query!(@bump_sql, [row.id]) end)

         def titles(ids), do: Enum.map(ids, fn id -> Repo.query!("SELECT title FROM scenes WHERE id = $1", [id]) end)

         def bump_table(rows, table), do: Enum.each(rows, fn row -> Repo.query!(update_sql(table), [row.id]) end)

         defp update_sql(table), do: "UPDATE \#{table} SET n = n + 1 WHERE id = $1"

         defp load(id), do: Repo.get!(:orders, id)
       end
       """},
      {@billing,
       """
       defmodule EffectsFixture.Mailer do
         @compile {:no_warn_undefined, [Swoosh.Mailer]}

         def deliver(email), do: Swoosh.Mailer.deliver(email, [])
       end

       defmodule EffectsFixture.Billing do
         @compile {:no_warn_undefined, [Ecto.Multi, Phoenix.PubSub]}
         alias EffectsFixture.{Mailer, Repo}

         def charge(order) do
           Repo.transaction(fn ->
             Repo.insert(order)
             :httpc.request(order.payment_url)
           end)
         end

         def place(order) do
           Repo.transaction(fn ->
             Repo.insert(order)
             notify(order)
           end)
         end

         def announce(multi, order) do
           Ecto.Multi.run(multi, :announce, fn _repo, _changes ->
             {:ok, Phoenix.PubSub.broadcast(EffectsFixture.PubSub, "orders", order)}
           end)
         end

         def place_then_notify(order) do
           {:ok, placed} = Repo.transaction(fn -> Repo.insert(order) end)
           notify(placed)
         end

         defp notify(order), do: Mailer.deliver(order.email)
       end
       """},
      {@core,
       """
       defmodule EffectsFixture.Core.Pricing do
         alias EffectsFixture.Core.Calendar

         def total(items), do: items |> Enum.map(& &1.price) |> Enum.sum()

         def discounted(price), do: if(Calendar.weekend?(), do: price * 0.9, else: price)
       end

       defmodule EffectsFixture.Core.Calendar do
         def weekend?, do: Date.day_of_week(Date.utc_today()) >= 6
       end

       defmodule EffectsFixture.Core.Invoice do
         def number(order), do: "INV-\#{order.id}-\#{EffectsFixture.Orders.count()}"

         def print(invoice), do: IO.puts(invoice)
       end
       """},
      {@servers,
       """
       defmodule EffectsFixture.PriceCache do
         use GenServer

         @impl true
         def init(path), do: {:ok, load(path)}

         defp load(path), do: File.read!(path)
       end

       defmodule EffectsFixture.LazyPriceCache do
         use GenServer

         @impl true
         def init(path), do: {:ok, %{path: path}, {:continue, :load}}

         @impl true
         def handle_continue(:load, state), do: {:noreply, Map.put(state, :prices, File.read!(state.path))}
       end

       defmodule EffectsFixture.TlsClient do
         use GenServer

         @impl true
         def init(options) do
           :ok = :ssl.start()
           {:ok, options}
         end
       end

       defmodule EffectsFixture.Ticker do
         use GenServer

         @impl true
         def init(count) do
           Process.send_after(self(), :tick, 1000)
           {:ok, count}
         end
       end
       """}
    ])

    :ok
  end

  describe "no_queries_in_loops/2" do
    test "flags a query made once per item, through every kind of loop and call" do
      violations = capture(&Effects.no_queries_in_loops/2, "EffectsFixture.Orders")

      assert Enum.map(violations, &{&1.caller_function, &1.line, &1.message}) == [
               {{:with_users, 1}, 5,
                "queries the database once per item: Enum.map/2 calls EffectsFixture.Accounts.get_user!/1, " <>
                  "which reaches EffectsFixture.Repo.get!/2"},
               {{:users, 1}, 8,
                "queries the database once per item: Enum.map/2 calls EffectsFixture.Accounts.get_user!/1, " <>
                  "which reaches EffectsFixture.Repo.get!/2"},
               {{:owners, 1}, 13,
                "queries the database once per item: for calls EffectsFixture.Repo.get!/2"},
               {{:touch_all, 1}, 17,
                "queries the database once per item: Enum.each/2 calls load/1, which reaches EffectsFixture.Repo.get!/2"},
               {{:totals, 1}, 20,
                "queries the database once per item: Enum.reduce/3 calls EffectsFixture.Accounts.get_user!/1, " <>
                  "which reaches EffectsFixture.Repo.get!/2"},
               {{:fetch_all, 1}, 23,
                "makes an HTTP request once per item: Enum.map/2 calls :httpc.request/1"},
               {{:streamed, 1}, 25,
                "queries the database once per item: Stream.map/2 calls EffectsFixture.Accounts.get_user!/1, " <>
                  "which reaches EffectsFixture.Repo.get!/2"},
               {{:lines, 1}, 38,
                "queries the database once per item: for calls EffectsFixture.Repo.all/1"},
               {{:titles, 1}, 47,
                "queries the database once per item: Enum.map/2 calls EffectsFixture.Repo.query!/2"}
             ]
    end

    test "reports where the loop is, and how to fix it" do
      [violation | _] = capture(&Effects.no_queries_in_loops/2, "EffectsFixture.Orders")

      assert violation.rule == "no_queries_in_loops"
      assert violation.module == EffectsFixture.Orders
      assert violation.file == @orders

      assert {violation.callee, violation.callee_function} ==
               {EffectsFixture.Accounts, {:get_user!, 1}}

      assert violation.fix == @query_fix
    end

    test "passes code that queries once before the loop, or only computes or writes per item" do
      batched = [
        "with_users_batched",
        "names",
        "import_users",
        "count",
        "pages",
        "bump",
        "bump_table"
      ]

      reported = capture(&Effects.no_queries_in_loops/2, "EffectsFixture.Orders")

      assert Enum.filter(reported, fn violation ->
               Atom.to_string(elem(violation.caller_function, 0)) in batched
             end) ==
               []
    end
  end

  describe "should_be_free_of_side_effects/2" do
    test "flags each call that leaves the functional core, at the call" do
      violations = capture(&Effects.should_be_free_of_side_effects/2, "EffectsFixture.Core.**")

      assert Enum.map(violations, &{&1.module, &1.caller_function, &1.line, &1.message}) == [
               {EffectsFixture.Core.Calendar, {:weekend?, 0}, 10,
                "reads the clock through Date.utc_today/0"},
               {EffectsFixture.Core.Invoice, {:number, 1}, 14,
                "touches the database through EffectsFixture.Orders.count/0, " <>
                  "which reaches EffectsFixture.Repo.all/1"},
               {EffectsFixture.Core.Invoice, {:print, 1}, 16,
                "writes to the console through IO.puts/1"}
             ]

      assert Enum.all?(
               violations,
               &(&1.file == @core and &1.rule == "should_be_free_of_side_effects")
             )
    end

    test "allows the effects a project accepts in its core" do
      violations =
        capture(&Effects.should_be_free_of_side_effects/2, "EffectsFixture.Core.**",
          allow: [:console, :clock]
        )

      assert Enum.map(violations, & &1.caller_function) == [{:number, 1}]
    end
  end

  describe "no_io_in_transactions/2" do
    test "flags calls inside a transaction that reach outside the database, and passes ones after the commit" do
      violations = capture(&Effects.no_io_in_transactions/2, "EffectsFixture.Billing")

      held =
        ": the transaction holds its database connection while it waits, and a rollback can't undo it"

      assert Enum.map(violations, &{&1.caller_function, &1.line, &1.message}) == [
               {{:charge, 1}, 14,
                "makes an HTTP request inside EffectsFixture.Repo.transaction/1 through :httpc.request/1" <>
                  held},
               {{:place, 1}, 21,
                "sends email inside EffectsFixture.Repo.transaction/1 through notify/1, " <>
                  "which reaches Swoosh.Mailer.deliver/2" <> held},
               {{:announce, 2}, 27,
                "publishes a message inside Ecto.Multi.run/3 through Phoenix.PubSub.broadcast/3" <>
                  held}
             ]

      assert hd(violations).file == @billing

      assert hd(violations).fix ==
               "do it after the transaction commits, or record it in the transaction, as an outbox row or an " <>
                 "Oban job, and do it after the commit"
    end
  end

  describe "no_work_in_init/2" do
    test "flags a GenServer whose init/1 does I/O, and passes deferred work, scheduling and starting an application" do
      violations = capture(&Effects.no_work_in_init/2, "EffectsFixture.**")

      assert Enum.map(violations, &{&1.module, &1.line, &1.message, &1.fix}) == [
               {EffectsFixture.PriceCache, 5,
                "touches files during init/1 through load/1, which reaches File.read!/1, " <>
                  "so its supervisor waits until the work is done",
                "return {:ok, state, {:continue, :load}} from init/1, and do the work in handle_continue/2"}
             ]

      assert hd(violations).file == @servers
    end
  end

  defp capture(rule, pattern, opts \\ []) do
    subject = ModuleSet.new(pattern)

    Assertions.capture_violations(fn ->
      rule.(subject, Keyword.put(opts, :paths, [@directory]))
    end)
  end
end
