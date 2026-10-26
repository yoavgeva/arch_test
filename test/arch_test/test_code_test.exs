defmodule ArchTest.TestCodeTest do
  use ExUnit.Case, async: false

  alias ArchTest.{Assertions, CompiledFixture, ModuleSet, TestCode}

  @root Path.join(System.tmp_dir!(), "arch_test_test_code_fixtures")
  @ebin Path.join(@root, "ebin")
  @tests Path.join(@root, "test")

  setup_all do
    CompiledFixture.compile(@ebin, [
      {"lib/test_fixture/pricing.ex",
       """
       defmodule TestFixture.Pricing do
         def total(prices), do: Enum.sum(prices)
       end
       """},
      {"lib/test_fixture/mailer.ex",
       """
       defmodule TestFixture.Mailer do
         @callback deliver(String.t()) :: :ok
       end

       defmodule TestFixture.SmtpMailer do
         @behaviour TestFixture.Mailer

         @impl true
         def deliver(to), do: :gen_tcp.send(:socket, to)
       end

       defmodule TestFixture.Formatter do
         @callback format(String.t()) :: String.t()
       end

       defmodule TestFixture.UpcaseFormatter do
         @behaviour TestFixture.Formatter

         @impl true
         def format(text), do: String.upcase(text)
       end
       """},
      {"lib/test_fixture/checkout.ex",
       """
       defmodule TestFixture.Checkout do
         def pay(prices), do: TestFixture.Pricing.total(prices)
         def receipt(to), do: TestFixture.SmtpMailer.deliver(to)
       end
       """},
      {"lib/test_fixture/orders.ex",
       """
       defmodule TestFixture.Orders do
         def count, do: 0
       end
       """},
      {"lib/test_fixture/linter.ex",
       """
       defmodule TestFixture.Rules.Length do
         def check(text), do: if(String.length(text) > 80, do: [:too_long], else: [])
       end

       defmodule TestFixture.Rules.Width do
         def check(text), do: if(String.contains?(text, "\t"), do: [:tab], else: [])
       end

       defmodule TestFixture.Rules.Shouting do
         def check(text), do: if(text == String.upcase(text), do: [:shouting], else: [])
       end

       defmodule TestFixture.Registry do
         def rules, do: [TestFixture.Rules.Length, TestFixture.Rules.Width, TestFixture.Rules.Shouting]
       end

       defmodule TestFixture.Linter do
         def check(text), do: Enum.flat_map(TestFixture.Registry.rules(), & &1.check(text))
       end

       defmodule TestFixture.Reading do
         def read(text), do: String.split(text)
       end

       defmodule TestFixture.Api do
         def read(text), do: TestFixture.Reading.read(text)
       end
       """},
      {"lib/test_fixture/billing.ex",
       """
       defmodule TestFixture.Billing do
         def currency, do: "EUR"
       end

       defmodule TestFixture.Billing.Invoice do
         def total(lines), do: Enum.sum(lines)
       end
       """},
      {"lib/test_fixture/known_projects.ex",
       """
       defmodule TestFixture.Json do
         def decode(body), do: {:json, body}
       end

       defmodule TestFixture.Decode do
         @decoders [json: TestFixture.Json]
         def run(request), do: Keyword.fetch!(@decoders, request.format).decode(request.body)
       end

       defmodule TestFixture.Client do
         def run(request), do: Enum.reduce(steps(), request, fn {_name, step}, acc -> step.run(acc) end)
         defp steps, do: [decode: TestFixture.Decode]
       end

       defmodule TestFixture.Migrations do
         def up, do: :ok
       end

       defmodule Mix.Tasks.TestFixture.Install do
         def run(_args), do: :ok
       end

       defmodule TestFixture.Components do
         def badge(assigns), do: assigns
       end

       defmodule TestFixture.Promotions do
         @compile {:no_warn_undefined, [Shopify]}
         def discount(code), do: Shopify.create_price_rule(code)
       end

       defmodule TestFixture.Adapter do
         @callback fetch(term()) :: term()
       end

       defmodule TestFixture.HttpAdapter do
         @behaviour TestFixture.Adapter
         def fetch(request), do: request
       end

       defmodule TestFixture.Fetcher do
         def get(request), do: TestFixture.HttpAdapter.fetch(request)
       end

       defmodule TestFixture.Sigils do
         defmacro sigil_Q(text, _modifiers), do: text
       end

       defmodule TestFixture.Normalize do
         def run(input, _opts), do: {:ok, String.trim(input)}
       end

       defprotocol TestFixture.Renderable do
         def render(item)
       end

       defmodule TestFixture.Badge do
         defstruct label: "badge"

         defimpl TestFixture.Renderable do
           def render(badge), do: badge.label
         end
       end

       defmodule TestFixture.Parser do
         def parse(name), do: struct(Module.concat([TestFixture, Macro.camelize(name)]), %{})
       end

       defmodule TestFixture.Page do
         def render(item), do: TestFixture.Renderable.render(item)
       end

       defmodule TestFixture.Paying do
         def pay(code), do: TestFixture.Promotions.discount(code)
       end
       """},
      {"lib/test_fixture_web/room_channel.ex",
       """
       defmodule TestFixtureWeb.RoomChannel do
         def join(_topic, _payload, socket), do: {:ok, socket}
       end
       """},
      {"lib/test_fixture_web/page_controller.ex",
       """
       defmodule TestFixtureWeb.PageController do
         def show(conn, _params), do: conn
       end

       defmodule TestFixtureWeb.Live.Archives do
         def mount(_params, _session, socket), do: {:ok, socket}
       end
       """},
      {"lib/test_fixture/mailer.ex",
       """
       defprotocol MailLib.Recipient do
         def format(recipient)
       end

       defmodule TestFixture.Account do
         defstruct [:email]
       end

       defmodule TestFixture.Mailer do
         def deliver(email), do: {:ok, email}

         defimpl MailLib.Recipient, for: TestFixture.Account do
           def format(account), do: {"", account.email}
         end
       end
       """},
      {"lib/test_fixture/workers.ex",
       """
       defmodule TestFixture.Broadcaster do
         use GenServer

         def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
         def init(opts), do: {:ok, opts}
       end

       defmodule TestFixture.Workers do
         use Supervisor

         def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)
         def init(opts), do: Supervisor.init([{TestFixture.Broadcaster, opts}], strategy: :one_for_one)
         def topic(name), do: "workers:\#{name}"
       end
       """}
    ])

    File.rm_rf!(@tests)

    write_test("test/test_helper.exs", """
    ExUnit.start()
    Mox.defmock(TestFixture.MailerMock, for: TestFixture.Mailer)
    Mox.defmock(TestFixture.FormatterMock, for: TestFixture.Formatter)
    """)

    write_test("test/test_fixture/checkout_test.exs", """
    defmodule TestFixture.CheckoutTest do
      use ExUnit.Case, async: true
      alias TestFixture.{Checkout, Pricing}

      setup do
        Application.put_env(:test_fixture, :currency, "EUR")
        :ok
      end

      test "pays" do
        stub(Pricing, :total, fn _prices -> 10 end)
        assert [1, 2] |> Checkout.pay() == 10
      end

      test "sends a receipt" do
        expect(TestFixture.MailerMock, :deliver, fn _to -> :ok end)
        Process.sleep(50)
        assert Checkout.receipt("ada@example.com") == :ok
      end

      test "formats" do
        expect(TestFixture.FormatterMock, :format, fn text -> text end)
        :timer.sleep(10)
      end
    end
    """)

    write_test("test/test_fixture/pricing_test.exs", """
    defmodule TestFixture.PricingTest do
      use ExUnit.Case, async: false

      test "totals" do
        System.put_env("CURRENCY", "EUR")
        assert TestFixture.Orders.count() == 0
      end
    end
    """)

    write_test("test/test_fixture/orders_test.exs", """
    defmodule TestFixture.OrdersTest do
      use ExUnit.Case, async: true
      alias TestFixture.Orders

      test "counts" do
        Mimic.stub(Orders, :count, fn -> 3 end)
        assert Orders.count() == 3
      end
    end
    """)

    write_test("test/test_fixture/polling_test.exs", """
    defmodule TestFixture.PollingTest do
      use ExUnit.Case, async: true

      defmodule SlowCodec do
        def decode(binary) do
          Process.sleep(50)
          binary
        end
      end

      test "polls until the codec answers" do
        parked = spawn(fn -> Process.sleep(:infinity) end)
        assert_eventually(fn -> SlowCodec.decode("x") == "x" and Process.alive?(parked) end)
      end

      defp assert_eventually(fun, attempts \\\\ 10) do
        if fun.() or attempts == 0 do
          :ok
        else
          Process.sleep(5)
          assert_eventually(fun, attempts - 1)
        end
      end
    end
    """)

    write_test("test/test_fixture/rules/length_test.exs", """
    defmodule TestFixture.Rules.LengthTest do
      use ExUnit.Case, async: true

      test "flags long text, through the linter that runs every rule" do
        assert TestFixture.Linter.check(String.duplicate("x", 81)) == [:too_long]
      end
    end
    """)

    write_test("test/support/linting.exs", """
    defmodule TestFixture.Test.Linting do
      def findings(text), do: TestFixture.Linter.check(text)
    end
    """)

    write_test("test/test_fixture/rules/width_test.exs", """
    defmodule TestFixture.Rules.WidthTest do
      use ExUnit.Case, async: true

      test "flags tabs, through a test helper" do
        assert TestFixture.Test.Linting.findings("a\tb") == [:tab]
      end
    end
    """)

    write_test("test/test_fixture/rules/shouting_test.exs", """
    defmodule TestFixture.Rules.ShoutingTest do
      use ExUnit.Case, async: true
      import TestFixture.Test.Linting, only: [findings: 1]

      test "flags shouting, through an imported test helper" do
        assert findings("STOP") == [:shouting]
      end
    end
    """)

    write_test("test/test_fixture/reading_test.exs", """
    defmodule TestFixture.ReadingTest do
      use ExUnit.Case, async: true

      test "reads through the API" do
        assert TestFixture.Api.read("a b") == ["a", "b"]
      end
    end
    """)

    write_test("test/test_fixture/billing_test.exs", """
    defmodule TestFixture.BillingTest do
      use ExUnit.Case, async: true

      test "totals an invoice" do
        assert TestFixture.Billing.Invoice.total([1, 2]) == 3
      end
    end
    """)

    write_test("test/test_fixture_web/room_channel_test.exs", """
    defmodule TestFixtureWeb.RoomChannelTest do
      use TestFixtureWeb.ChannelCase, async: true

      test "joins", %{socket: socket} do
        assert {:ok, _reply, _socket} = subscribe_and_join(socket, "room:1", %{})
      end
    end
    """)

    write_test("test/test_fixture_web/page_controller_test.exs", """
    defmodule TestFixtureWeb.PageControllerTest do
      use TestFixtureWeb.ConnCase, async: true

      test "shows the page", %{conn: conn} do
        assert conn |> get("/") |> html_response(200)
      end
    end
    """)

    write_test("test/test_fixture/json_test.exs", """
    defmodule TestFixture.JsonTest do
      use ExUnit.Case, async: true

      test "decodes through the client's steps" do
        assert TestFixture.Client.run(%{format: :json, body: "x"}) == {:json, "x"}
      end
    end
    """)

    write_test("test/test_fixture/migrations_test.exs", """
    defmodule TestFixture.MigrationsTest do
      use ExUnit.Case, async: true

      defmodule Step do
        def up, do: TestFixture.Migrations.up()
      end

      test "migrates" do
        assert Step.up() == :ok
      end
    end
    """)

    write_test("test/mix/tasks/test_fixture.install_test.exs", """
    defmodule Mix.Tasks.TestFixture.InstallTest do
      use ExUnit.Case, async: true

      test "installs" do
        assert Mix.Task.run("test_fixture.install", []) == :ok
      end
    end
    """)

    write_test("test/test_fixture/components_test.exs", """
    defmodule TestFixture.ComponentsTest do
      use ExUnit.Case, async: true

      test "renders a badge" do
        assigns = %{}
        assert ~H|<TestFixture.Components.badge label="new" />|
      end
    end
    """)

    write_test("test/test_fixture/paying_test.exs", """
    defmodule TestFixture.PayingTest do
      use ExUnit.Case, async: true

      test "pays with a discount" do
        Mimic.stub(TestFixture.Promotions, :discount, fn _code -> {:ok, "x"} end)
        assert TestFixture.Paying.pay("x") == {:ok, "x"}
      end
    end
    """)

    write_test("test/test_fixture/slow_peer_test.exs", """
    defmodule TestFixture.SlowPeerTest do
      use ExUnit.Case, async: true

      test "times out on a slow peer" do
        assert start_peer(fn ->
                 Process.sleep(100)
                 :late
               end)
      end

      test "keeps a slow step for later" do
        steps = [fn -> Process.sleep(50) end]
        assert length(steps) == 1
      end

      test "waits in a loop" do
        Enum.each(1..2, fn _step -> Process.sleep(10) end)
      end

      defp start_peer(fun), do: fun
    end
    """)

    write_test("test/test_fixture/adapter_test.exs", """
    defmodule TestFixture.AdapterTest do
      use ExUnit.Case, async: true

      test "fetches through the adapter" do
        assert TestFixture.Fetcher.get(1) == 1
      end
    end
    """)

    write_test("test/test_fixture/sigils_test.exs", """
    defmodule TestFixture.SigilsTest do
      use TestFixture.SigilCase

      test "quotes" do
        assert ~Q"text" == "text"
      end
    end
    """)

    write_test("test/test_fixture/normalize_test.exs", """
    defmodule TestFixture.NormalizeTest do
      use TestFixture.PhaseCase, phase: TestFixture.Normalize

      test "trims" do
        assert run_phase(" a ") == {:ok, "a"}
      end
    end
    """)

    write_test("test/test_fixture/mailer_test.exs", """
    defmodule TestFixture.MailerTest do
      use ExUnit.Case, async: true

      test "formats an account as a recipient" do
        assert MailLib.Recipient.format(%TestFixture.Account{email: "a@b.c"}) == {"", "a@b.c"}
      end
    end
    """)

    write_test("test/test_fixture/broadcaster_test.exs", """
    defmodule TestFixture.BroadcasterTest do
      use ExUnit.Case, async: true

      test "forwards what it hears" do
        start_supervised!({TestFixture.Workers, name: :workers})
        assert TestFixture.Workers.topic(:workers) == "workers:workers"
      end
    end
    """)

    write_test("test/test_fixture_web/live/archives_test.exs", """
    defmodule TestFixtureWeb.Live.ArchivesTest do
      use TestFixtureWeb.ConnCase, async: true

      test "lists archives", %{conn: conn} do
        conn |> visit("/archives") |> assert_has("h1", text: "Archives")
      end
    end
    """)

    write_test("test/test_fixture/badge_test.exs", """
    defmodule TestFixture.BadgeTest do
      use ExUnit.Case, async: true

      test "renders a parsed badge" do
        assert TestFixture.Page.render(TestFixture.Parser.parse("badge")) == "badge"
      end
    end
    """)

    write_test("test/test_fixture/router_test.exs", """
    defmodule TestFixture.RouterTest do
      use ExUnit.Case, async: true

      defmodule Plug do
        def unquote(:*)(conn), do: conn

        for verb <- [:get, :post] do
          def unquote(verb)(conn), do: conn
        end
      end

      test "routes every verb" do
        assert Plug.*(1) == 1
      end
    end
    """)

    write_test("test/test_fixture/step_test.exs", """
    defmodule TestFixture.StepTest do
      use ExUnit.Case, async: true

      defmodule Step do
        def version, do: :persistent_term.get({__MODULE__, :version})
      end

      test "reads its version" do
        :persistent_term.put({Step, :version}, 2)
        assert Step.version() == 2
      end
    end
    """)

    :ok
  end

  describe "tests_use_their_subject/2" do
    test "flags a test that never uses the module it's named after, or only mocks it, and passes tests that reach it" do
      violations = capture(&TestCode.tests_use_their_subject/2)

      assert Enum.map(violations, &{&1.module, &1.file, &1.line, &1.message, &1.fix}) == [
               {TestFixture.OrdersTest, "test/test_fixture/orders_test.exs", 1,
                "TestFixture.OrdersTest only mocks TestFixture.Orders, the module it's named after",
                "test the real TestFixture.Orders, and mock only what it calls"},
               {TestFixture.PricingTest, "test/test_fixture/pricing_test.exs", 1,
                "TestFixture.PricingTest never uses TestFixture.Pricing, the module it's named after",
                "test TestFixture.Pricing itself, or name the test after the module it tests"}
             ]
    end
  end

  describe "tests_dont_mock_pure_modules/2" do
    test "flags mocks of modules and behaviours that touch nothing outside them" do
      violations = capture(&TestCode.tests_dont_mock_pure_modules/2)

      assert Enum.map(violations, &{&1.module, &1.line, &1.message}) == [
               {TestFixture.CheckoutTest, 11,
                ~s(test "pays" mocks TestFixture.Pricing.total, which touches nothing outside it, ) <>
                  "so the test checks the mock instead of the code"},
               {TestFixture.CheckoutTest, 22,
                ~s(test "formats" mocks TestFixture.FormatterMock, whose TestFixture.Formatter ) <>
                  "implementations touch nothing outside them, so the test checks the mock instead of the code"},
               {TestFixture.OrdersTest, 6,
                ~s(test "counts" mocks TestFixture.Orders.count, which touches nothing outside it, ) <>
                  "so the test checks the mock instead of the code"}
             ]

      assert hd(violations).fix ==
               "use the real module, and mock only the ones that touch the database, the network or other services"
    end
  end

  describe "tests_dont_sleep/2" do
    test "flags sleeps in tests, and passes polling helpers, slow fakes, callbacks and parked processes" do
      violations = capture(&TestCode.tests_dont_sleep/2)

      assert Enum.map(violations, &{&1.module, &1.line, &1.message}) == [
               {TestFixture.CheckoutTest, 17,
                ~s(test "sends a receipt" sleeps with Process.sleep/1, ) <>
                  "which is too short on a slow machine and slows every run"},
               {TestFixture.CheckoutTest, 23,
                ~s(test "formats" sleeps with :timer.sleep/1, which is too short on a slow machine and slows every run)},
               {TestFixture.SlowPeerTest, 17,
                ~s(test "waits in a loop" sleeps with Process.sleep/1, ) <>
                  "which is too short on a slow machine and slows every run"}
             ]

      assert hd(violations).fix ==
               "wait for what the test needs instead, with assert_receive or a monitor's :DOWN message"
    end
  end

  describe "async_tests_share_no_state/2" do
    test "flags async tests that change global state, and passes sync ones" do
      violations = capture(&TestCode.async_tests_share_no_state/2)

      assert Enum.map(violations, &{&1.module, &1.line, &1.message, &1.fix}) == [
               {TestFixture.CheckoutTest, 6,
                "setup changes global state with Application.put_env/3 in an async test, " <>
                  "so tests running at the same time can see it",
                "pass the value to the code under test instead, or make the test module async: false"}
             ]
    end
  end

  defp write_test(path, source) do
    file = Path.join(@root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, source)
  end

  defp capture(rule) do
    subject = ModuleSet.new(["TestFixture.**", "TestFixtureWeb.**", "Mix.Tasks.**"])

    File.cd!(@root, fn ->
      Assertions.capture_violations(fn ->
        rule.(subject, paths: [@ebin], test_paths: ["test"])
      end)
    end)
  end
end
