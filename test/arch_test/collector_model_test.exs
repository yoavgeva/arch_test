defmodule ArchTest.CollectorModelTest do
  use ExUnit.Case, async: false

  alias ArchTest.Collector

  @ebin Path.expand("../support/fixture_app/_build/dev/lib/fixture_app/ebin", __DIR__)

  test "build_graph accepts include and exclude module filters" do
    graph =
      Collector.build_graph(:arch_test,
        include: ["ArchTest.**"],
        exclude: ["ArchTest.Pattern"],
        force: true
      )

    assert ArchTest.Collector in Map.keys(graph)
    refute ArchTest.Pattern in Map.keys(graph)
  end

  test "build_graph filters dependency edges to the kept module set" do
    graph =
      Collector.build_graph(:arch_test,
        include: ["ArchTest.Assertions"],
        exclude: ["ArchTest.Collector"],
        force: true
      )

    assert Map.keys(graph) == [ArchTest.Assertions]
    refute ArchTest.Collector in Collector.dependencies_of(graph, ArchTest.Assertions)
  end

  test "build_graph_from_paths accepts multiple paths" do
    graph = Collector.build_graph_from_paths([@ebin], force: true)
    assert FixtureApp.Orders.Checkout in Map.keys(graph)
  end

  test "calls_from_path returns function-level call metadata with line numbers" do
    calls = Collector.calls_from_path(@ebin, force: true)

    call =
      Enum.find(calls, fn call ->
        call.caller_module == FixtureApp.Orders.Checkout and
          call.callee_module == FixtureApp.Inventory.Repo
      end)

    assert %ArchTest.Call{} = call
    assert is_atom(call.caller_function)
    assert is_integer(call.line)
    assert call.line > 0
    assert is_binary(call.file)
  end

  test "calls_from_path filters excluded callees and generated compiler calls" do
    calls =
      Collector.calls_from_path(@ebin,
        exclude: ["FixtureApp.Inventory.**"],
        force: true
      )

    refute Enum.any?(
             calls,
             &String.starts_with?(inspect(&1.callee_module), "FixtureApp.Inventory")
           )

    refute Enum.any?(calls, &(&1.caller_function == :__info__))
    refute Enum.any?(calls, &(&1.line in [nil, 0]))

    refute Enum.any?(
             calls,
             &(&1.callee_module == :erlang and &1.callee_function == :get_module_info)
           )
  end

  @tag :tmp_dir
  test "calls_from_path captures remote captures and static apply targets", %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])
    app_mod = "AuditCall#{suffix}"
    source_path = Path.join(tmp_dir, "audit_call.ex")
    ebin_path = Path.join(tmp_dir, "ebin")
    File.mkdir_p!(ebin_path)

    File.write!(source_path, """
    defmodule #{app_mod}.Target do
      def f(value), do: value
    end

    defmodule #{app_mod}.Caller do
      def captured(values), do: Enum.map(values, &#{app_mod}.Target.f/1)
      def applied(value), do: apply(#{app_mod}.Target, :f, [value])
    end
    """)

    previous_options = Code.compiler_options()
    Code.compiler_options(debug_info: true)

    try do
      assert {:ok, _modules, %{compile_warnings: [], runtime_warnings: []}} =
               Kernel.ParallelCompiler.compile_to_path([source_path], ebin_path,
                 return_diagnostics: true
               )
    after
      Code.compiler_options(previous_options)
    end

    target = Module.concat([String.to_atom(app_mod), Target])
    caller = Module.concat([String.to_atom(app_mod), Caller])
    calls = Collector.calls_from_path(ebin_path, force: true)

    assert Enum.any?(calls, fn call ->
             call.caller_module == caller and
               call.caller_function == :captured and
               call.callee_module == target and
               call.callee_function == :f and
               call.callee_arity == 1 and
               call.kind == :remote_capture
           end)

    assert Enum.any?(calls, fn call ->
             call.caller_module == caller and
               call.caller_function == :applied and
               call.callee_module == target and
               call.callee_function == :f and
               call.callee_arity == 1 and
               call.kind == :static_apply
           end)

    refute Enum.any?(calls, fn call ->
             call.caller_module == caller and
               call.caller_function == :applied and
               call.callee_module == :erlang and
               call.callee_function == :apply
           end)
  end

  test "calls_from_path filters generated protocol dispatch calls" do
    calls = Collector.calls_from_path(@ebin, force: true)

    protocol_impl_calls =
      Enum.filter(calls, &(&1.caller_module == FixtureApp.Behaviours.MyProtocol.Content))

    refute Enum.any?(protocol_impl_calls, &(&1.caller_function in [:impl_for, :impl_for!]))

    refute Enum.any?(protocol_impl_calls, fn call ->
             call.callee_module == :erlang and
               call.callee_function |> Atom.to_string() |> String.starts_with?("is_")
           end)
  end
end
