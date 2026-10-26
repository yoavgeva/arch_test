defmodule ArchTest.TestCodeScaleTest do
  # The test rules on a project the size of a real one: hundreds of functions and mocks. Each runs in seconds, as on
  # OpenFn Lightning, where tests_dont_mock_pure_modules once took six minutes.
  use ExUnit.Case, async: false

  alias ArchTest.{Assertions, CompiledFixture, ModuleSet, TestCode}

  @root Path.join(System.tmp_dir!(), "arch_test_test_code_scale")
  @ebin Path.join(@root, "ebin")
  @links 1000
  @mocks 400

  setup_all do
    # A chain of functions whose last calls a library outside Elixir's and Erlang's, so every one is opaque.
    chain =
      for link <- 0..(@links - 1), into: "" do
        next = if link == @links - 1, do: "ScaleSdk.call(x)", else: "link#{link + 1}(x)"
        "  def link#{link}(x), do: #{next}\n"
      end

    CompiledFixture.compile(@ebin, [
      {"lib/scale_fixture/chain.ex",
       """
       defmodule ScaleFixture.Chain do
         @compile {:no_warn_undefined, [ScaleSdk]}
       #{chain}end
       """}
    ])

    stubs =
      for mock <- 1..@mocks,
          into: "",
          do: "    Mimic.stub(ScaleFixture.Chain, :link#{rem(mock, @links)}, fn x -> x end)\n"

    file = Path.join(@root, "test/scale_fixture/chain_test.exs")
    File.mkdir_p!(Path.dirname(file))

    File.write!(file, """
    defmodule ScaleFixture.ChainTest do
      use ExUnit.Case

      test "stubs every link" do
    #{stubs}    assert ScaleFixture.Chain.link0(1) == 1
      end
    end
    """)

    :ok
  end

  test "tests_dont_mock_pure_modules finds what each mock reaches once, not once per mock" do
    {microseconds, violations} =
      :timer.tc(fn -> capture(&TestCode.tests_dont_mock_pure_modules/2) end)

    assert violations == []
    assert microseconds < 5_000_000, "took #{div(microseconds, 1000)} ms"
  end

  defp capture(rule) do
    File.cd!(@root, fn ->
      Assertions.capture_violations(fn ->
        rule.(ModuleSet.new("ScaleFixture.**"), paths: [@ebin], test_paths: ["test"])
      end)
    end)
  end
end
