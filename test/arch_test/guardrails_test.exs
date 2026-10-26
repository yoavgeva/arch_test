defmodule ArchTest.GuardrailsTest do
  use ExUnit.Case, async: false

  alias ArchTest.{Assertions, CompiledFixture, Guardrails, ModuleSet}

  @root Path.join(System.tmp_dir!(), "arch_test_guardrails_fixtures")
  @pricing "lib/guard_fixture/pricing.ex"
  @pricing_test "test/guard_fixture/pricing_test.exs"
  @accounts "lib/guard_fixture/accounts.ex"
  @import_task "lib/guard_fixture/import_task.ex"

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
          {@accounts,
           """
           defmodule GuardFixture.Accounts do
             require Logger

             def create(attrs), do: File.write("users.txt", attrs)

             def fetch_rate(url) do
               try do
                 :httpc.request(url)
               rescue
                 _ -> nil
               end
             end

             def find(id) do
               case lookup(id) do
                 {:ok, user} -> user
                 {:error, _} -> nil
               end
             end

             def sync(attrs) do
               create(attrs)
               :ok
             end

             def parse(text) do
               try do
                 String.to_integer(text)
               rescue
                 ArgumentError -> 0
               end
             end

             def save(attrs) do
               case create(attrs) do
                 :ok -> :ok
                 {:error, reason} -> {:error, reason}
               end
             end

             def import_all(rows), do: Enum.each(rows, fn row -> create(row) end)

             def remember(attrs) do
               _ = create(attrs)
               :ok
             end

             def option(opts) do
               case Keyword.fetch(opts, :size) do
                 {:ok, size} -> size
                 :error -> 1
               end
             end

             def valid?(id), do: match?({:ok, _}, lookup(id))

             def collect(ids) do
               Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, found} ->
                 case lookup(id) do
                   {:ok, user} -> {:cont, {:ok, [user | found]}}
                   {:error, _reason} = error -> {:halt, error}
                 end
               end)
             end

             def start(id) do
               case lookup(id) do
                 {:ok, user} -> {:ok, user}
                 {:error, reason} -> {:stop, reason}
               end
             end

             def cursor(text) do
               with {:ok, time, _offset} <- DateTime.from_iso8601(text) do
                 time
               else
                 _other -> nil
               end
             end

             def load(id) do
               case lookup(id) do
                 {:ok, user} ->
                   user

                 {:error, reason} ->
                   Logger.warning("can't load \#{id}: \#{inspect(reason)}")
                   nil
               end
             end

             def exists?(id) do
               case lookup(id) do
                 {:ok, _user} -> true
                 {:error, _reason} -> false
               end
             end

             def close(pid) do
               GenServer.stop(pid)
             catch
               :exit, _reason -> :ok
             end

             def refresh(id) do
               lookup(id)
             rescue
               error ->
                 report(id, error)
                 :ok
             end

             def size(text) do
               case parse_size(text) do
                 {:ok, size} -> size
                 {:error, _reason} -> 0
               end
             end

             def tally(ids) do
               Enum.reduce(ids, %{found: 0, failed: 0}, fn id, acc ->
                 case lookup(id) do
                   {:ok, _user} -> %{acc | found: acc.found + 1}
                   {:error, _reason} -> %{acc | failed: acc.failed + 1}
                 end
               end)
             end

             def detach(pid, id) do
               close(pid)
               cancel(id)
               :ok
             end

             def pay(order) do
               case charge(order) do
                 {:ok, receipt} -> receipt
                 {:error, _reason} -> nil
               end
             end

             def save_atomically(path, data) do
               tmp = path <> ".tmp"

               with :ok <- File.write(tmp, data), :ok <- File.rename(tmp, path) do
                 :ok
               else
                 {:error, reason} ->
                   File.rm(tmp)
                   {:error, reason}
               end
             end

             defp charge(order) do
               case gateway().charge(order) do
                 {:ok, receipt} -> {:ok, receipt.id}
                 {:error, reason} -> {:error, {:declined, reason}}
               end
             end

             defp gateway, do: Application.get_env(:guard_fixture, :gateway)

             defp cancel(id), do: File.rm("locks/\#{id}")

             defp report(id, error), do: send(self(), {:failed, id, error})

             defp parse_size(text),
               do: if(text =~ ~r/^[0-9]+$/, do: {:ok, String.to_integer(text)}, else: {:error, :invalid})

             defp lookup(id), do: File.read("users/\#{id}")
           end
           """},
          {@import_task,
           """
           defmodule GuardFixture.ImportTask do
             use Mix.Task

             def run([path]) do
               case File.read(path) do
                 {:ok, text} ->
                   IO.puts(text)

                 {:error, reason} ->
                   IO.puts("can't read \#{path}: \#{inspect(reason)}")
                   :ok
               end
             end
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

  describe "no_swallowed_errors/2" do
    test "flags catch-all handlers that return success, and results that can be errors thrown away, and passes errors passed on" do
      violations =
        capture(&Guardrails.no_swallowed_errors/2)
        |> Enum.filter(&(&1.file in [@accounts, @import_task]))

      ignored = "match the result, and handle or return the error"

      assert Enum.map(violations, &{&1.caller_function, &1.line, &1.message, &1.fix}) == [
               {{:fetch_rate, 1}, 10,
                "rescues every exception and returns nil, so callers can't tell it failed",
                "rescue only the exceptions you expect and let the rest raise, or return {:error, reason}"},
               {{:find, 1}, 17, "turns any {:error, _} into nil, so callers can't tell it failed",
                "return the error, or handle only the reasons you expect"},
               {{:sync, 1}, 22, "ignores the {:error, _} that create/1 can return", ignored},
               {{:import_all, 1}, 41, "ignores the {:error, _} that create/1 can return",
                ignored},
               {{:load, 1}, 86, "turns any {:error, _} into nil, so callers can't tell it failed",
                "return the error, or handle only the reasons you expect"},
               {{:pay, 1}, 138, "turns any {:error, _} into nil, so callers can't tell it failed",
                "return the error, or handle only the reasons you expect"}
             ]
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
