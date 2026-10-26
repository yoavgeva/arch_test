defmodule ArchTest.Code.Waits do
  @moduledoc false
  # The waits in a function that have no limit:
  #
  # - a call given `:infinity` as its timeout, as `GenServer.call(server, request, :infinity)` is, or as a keyword
  #   option named for a timeout, as `Task.async_stream(items, fun, timeout: :infinity)` is;
  # - a call that waits with no limit unless given one, as `:gen_tcp.recv/2` and `:httpc.request/1` do;
  # - a `receive` with no `after`, or an `after :infinity`, other than a process's own loop, whose clauses call the
  #   function again to wait for the next message.

  alias ArchTest.Code

  # Calls that take a timeout, and its position, from 0.
  @timeouts %{
    {GenServer, :call, 3} => 2,
    {:gen_server, :call, 3} => 2,
    {:gen_statem, :call, 3} => 2,
    {Task, :await, 2} => 1,
    {Task, :yield, 2} => 1,
    {Task, :await_many, 2} => 1,
    {Task, :yield_many, 2} => 1,
    {Agent, :get, 3} => 2,
    {Agent, :update, 3} => 2,
    {Agent, :get_and_update, 3} => 2,
    {:gen_tcp, :recv, 3} => 2,
    {:gen_tcp, :connect, 4} => 3,
    {:gen_udp, :recv, 3} => 2,
    {:ssl, :recv, 3} => 2,
    {:ssl, :connect, 4} => 3,
    {:erpc, :call, 5} => 4,
    {:rpc, :call, 5} => 4
  }
  # Calls that wait with no limit unless given one.
  @unbounded MapSet.new([
               {:gen_tcp, :connect, 3},
               {:gen_tcp, :recv, 2},
               {:gen_udp, :recv, 2},
               {:ssl, :connect, 2},
               {:ssl, :recv, 2},
               {:ssl, :handshake, 1},
               {:httpc, :request, 1},
               {:httpc, :request, 2}
             ])

  @type wait :: %{
          required(:line) => pos_integer() | nil,
          required(:target) => Code.key() | nil,
          required(:how) => :infinity | :option | :default | :receive,
          optional(:option) => atom(),
          optional(:next) => [Code.key()]
        }

  @doc false
  @spec unbounded([tuple()], module(), atom(), arity(), MapSet.t()) :: [wait()]
  def unbounded(clauses, module, name, arity, locals) do
    bodies = Enum.map(clauses, fn {_meta, _args, _guards, body} -> body end)
    flushes? = cancels_timer?(bodies)

    bodies
    |> Macro.prewalk([], fn node, acc ->
      {node, waits(node, module, {name, arity}, locals) ++ acc}
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.reject(&(&1.how == :receive and flushes?))
  end

  # A receive after a timer is cancelled flushes its message, which is already on its way when cancelling fails.
  defp cancels_timer?(bodies) do
    bodies
    |> Macro.prewalk(false, fn
      {{:., _, [:erlang, :cancel_timer]}, _, _} = node, _found -> {node, true}
      node, found -> {node, found}
    end)
    |> elem(1)
  end

  defp waits({:receive, meta, [options]}, module, _self, locals) when is_list(options) do
    forever? =
      not Keyword.has_key?(options, :after) or
        match?([{:->, _, [[:infinity], _]}], options[:after])

    if forever? and not watches?(options[:do]),
      do: [Map.put(wait(meta, nil, :receive), :next, next(options[:do], module, locals))],
      else: []
  end

  defp waits({{:., meta, [callee, name]}, _, args}, _module, _self, _locals)
       when is_atom(callee) and is_atom(name) and is_list(args) do
    target = {callee, name, length(args)}
    call_waits(target, args, meta)
  end

  defp waits({name, meta, args}, module, _self, locals) when is_atom(name) and is_list(args) do
    if MapSet.member?(locals, {name, length(args)}),
      do: call_waits({module, name, length(args)}, args, meta),
      else: []
  end

  defp waits(_node, _module, _self, _locals), do: []

  defp call_waits(target, args, meta) do
    cond do
      Enum.at(args, Map.get(@timeouts, target, -1)) == :infinity and
          Map.has_key?(@timeouts, target) ->
        [wait(meta, target, :infinity)]

      option = Enum.find_value(args, &infinite_option/1) ->
        [Map.put(wait(meta, target, :option), :option, option)]

      MapSet.member?(@unbounded, target) or httpc_without_timeout?(target, args) ->
        [wait(meta, target, :default)]

      true ->
        []
    end
  end

  defp wait(meta, target, how), do: %{line: meta[:line], target: target, how: how}

  # The option naming a timeout given `:infinity`: `timeout: :infinity`, `receive_timeout: :infinity` and the like.
  defp infinite_option(options) when is_list(options) do
    Enum.find_value(options, fn
      {key, :infinity} when is_atom(key) ->
        if String.ends_with?(Atom.to_string(key), "timeout"), do: key

      _other ->
        nil
    end)
  end

  defp infinite_option(_arg), do: nil

  # `:httpc.request(method, request, http_options, options)` waits with no limit when the HTTP options it's given
  # leave out `timeout`.
  defp httpc_without_timeout?({:httpc, :request, 4}, [_method, _request, http_options, _options])
       when is_list(http_options),
       do: not Keyword.has_key?(http_options, :timeout)

  defp httpc_without_timeout?(_target, _args), do: false

  # Whether a receive's clauses call its function again: a process's loop, waiting for its next message.
  # Whether a receive also takes the `:DOWN` of a process it monitors, so it stops waiting when that process dies, as
  # `GenServer.call/2` does.
  defp watches?(clauses) when is_list(clauses),
    do:
      Enum.any?(
        clauses,
        &match?({:->, _, [[{:{}, _, [tag | _]}], _]} when tag in [:DOWN, :EXIT], &1)
      )

  defp watches?(_clauses), do: false

  # The module's functions a receive's clauses call, which may lead back to it: a process's loop, waiting for its
  # next message.
  defp next(clauses, module, locals) do
    clauses
    |> Macro.prewalk([], fn
      {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
        if MapSet.member?(locals, {name, length(args)}),
          do: {node, [{module, name, length(args)} | acc]},
          else: {node, acc}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.uniq()
  end
end
