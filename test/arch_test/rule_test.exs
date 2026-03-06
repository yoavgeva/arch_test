defmodule ArchTest.RuleTest do
  use ExUnit.Case, async: true

  alias ArchTest.{Rule, Violation}

  @sample_graph %{A => [B], B => [C], C => []}

  describe "evaluate/2" do
    test "returns {:ok, []} when check_fn returns empty list" do
      rule = %Rule{
        description: "no violations",
        check_fn: fn _graph -> [] end
      }

      assert Rule.evaluate(rule, @sample_graph) == {:ok, []}
    end

    test "returns {:violations, list} when violations found" do
      v = Violation.forbidden_dep(A, B, "test violation")

      rule = %Rule{
        description: "always violations",
        check_fn: fn _graph -> [v] end
      }

      assert {:violations, [^v]} = Rule.evaluate(rule, @sample_graph)
    end

    test "check_fn receives the graph" do
      rule = %Rule{
        description: "inspects graph",
        check_fn: fn graph ->
          if Map.has_key?(graph, A), do: [], else: [Violation.forbidden_dep(A, B, "missing")]
        end
      }

      assert Rule.evaluate(rule, @sample_graph) == {:ok, []}
      assert {:violations, _} = Rule.evaluate(rule, %{})
    end

    test "returns multiple violations" do
      v1 = Violation.forbidden_dep(A, B, "v1")
      v2 = Violation.forbidden_dep(B, C, "v2")

      rule = %Rule{
        description: "multiple",
        check_fn: fn _graph -> [v1, v2] end
      }

      assert {:violations, violations} = Rule.evaluate(rule, @sample_graph)
      assert length(violations) == 2
    end
  end

  describe "struct" do
    test "requires description and check_fn keys" do
      # @enforce_keys means building without those keys raises at compile time.
      # We verify this by attempting it dynamically via struct/2.
      assert_raise ArgumentError, fn ->
        struct!(Rule, %{})
      end
    end

    test "description is accessible" do
      rule = %Rule{description: "my rule", check_fn: fn _ -> [] end}
      assert rule.description == "my rule"
    end
  end
end
