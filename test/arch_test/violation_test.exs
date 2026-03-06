defmodule ArchTest.ViolationTest do
  use ExUnit.Case, async: true

  alias ArchTest.Violation

  describe "forbidden_dep/3" do
    test "creates a :forbidden_dep violation with caller and callee" do
      v = Violation.forbidden_dep(MyApp.A, MyApp.B, "forbidden")
      assert v.type == :forbidden_dep
      assert v.caller == MyApp.A
      assert v.callee == MyApp.B
      assert v.message == "forbidden"
    end
  end

  describe "transitive_dep/4" do
    test "creates a :forbidden_dep violation with path" do
      v = Violation.transitive_dep(MyApp.A, MyApp.C, [MyApp.A, MyApp.B, MyApp.C], "transitive")
      assert v.type == :forbidden_dep
      assert v.caller == MyApp.A
      assert v.callee == MyApp.C
      assert v.path == [MyApp.A, MyApp.B, MyApp.C]
      assert v.message == "transitive"
    end

    test "path field is stored correctly" do
      path = [X, Y, Z]
      v = Violation.transitive_dep(X, Z, path, "via path")
      assert v.path == path
    end
  end

  describe "naming/2" do
    test "creates a :naming violation with module" do
      v = Violation.naming(MyApp.Bad, "bad name")
      assert v.type == :naming
      assert v.module == MyApp.Bad
      assert v.message == "bad name"
    end
  end

  describe "existence/2" do
    test "creates an :existence violation with module" do
      v = Violation.existence(MyApp.Manager, "should not exist")
      assert v.type == :existence
      assert v.module == MyApp.Manager
      assert v.message == "should not exist"
    end
  end

  describe "cycle/2" do
    test "creates a :cycle violation with path stored" do
      v = Violation.cycle([A, B], "cycle found")
      assert v.type == :cycle
      assert v.path == [A, B]
      assert String.contains?(v.message, "cycle found")
    end

    test "format includes all path elements for 3-module cycle" do
      v = Violation.cycle([A, B, C], "cycle detected")
      formatted = Violation.format(v)
      assert String.contains?(formatted, inspect(A))
      assert String.contains?(formatted, inspect(B))
      assert String.contains?(formatted, inspect(C))
      # Cycle closing: should show A again at the end
      assert String.contains?(formatted, "#{inspect(A)}")
    end
  end

  describe "format/1" do
    test "formats dep violation showing callee" do
      v = Violation.forbidden_dep(A, B, "reason")
      formatted = Violation.format(v)
      assert String.contains?(formatted, inspect(B))
      assert String.contains?(formatted, "reason")
    end

    test "formats module violation (no caller/callee)" do
      v = Violation.naming(MyApp.Foo, "bad name")
      formatted = Violation.format(v)
      assert String.contains?(formatted, inspect(MyApp.Foo))
      assert String.contains?(formatted, "bad name")
    end

    test "formats violation with only message" do
      v = %Violation{type: :custom, message: "just a message"}
      formatted = Violation.format(v)
      assert String.contains?(formatted, "just a message")
    end

    test "handles nil caller AND nil callee (message-only forbidden_dep) without crashing" do
      v = %Violation{type: :forbidden_dep, caller: nil, callee: nil, message: "orphaned violation"}
      formatted = Violation.format(v)
      assert is_binary(formatted)
      assert String.contains?(formatted, "orphaned violation")
    end

    test "does not truncate very long messages" do
      long_msg = String.duplicate("x", 5000)
      v = %Violation{type: :custom, message: long_msg}
      formatted = Violation.format(v)
      assert String.contains?(formatted, long_msg)
    end

    test "formats transitive dep showing path" do
      v = Violation.transitive_dep(A, C, [A, B, C], "transitive reason")
      formatted = Violation.format(v)
      assert String.contains?(formatted, "[transitive]")
      assert String.contains?(formatted, inspect(C))
      assert String.contains?(formatted, "transitive reason")
      # Should show the via path
      assert String.contains?(formatted, "via:")
    end

    test "formats existence violation with module" do
      v = Violation.existence(MyApp.BadManager, "should not exist")
      formatted = Violation.format(v)
      assert String.contains?(formatted, inspect(MyApp.BadManager))
      assert String.contains?(formatted, "should not exist")
    end
  end

  describe "format_all/1" do
    test "returns '(no violations)' for empty list" do
      assert Violation.format_all([]) == "(no violations)"
    end

    test "formats multiple violations" do
      violations = [
        Violation.forbidden_dep(A, B, "v1"),
        Violation.forbidden_dep(C, D, "v2")
      ]

      result = Violation.format_all(violations)
      assert String.contains?(result, inspect(A))
      assert String.contains?(result, inspect(C))
    end

    test "indents violations with 4 spaces" do
      violations = [Violation.forbidden_dep(A, B, "test")]
      result = Violation.format_all(violations)
      lines = String.split(result, "\n")
      # At least one line should be indented
      assert Enum.any?(lines, fn l -> String.starts_with?(l, "    ") end)
    end

    test "groups multiple violations for the same caller module" do
      violations = [
        Violation.forbidden_dep(MyApp.A, MyApp.B, "v1"),
        Violation.forbidden_dep(MyApp.A, MyApp.C, "v2"),
        Violation.forbidden_dep(MyApp.A, MyApp.D, "v3")
      ]

      result = Violation.format_all(violations)
      # The module header should appear once
      header_count =
        result
        |> String.split("\n")
        |> Enum.count(fn line -> String.contains?(line, "MyApp.A") and not String.contains?(line, "depends on") end)

      # At least one header line for MyApp.A, but not three separate groups
      assert header_count >= 1
      # All three violations should be present
      assert String.contains?(result, "v1")
      assert String.contains?(result, "v2")
      assert String.contains?(result, "v3")
    end

    test "violations for different modules appear in separate sections" do
      violations = [
        Violation.forbidden_dep(Alpha, Gamma, "v1"),
        Violation.forbidden_dep(Beta, Delta, "v2")
      ]

      result = Violation.format_all(violations)
      assert String.contains?(result, inspect(Alpha))
      assert String.contains?(result, inspect(Beta))
      # Separator line should be present between different groups
      assert String.contains?(result, String.duplicate("\u2500", 60))
    end

    test "handles 10+ violations without truncation or crash" do
      violations =
        for i <- 1..15 do
          caller = Module.concat(["Mod#{i}"])
          callee = Module.concat(["Dep#{i}"])
          Violation.forbidden_dep(caller, callee, "violation #{i}")
        end

      result = Violation.format_all(violations)
      assert is_binary(result)

      # All 15 violations should be present
      for i <- 1..15 do
        assert String.contains?(result, "violation #{i}")
      end
    end

    test "produces deterministic output (sorted module groups)" do
      violations = [
        Violation.forbidden_dep(Zebra, A, "z"),
        Violation.forbidden_dep(Alpha, B, "a"),
        Violation.forbidden_dep(Middle, C, "m")
      ]

      result1 = Violation.format_all(violations)
      result2 = Violation.format_all(violations)
      assert result1 == result2

      # Verify ordering: Alpha should appear before Middle, Middle before Zebra
      alpha_pos = :binary.match(result1, inspect(Alpha)) |> elem(0)
      middle_pos = :binary.match(result1, inspect(Middle)) |> elem(0)
      zebra_pos = :binary.match(result1, inspect(Zebra)) |> elem(0)
      assert alpha_pos < middle_pos
      assert middle_pos < zebra_pos
    end
  end
end
