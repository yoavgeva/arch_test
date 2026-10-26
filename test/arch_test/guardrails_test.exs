defmodule ArchTest.GuardrailsTest do
  use ExUnit.Case, async: false

  alias ArchTest.{Assertions, CompiledFixture, Guardrails, ModuleSet}

  @root Path.join(System.tmp_dir!(), "arch_test_guardrails_fixtures")
  @pricing "lib/guard_fixture/pricing.ex"
  @pricing_test "test/guard_fixture/pricing_test.exs"

  setup_all do
    File.rm_rf!(@root)

    sources = [
      {@pricing,
       """
       defmodule GuardFixture.Pricing do
         @moduledoc "Prices. Mentioning credo:disable in prose doesn't silence anything."

         # credo:disable-for-next-line Credo.Check.Refactor.Nesting
         def total(prices), do: Enum.sum(prices)

         @dialyzer {:nowarn_function, discount: 1}
         def discount(price), do: price * 0.9

         @doc false
         def round_cents(price), do: round(price * 100) / 100

         @doc false
         def tax(price), do: price * 0.2

         def with_tax(price), do: price + tax(price)

         def refund(_order), do: raise("not implemented yet")

         def export(_format), do: {:error, :not_implemented}

         # coveralls-ignore-next-line
         def legacy(price), do: price
       end
       """}
    ]

    sources =
      sources ++
        [
          {"lib/guard_fixture/response.ex",
           """
           defmodule GuardFixture.Validator do
             @callback validate(term()) :: :ok
           end

           defmodule GuardFixture.Response do
             @behaviour GuardFixture.Validator

             @doc false
             def validate(_response), do: :ok

             @doc false
             def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
           end
           """},
          {"deps/fake_dep/lib/generated.ex",
           """
           defmodule GuardFixture.Generated do
             # credo:disable-for-this-file
             def value, do: 1
           end
           """}
        ]

    for {file, source} <- sources, do: write(file, source)
    CompiledFixture.compile(Path.join(@root, "ebin"), sources)

    write(@pricing_test, """
    defmodule GuardFixture.PricingTest do
      use ExUnit.Case, async: true
      alias GuardFixture.Pricing

      # credo:disable-for-this-file Credo.Check.Readability.Specs
      test "rounds" do
        assert Pricing.round_cents(1.234) == 1.23
        assert 1.2 |> Pricing.tax() == 0.24
        assert Pricing.total([1, 2]) == 3
        assert GuardFixture.Response.validate(%{}) == :ok
        assert GuardFixture.Response.child_spec([]).id == GuardFixture.Response
      end
    end
    """)

    :ok
  end

  describe "no_suppressions/2" do
    test "flags comments and attributes that silence a tool, in code and tests, but not in dependencies" do
      violations = capture(&Guardrails.no_suppressions/2)

      assert Enum.map(violations, &{&1.module, &1.file, &1.line, &1.message}) == [
               {GuardFixture.Pricing, @pricing, 4,
                "# credo:disable-for-next-line Credo.Check.Refactor.Nesting silences a warning instead of fixing it"},
               {GuardFixture.Pricing, @pricing, 7,
                "@dialyzer {:nowarn_function, discount: 1} silences a warning instead of fixing it"},
               {GuardFixture.Pricing, @pricing, 22,
                "# coveralls-ignore-next-line silences a warning instead of fixing it"},
               {GuardFixture.PricingTest, @pricing_test, 5,
                "# credo:disable-for-this-file Credo.Check.Readability.Specs silences a warning instead of fixing it"}
             ]

      assert hd(violations).fix == "fix what the tool reports instead of silencing it"
    end

    test "allows the tools a project accepts" do
      violations = capture(&Guardrails.no_suppressions/2, allow: [:coveralls, :dialyzer])

      assert Enum.map(violations, & &1.line) == [4, 5]
    end
  end

  describe "no_stubs/2" do
    test "flags functions that only raise 'not implemented' or return it" do
      violations = capture(&Guardrails.no_stubs/2)

      assert Enum.map(violations, &{&1.caller_function, &1.line, &1.message}) == [
               {{:refund, 1}, 18, ~s(is a stub: it only raises "not implemented yet")},
               {{:export, 1}, 20, "is a stub: it only returns {:error, :not_implemented}"}
             ]

      assert hd(violations).fix == "implement it, or remove it until something needs it"
    end
  end

  describe "no_functions_only_tests_call/2" do
    test "flags @doc false functions only tests call, and passes callbacks and ones the code calls" do
      violations = capture(&Guardrails.no_functions_only_tests_call/2)

      assert Enum.map(violations, &{&1.caller_function, &1.line, &1.message, &1.fix}) == [
               {{:round_cents, 1}, 11,
                "is public only for tests: it's marked @doc false, and only tests call it",
                "test it through the functions that use it, and make it private, " <>
                  "or move it into a module of its own that both code and tests use"}
             ]
    end
  end

  defp write(path, source) do
    file = Path.join(@root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, source)
  end

  defp capture(rule, opts \\ []) do
    subject = ModuleSet.new("GuardFixture.**")
    opts = Keyword.merge([paths: [Path.join(@root, "ebin")], test_paths: ["test"]], opts)

    File.cd!(@root, fn -> Assertions.capture_violations(fn -> rule.(subject, opts) end) end)
  end
end
