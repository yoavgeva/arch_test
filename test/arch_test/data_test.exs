defmodule ArchTest.DataTest do
  use ExUnit.Case, async: false

  alias ArchTest.{Assertions, CompiledFixture, Data, Effects, ModuleSet}

  @directory Path.join(System.tmp_dir!(), "arch_test_data_fixtures")
  @accounts "lib/data_fixture/accounts.ex"
  @ads "lib/data_fixture/ads.ex"
  @web "lib/data_fixture/web.ex"
  @billing Path.join(@directory, "src/lib/data_fixture/billing.ex")

  @billing_source """
  defmodule DataFixture.Billing.Invoice do
    # schema "invoices" do
    #   field :amount, :float
    #   field :tax_rate, :float
    #   field :amount_cents, :integer
    #   field :price, :decimal
    #   field :distance, :float
    # end
    def __changeset__ do
      %{amount: :float, tax_rate: :float, amount_cents: :integer, price: :decimal, distance: :float}
    end
  end

  defmodule DataFixture.Billing.Cart do
    defstruct items: [], total_price: 0.0, shipping_fee: 0.0, weight: 0.5
  end
  """

  setup_all do
    CompiledFixture.compile(@directory, [
      {"lib/data_fixture/repo.ex",
       """
       defmodule DataFixture.Repo do
         @compile {:no_warn_undefined, [Ecto.Repo.Queryable, Ecto.Repo.Schema, Ecto.Repo.Transaction]}

         def all(queryable, opts \\\\ []), do: Ecto.Repo.Queryable.all(__MODULE__, queryable, opts)
         def get!(queryable, id, opts \\\\ []), do: Ecto.Repo.Queryable.get!(__MODULE__, queryable, id, opts)
         def one(queryable, opts \\\\ []), do: Ecto.Repo.Queryable.one(__MODULE__, queryable, opts)
         def update(changeset, opts \\\\ []), do: Ecto.Repo.Schema.update(__MODULE__, changeset, opts)
         def update_all(queryable, updates, opts \\\\ []),
           do: Ecto.Repo.Schema.update_all(__MODULE__, queryable, updates, opts)

         def transaction(fun, opts \\\\ []), do: Ecto.Repo.Transaction.transaction(__MODULE__, fun, opts)
       end
       """},
      {@accounts,
       """
       defmodule DataFixture.Accounts.User do
         @compile {:no_warn_undefined, [Ecto.Changeset]}
         @admin_fields [:role, :admin]

         def changeset(user, attrs), do: Ecto.Changeset.cast(user, attrs, [:email, :role])
         def profile_changeset(user, attrs), do: Ecto.Changeset.cast(user, attrs, [:email, :name])
         def admin_changeset(user, attrs), do: Ecto.Changeset.cast(user, attrs, @admin_fields)
       end

       defmodule DataFixture.Accounts do
         alias DataFixture.Accounts.User
         alias DataFixture.Repo

         def update_user(user, attrs), do: user |> User.changeset(attrs) |> Repo.update()
         def update_profile(user, attrs), do: user |> User.profile_changeset(attrs) |> Repo.update()
         def set_roles(user, attrs), do: user |> User.admin_changeset(attrs) |> Repo.update()
         def get_user!(id), do: Repo.get!(User, id)
       end

       defmodule DataFixture.Audit do
         @compile {:no_warn_undefined, [Ecto.Changeset]}

         def entry(attrs), do: Ecto.Changeset.cast(%{}, attrs, [:user_id, :action, :note])
         def log(user, params), do: DataFixture.Repo.update(entry(%{user_id: user.id, note: params["note"]}))
       end

       defmodule DataFixture.Drafts do
         @compile {:no_warn_undefined, [Ecto.Changeset]}

         def changeset(draft, attrs), do: Ecto.Changeset.cast(draft, attrs, [:title, :user_id])
         def create(user, attrs), do: DataFixture.Repo.update(changeset(%{}, Map.put(attrs, "user_id", user.id)))
         def create_for(user, attrs), do: DataFixture.Repo.update(changeset(%{}, Map.merge(attrs, %{"title" => user.name})))
       end

       defmodule DataFixture.Policy do
         def authorize!(user, action), do: if(user.admin, do: :ok, else: raise("can't \#{action}"))
       end
       """},
      {@ads,
       """
       defmodule DataFixture.Ads do
         @compile {:no_warn_undefined, [Ecto.Changeset]}
         alias DataFixture.Repo

         def track_click(ad), do: ad |> Ecto.Changeset.change(clicks: ad.clicks + 1) |> Repo.update()

         def add_tag(ad, tag), do: ad |> Ecto.Changeset.change(%{tags: ad.tags ++ [tag]}) |> Repo.update()

         def rename(ad, name), do: ad |> Ecto.Changeset.change(name: name) |> Repo.update()

         def track_view(query), do: Repo.update_all(query, inc: [views: 1])

         def preview_click(ad), do: Ecto.Changeset.change(ad, clicks: ad.clicks + 1)

         def lock_account(query), do: Repo.one(%{lock: "FOR UPDATE", query: query})

         def charge(query, amount) do
           Repo.transaction(fn ->
             account = lock_account(query)
             account |> Ecto.Changeset.change(balance: account.balance - amount) |> Repo.update()
           end)
         end

         def refund(account, amount) do
           account
           |> Ecto.Changeset.change(balance: account.balance + amount)
           |> Ecto.Changeset.optimistic_lock(:version)
           |> Repo.update()
         end

         def credit(changeset, amount),
           do: Ecto.Changeset.put_change(changeset, :balance, changeset.data.balance + amount)

         def apply_credit(account, amount), do: account |> Ecto.Changeset.change() |> credit(amount) |> Repo.update()

         def move(item, before, next),
           do: item |> Ecto.Changeset.change(position: (before.position + next.position) / 2) |> Repo.update()
       end
       """},
      {@web,
       """
       defmodule DataFixture.Blog.Post do
       end

       defmodule DataFixture.Blog do
         @compile {:no_warn_undefined, [Ecto.Query.Builder.OrderBy, Ecto.Query.Builder.LimitOffset, Ecto.Query.Builder.Filter, Ecto.Query.Builder.Select]}
         alias DataFixture.Blog.Post
         alias DataFixture.Repo

         def list_posts, do: Repo.all(Post)

         def list_titles do
           query = Ecto.Query.Builder.OrderBy.apply(Post, :asc, :title)
           Repo.all(query)
         end

         def recent_posts, do: Post |> Ecto.Query.Builder.LimitOffset.apply(:limit, 10) |> Repo.all()

         def user_posts(user), do: Post |> Ecto.Query.Builder.Filter.apply(:where, user.id) |> Repo.all()

         def count_posts, do: Post |> Ecto.Query.Builder.Select.apply({:count, [], [:id]}) |> Repo.all()

         def run(query), do: Repo.all(query)

         def get_post!(id), do: Repo.get!(Post, id)

         def get_user_post!(user, id), do: Repo.get!({Post, user.id}, id)
       end

       defmodule DataFixture.PostController do
         @behaviour Plug
         alias DataFixture.{Accounts, Blog}

         def init(action), do: action
         def call(conn, action), do: phoenix_controller_pipeline(conn, action)

         def index(conn, _params), do: Map.put(conn, :posts, Blog.list_posts())

         def titles(conn, _params), do: Map.put(conn, :titles, Blog.list_titles())

         def recent(conn, _params), do: Map.put(conn, :posts, Blog.recent_posts())

         def mine(conn, _params), do: Map.put(conn, :posts, Blog.user_posts(conn.assigns.current_user))

         def count(conn, _params), do: Map.put(conn, :count, Blog.count_posts())

         def show(conn, %{"id" => id}), do: Map.put(conn, :post, Blog.get_post!(id))

         def show_mine(conn, %{"id" => id}), do: Map.put(conn, :post, Blog.get_user_post!(conn.assigns.current_user, id))

         def update_account(conn, %{"user" => attrs}), do: Accounts.update_user(conn.assigns.current_user, attrs)

         def update_profile(conn, %{"user" => attrs}), do: Accounts.update_profile(conn.assigns.current_user, attrs)

         defp phoenix_controller_pipeline(conn, action), do: apply(__MODULE__, action, [conn, conn.params])
       end

       defmodule DataFixture.AdminUserController do
         @behaviour Plug
         alias DataFixture.Accounts

         def init(action), do: action
         def call(conn, action), do: phoenix_controller_pipeline(conn, action)

         def update(conn, %{"id" => id, "user" => attrs}) do
           DataFixture.Policy.authorize!(conn.assigns.current_user, :set_roles)
           Accounts.set_roles(Accounts.get_user!(id), attrs)
         end

         defp phoenix_controller_pipeline(conn, action), do: apply(__MODULE__, action, [conn, conn.params])
       end

       defmodule DataFixture.PostIndexLive do
         @behaviour Phoenix.LiveView

         def mount(_params, _session, socket), do: {:ok, Map.put(socket, :posts, DataFixture.Blog.list_posts())}
       end

       defmodule DataFixture.PostEditLive do
         @behaviour Phoenix.LiveView

         def mount(%{"slug" => slug}, _session, socket) do
           blog = DataFixture.Blog.get_user_post!(socket.assigns.current_user, slug)
           {:ok, Map.put(socket, :assigns, %{blog: blog})}
         end

         def handle_event("open", %{"id" => id}, socket),
           do: {:noreply, Map.put(socket, :post, DataFixture.Repo.get_by(DataFixture.Blog.Post, id: id, blog_id: socket.assigns.blog.id))}
       end

       defmodule DataFixture.DraftController do
         @behaviour Plug
         alias DataFixture.{Accounts, Audit, Drafts}

         def init(action), do: action
         def call(conn, action), do: phoenix_controller_pipeline(conn, action)

         def log(conn, params), do: Audit.log(conn.assigns.current_user, params)

         def create(conn, %{"draft" => attrs}), do: Drafts.create(conn.assigns.current_user, attrs)

         def create_titled(conn, %{"draft" => attrs}), do: Drafts.create_for(conn.assigns.current_user, attrs)

         def show_user(conn, %{"id" => id}), do: with_own_user(conn, id, fn user -> Map.put(conn, :user, user) end)

         def promote(conn, %{"user" => attrs}),
           do: with_admin(conn, fn -> Accounts.update_user(conn.assigns.current_user, attrs) end)

         defp with_admin(conn, fun), do: if(conn.assigns.current_user.admin, do: fun.(), else: conn)

         defp with_own_user(conn, id, fun) do
           current = conn.assigns.current_user
           user = Accounts.get_user!(id)
           if user.id == current.id, do: fun.(user), else: conn
         end

         defp phoenix_controller_pipeline(conn, action), do: apply(__MODULE__, action, [conn, conn.params])
       end
       """},
      {@billing, @billing_source}
    ])

    File.mkdir_p!(Path.dirname(@billing))
    File.write!(@billing, @billing_source)
    :ok
  end

  describe "no_mass_assignment/2" do
    test "flags endpoints whose params reach a cast of a privileged field, and passes policies, maps the code " <>
           "builds and keys it sets" do
      violations =
        capture(&Data.no_mass_assignment/2, "DataFixture.**", policy: DataFixture.Policy)

      assert Enum.map(violations, &{&1.module, &1.caller_function, &1.line, &1.message}) == [
               {DataFixture.PostController, {:update_account, 2}, 50,
                "lets the request set :role through DataFixture.Accounts.update_user/2, which reaches " <>
                  "DataFixture.Accounts.User.changeset/2, where cast/3 takes it from the params"},
               {DataFixture.DraftController, {:create_titled, 2}, 101,
                "lets the request set :user_id through DataFixture.Drafts.create_for/2, which reaches " <>
                  "DataFixture.Drafts.changeset/2, where cast/3 takes it from the params"}
             ]

      assert hd(violations).fix ==
               "leave :role out of cast/3 and set it with put_change/3 from the current user or scope, or cast " <>
                 "it in a changeset that only endpoints checking DataFixture.Policy use"
    end
  end

  describe "no_lost_updates/2" do
    test "flags fields set from their old value before a write, and passes locks, atomic updates and neighbours" do
      violations = capture(&Data.no_lost_updates/2, "DataFixture.**")

      assert Enum.map(violations, &{&1.module, &1.caller_function, &1.line, &1.message}) == [
               {DataFixture.Ads, {:track_click, 1}, 5,
                "sets :clicks from its old value: a request that changes it between the read and this write " <>
                  "is lost"},
               {DataFixture.Ads, {:add_tag, 2}, 7,
                "sets :tags from its old value: a request that changes it between the read and this write " <>
                  "is lost"},
               {DataFixture.Ads, {:credit, 2}, 32,
                "sets :balance from its old value: a request that changes it between the read and this write " <>
                  "is lost"}
             ]

      assert hd(violations).fix ==
               "change it in the database, as Repo.update_all(query, inc: [clicks: 1]) does, or read the row with " <>
                 ~s(lock: "FOR UPDATE" in the transaction that writes it, or add optimistic_lock/3)

      assert hd(violations).file == @ads
    end
  end

  describe "no_float_money/2" do
    test "flags money fields stored as floats, and passes decimals, cents, rates and other floats" do
      violations = capture(&Data.no_float_money/2, "DataFixture.**")

      assert Enum.map(violations, &{&1.module, &1.line, &1.message}) == [
               {DataFixture.Billing.Invoice, 3,
                "stores :amount as a float, which can't hold most decimal amounts exactly, so sums and " <>
                  "comparisons drift by fractions of a cent"},
               {DataFixture.Billing.Cart, 15,
                "stores :shipping_fee as a float, which can't hold most decimal amounts exactly, so sums and " <>
                  "comparisons drift by fractions of a cent"},
               {DataFixture.Billing.Cart, 15,
                "stores :total_price as a float, which can't hold most decimal amounts exactly, so sums and " <>
                  "comparisons drift by fractions of a cent"}
             ]

      assert hd(violations).fix == "store it as a :decimal, or as an :integer count of cents"
      assert hd(violations).file == @billing
    end
  end

  describe "no_unbounded_queries/2" do
    test "flags endpoints that list every row of a table, and passes limits, filters, aggregates and unknown queries" do
      violations = capture(&Data.no_unbounded_queries/2, "DataFixture.**")

      assert Enum.map(violations, &{&1.module, &1.caller_function, &1.line, &1.message}) == [
               {DataFixture.PostController, {:index, 2}, 36,
                "loads every row of DataFixture.Blog.Post through DataFixture.Blog.list_posts/0, which reaches " <>
                  "DataFixture.Repo.all/1, so each request loads more as the table grows"},
               {DataFixture.PostController, {:titles, 2}, 38,
                "loads every row of DataFixture.Blog.Post through DataFixture.Blog.list_titles/0, which reaches " <>
                  "DataFixture.Repo.all/1, so each request loads more as the table grows"},
               {DataFixture.PostIndexLive, {:mount, 3}, 75,
                "loads every row of DataFixture.Blog.Post through DataFixture.Blog.list_posts/0, which reaches " <>
                  "DataFixture.Repo.all/1, so each request loads more as the table grows"}
             ]

      assert hd(violations).fix ==
               "paginate it, as limit and offset or a cursor do, or filter it to what the page shows"
    end
  end

  describe "Effects.reads_are_authorized/2" do
    test "flags endpoints that read a record by an id the request names, and passes the user's own and policies" do
      violations =
        capture(&Effects.reads_are_authorized/2, "DataFixture.**", policy: DataFixture.Policy)

      assert Enum.map(violations, &{&1.module, &1.caller_function, &1.line, &1.message}) == [
               {DataFixture.PostController, {:show, 2}, 46,
                "reads a record by its id through DataFixture.Blog.get_post!/1, which reaches " <>
                  "DataFixture.Repo.get!/2: nothing checks that the user asking may see it"}
             ]

      assert hd(violations).fix ==
               "pass the current user or scope to the code that reads, and scope the query to it, or check " <>
                 "DataFixture.Policy first"
    end
  end

  defp capture(rule, pattern, opts \\ []) do
    subject = ModuleSet.new(pattern)

    Assertions.capture_violations(fn ->
      rule.(subject, Keyword.put(opts, :paths, [@directory]))
    end)
  end
end
