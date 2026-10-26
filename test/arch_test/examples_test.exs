defmodule ArchTest.ExamplesTest do
  # The design rule examples guide shows every design rule with code it flags and the code fixed. This compiles both
  # and runs the rule on them, so the guide can't show what a rule doesn't do.
  use ExUnit.Case, async: false

  alias ArchTest.{Assertions, CompiledFixture, ModuleSet}

  @guide Path.expand("../../guides/design-rule-examples.md", __DIR__)
  @root Path.join(System.tmp_dir!(), "arch_test_examples")

  @rules [
    {ArchTest.Effects, :no_queries_in_loops},
    {ArchTest.Effects, :should_be_free_of_side_effects},
    {ArchTest.Effects, :no_work_in_init},
    {ArchTest.Effects, :no_io_in_transactions},
    {ArchTest.Processes, :processes_have_one_interface},
    {ArchTest.Processes, :processes_hold_state},
    {ArchTest.Processes, :processes_are_supervised},
    {ArchTest.TestCode, :tests_use_their_subject},
    {ArchTest.TestCode, :tests_dont_mock_pure_modules},
    {ArchTest.TestCode, :tests_dont_sleep},
    {ArchTest.TestCode, :async_tests_share_no_state},
    {ArchTest.Guardrails, :no_suppressions},
    {ArchTest.Guardrails, :no_stubs},
    {ArchTest.Guardrails, :no_functions_only_tests_call},
    {ArchTest.Guardrails, :no_swallowed_errors}
  ]

  # `Shop.Repo`, an Ecto repo as `use Ecto.Repo` writes one, from a dependency's source.
  @repo {"deps/ecto/lib/shop/repo.ex",
         """
         defmodule Shop.Repo do
           @compile {:no_warn_undefined, [Ecto.Repo.Queryable, Ecto.Repo.Schema, Ecto.Repo.Transaction]}

           def all(queryable, opts \\\\ []), do: Ecto.Repo.Queryable.all(__MODULE__, queryable, opts)
           def get!(queryable, id, opts \\\\ []), do: Ecto.Repo.Queryable.get!(__MODULE__, queryable, id, opts)
           def insert(struct, opts \\\\ []), do: Ecto.Repo.Schema.insert(__MODULE__, struct, opts)
           def insert!(struct, opts \\\\ []), do: Ecto.Repo.Schema.insert!(__MODULE__, struct, opts)
           def transaction(fun, opts \\\\ []), do: Ecto.Repo.Transaction.transaction(__MODULE__, fun, opts)
         end
         """}

  # `Shop.Mailer`, a Swoosh mailer as `use Swoosh.Mailer` writes one.
  @mailer {"deps/swoosh/lib/shop/mailer.ex",
           """
           defmodule Shop.Mailer do
             @compile {:no_warn_undefined, [Swoosh.Mailer]}

             def deliver(email, config \\\\ []), do: Swoosh.Mailer.deliver(email, config)
           end
           """}

  setup_all do
    %{examples: @guide |> File.read!() |> examples()}
  end

  test "shows every design rule", %{examples: examples} do
    assert examples |> Map.keys() |> Enum.sort() ==
             @rules |> Enum.map(&elem(&1, 1)) |> Enum.sort()
  end

  for {module, rule} <- @rules do
    @module module
    @rule rule

    test "#{rule} flags its example, and passes the fixed code", %{examples: examples} do
      example = Map.fetch!(examples, @rule)
      flagged = check(@module, @rule, example.subject, example.flagged)

      assert flagged != []
      assert Enum.all?(flagged, &(&1.rule == Atom.to_string(@rule)))

      assert check(@module, @rule, example.subject, Map.merge(example.flagged, example.fixed)) ==
               []
    end
  end

  # Each rule's section: its subject, from the call it shows, and its code blocks by the file they'd live in, those
  # under "Fixed" apart.
  defp examples(guide) do
    ~r/^### `(\w+)`\n(.*?)(?=^##|\z)/ms
    |> Regex.scan(guide, capture: :all_but_first)
    |> Map.new(fn [rule, section] ->
      [flagged, fixed] = String.split(section, "<details>", parts: 2)
      [_, subject] = Regex.run(~r/modules_matching\("([^"]+)"\)/, section)
      {String.to_atom(rule), %{subject: subject, flagged: files(flagged), fixed: files(fixed)}}
    end)
  end

  defp modules(source),
    do: for([_, module] <- Regex.scan(~r/^\s*defmodule ([\w.]+)/m, source), do: module)

  defp files(text) do
    ~r/^```elixir\n(.*?)^```$/ms
    |> Regex.scan(text, capture: :all_but_first)
    |> Map.new(fn [source] -> {path(source), source} end)
  end

  defp path(source) do
    case Regex.run(~r/defmodule ([\w.]+)/, source) do
      [_, module] ->
        if source =~ "use ExUnit.Case",
          do: "test/#{Macro.underscore(module)}.exs",
          else: "lib/#{Macro.underscore(module)}.ex"

      nil ->
        "test/test_helper.exs"
    end
  end

  defp check(module, rule, pattern, files) do
    directory = Path.join(@root, Atom.to_string(rule))
    File.rm_rf!(directory)
    defined = files |> Map.values() |> Enum.flat_map(&modules/1)

    stubs =
      for {_path, source} = stub <- [@repo, @mailer],
          modules(source) -- defined != [],
          into: %{},
          do: stub

    files = Map.merge(stubs, files)

    for {path, source} <- files do
      File.mkdir_p!(Path.join(directory, Path.dirname(path)))
      File.write!(Path.join(directory, path), source)
    end

    ebin = Path.join(directory, "ebin")
    sources = for {path, _source} <- files, not String.starts_with?(path, "test/"), do: path
    opts = [paths: [ebin], test_paths: ["test"]]

    File.cd!(directory, fn ->
      CompiledFixture.compile_files(ebin, sources)

      Assertions.capture_violations(fn ->
        Function.capture(module, rule, 2).(ModuleSet.new(pattern), opts)
      end)
    end)
  end
end
