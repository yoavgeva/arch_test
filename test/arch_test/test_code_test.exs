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
    test "flags sleeps in tests, and passes polling helpers, slow fakes and parked processes" do
      violations = capture(&TestCode.tests_dont_sleep/2)

      assert Enum.map(violations, &{&1.module, &1.line, &1.message}) == [
               {TestFixture.CheckoutTest, 17,
                ~s(test "sends a receipt" sleeps with Process.sleep/1, ) <>
                  "which is too short on a slow machine and slows every run"},
               {TestFixture.CheckoutTest, 23,
                ~s(test "formats" sleeps with :timer.sleep/1, which is too short on a slow machine and slows every run)}
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
    subject = ModuleSet.new(["TestFixture.**", "TestFixtureWeb.**"])

    File.cd!(@root, fn ->
      Assertions.capture_violations(fn ->
        rule.(subject, paths: [@ebin], test_paths: ["test"])
      end)
    end)
  end
end
