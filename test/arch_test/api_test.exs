defmodule ArchTest.APITest do
  use ExUnit.Case, async: false

  alias ArchTest.{API, Assertions, CompiledFixture, ModuleSet}

  @directory Path.join(System.tmp_dir!(), "arch_test_api_fixtures")

  setup_all do
    CompiledFixture.compile(@directory, [
      {"lib/api_fixture/receipt.ex",
       """
       defmodule ApiFixture.Receipt do
         @spec render(String.t(), boolean()) :: String.t()
         def render(text, html) do
           if html, do: "<p>" <> text <> "</p>", else: String.trim(text)
         end

         def format(amount, rounded \\\\ false) do
           case rounded do
             true -> round(amount)
             false -> amount
           end
         end

         def total(items, true), do: Enum.sum(items)
         def total(items, false), do: length(items)

         def greet(name, nil), do: "Hi " <> name
         def greet(name, title), do: "Hi " <> title <> " " <> name

         def label(user) do
           if user, do: user.name, else: "guest"
         end

         def round_to(amount, places \\\\ 2), do: Float.round(amount, places)

         def log(message, verbose \\\\ false), do: {message, verbose}

         def marker(nil), do: 0
         def marker(false), do: 1
         def marker(true), do: 2
       end
       """},
      {"lib/api_fixture/transfers.ex",
       """
       defmodule ApiFixture.Transfers do
         def transfer(from_account_id, to_account_id, amount), do: {from_account_id, to_account_id, amount}
         def move(%{id: from}, %{id: to}, amount), do: {from, to, amount}
         def get(id), do: id
         def link(user_id, %{id: _} = group, role), do: {user_id, group, role}
       end
       """},
      {"lib/api_fixture/shipping.ex",
       """
       defmodule ApiFixture.Shipping do
         def days(speed) do
           case speed do
             "standard" -> 5
             "express" -> 2
             "overnight" -> 1
           end
         end

         def cost("standard"), do: 10
         def cost("express"), do: 20
         def cost("overnight"), do: 40

         def parse_speed("standard"), do: {:ok, :standard}
         def parse_speed("express"), do: {:ok, :express}
         def parse_speed("overnight"), do: {:ok, :overnight}
         def parse_speed(_other), do: :error

         def __kind__("standard"), do: 1
         def __kind__("express"), do: 2
         def __kind__("overnight"), do: 3

         def label(speed) do
           case speed do
             "express" -> "Fast"
             _ -> "Normal"
           end
         end
       end
       """},
      {"lib/api_fixture/parser.ex",
       """
       defmodule ApiFixture.Parser do
         def parse(string, options \\\\ []) do
           {int, rest} = Integer.parse(string)
           if Keyword.get(options, :discard_rest, false), do: int, else: {int, rest}
         end

         def lookup(map, key, opts) do
           case opts[:strict] do
             true -> Map.fetch!(map, key)
             _ -> Map.get(map, key)
           end
         end

         def size(context), do: context[:size] || 10
         def limit(opts), do: Keyword.get(opts, :limit) || [10]

         def files(opts) do
           mine = ["a.txt"]
           if opts[:only_mine], do: mine, else: ["b.txt" | mine]
         end

         def merged(request, opts) do
           if opts[:plug], do: %{request | adapter: :plug}, else: request
         end

         def find(map, key, opts) do
           if Keyword.get(opts, :required, false) do
             with :error <- Map.fetch(map, key), do: {:error, :missing}
           else
             {:ok, Map.get(map, key)}
           end
         end
       end
       """},
      {"lib/api_fixture/vocabulary.ex",
       """
       defmodule ApiFixture.Vocabulary do
         def parse_size("small"), do: 1
         def parse_size("medium"), do: 2
         def parse_size("large"), do: 3

         def digest("MD5"), do: {:ok, :md5, false}
         def digest("SHA"), do: {:ok, :sha, true}
         def digest("SHA-256"), do: {:ok, :sha256, true}
         def digest(_other), do: :error

         def closing("("), do: ")"
         def closing("["), do: "]"
         def closing("{"), do: "}"

         def title("index.html"), do: "Home"
         def title("about.html"), do: "About"
         def title("contact.html"), do: "Contact"

         def url(""), do: "app://home"
         def url("/new"), do: "app://new"
         def url("/settings"), do: "app://settings"

         def __components__, do: %{button: %{attrs: [%{name: :size, values: ~w(small medium large)}]}}

         def size_class("small"), do: "text-sm"
         def size_class("medium"), do: "text-base"
         def size_class("large"), do: "text-lg"
       end

       defmodule ApiFixture.Component do
         @behaviour Phoenix.LiveComponent

         def handle_event("save", _params, socket), do: {:noreply, socket}
         def handle_event("delete", _params, socket), do: {:noreply, socket}
         def handle_event("archive", _params, socket), do: {:noreply, socket}
       end
       """},
      {"lib/api_fixture/live.ex",
       """
       defmodule ApiFixture.Live do
         @behaviour Phoenix.LiveView

         @impl true
         def handle_event("save", _params, socket), do: {:noreply, socket}
         def handle_event("delete", _params, socket), do: {:noreply, socket}
         def handle_event("archive", _params, socket), do: {:noreply, socket}
       end
       """}
    ])

    :ok
  end

  describe "no_flag_arguments/2" do
    test "flags boolean parameters a public function branches on, and passes other parameters" do
      violations = capture(&API.no_flag_arguments/2)

      assert Enum.map(violations, &{&1.caller_function, &1.line, &1.message}) == [
               {{:render, 2}, 3,
                "takes `html`, a boolean that picks what it does: a call passing true or false doesn't say which"},
               {{:format, 2}, 7,
                "takes `rounded`, a boolean that picks what it does: a call passing true or false doesn't say which"},
               {{:total, 2}, 14,
                "takes a boolean that picks what it does: a call passing true or false doesn't say which"}
             ]

      assert hd(violations).fix ==
               "split it into one function for each thing it does, named for it, or take an atom that names the choice"
    end
  end

  describe "typed_identifiers/2" do
    test "flags public functions taking more than one identifier, and passes records and a single id" do
      violations = capture(&API.typed_identifiers/2)

      assert Enum.map(violations, &{&1.caller_function, &1.line, &1.message, &1.fix}) == [
               {{:transfer, 3}, 2,
                "takes from_account_id and to_account_id, identifiers of one type: a call that swaps them runs, " <>
                  "and reads or changes the wrong records",
                "take the records, as `%Account{} = account` does, or name the identifiers in a keyword list"}
             ]
    end
  end

  describe "no_stringly_typed_choices/2" do
    test "flags choices between three or more strings, and passes parsers, two strings and callbacks" do
      violations = capture(&API.no_stringly_typed_choices/2)

      chooses =
        ~s(chooses between "standard", "express" and "overnight": a typo compiles, and nothing lists the choices)

      assert Enum.map(violations, &{&1.caller_function, &1.line, &1.message}) == [
               {{:days, 1}, 3, chooses},
               {{:cost, 1}, 10, chooses}
             ]

      assert hd(violations).fix ==
               "turn the string into an atom where it enters the code, in one function, and match atoms everywhere else"
    end
  end

  describe "no_alternative_return_types/2" do
    test "flags an option that changes the kind of value returned, and passes ones that don't" do
      violations = capture(&API.no_alternative_return_types/2)

      assert Enum.map(violations, &{&1.caller_function, &1.line, &1.message, &1.fix}) == [
               {{:parse, 2}, 4,
                "returns a different kind of value depending on its :discard_rest option, so callers can't rely " <>
                  "on what it returns",
                "split it into one function for each kind of value it returns, named for it"}
             ]
    end
  end

  defp capture(rule) do
    subject = ModuleSet.new("ApiFixture.**")
    Assertions.capture_violations(fn -> rule.(subject, paths: [@directory]) end)
  end
end
