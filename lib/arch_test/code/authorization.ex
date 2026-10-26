defmodule ArchTest.Code.Authorization do
  @moduledoc false
  # What the rules about who may do what share: a web layer's endpoints, the policies that check permissions on the
  # way to them, and the calls an endpoint makes without the user asking.

  alias ArchTest.Code
  alias ArchTest.Code.Rules

  # Libraries that check permissions.
  @policies [Bodyguard, Canada.Can]
  # A controller's functions that Plug and Phoenix call, rather than a route.
  @plumbing [:init, :call, :action, :phoenix_controller_pipeline]
  # A LiveView's callbacks that every route to it reaches.
  @live [:mount, :handle_params, :handle_event]

  @type routes :: {[Code.route()], Code.t()}

  @doc false
  # The policies `opts` names, and those with the libraries that check permissions.
  @spec policies(keyword()) :: {[module()], [module()]}
  def policies(opts) do
    configured = opts |> Keyword.get(:policy, []) |> List.wrap()
    {configured, @policies ++ configured}
  end

  @doc false
  @spec policy_names([module()]) :: String.t()
  def policy_names([]), do: "a policy"
  def policy_names(policies), do: Enum.map_join(policies, " or ", &inspect/1)

  @doc false
  # A module's endpoints. Those that change things are controller actions, a LiveView's or LiveComponent's
  # `handle_event/3` and a channel's `handle_in/3`; those that read are these too, and a LiveView's `mount/3` and
  # `handle_params/3` and a channel's `join/3`, which load what a page or channel shows.
  @spec endpoints(Code.t(), module(), :changes | :reads) :: [Code.key()]
  def endpoints(code, module, which) do
    behaviours = Code.behaviours(code, module)

    controller? =
      Plug in behaviours and
        Map.has_key?(code.functions, {module, :phoenix_controller_pipeline, 2})

    for {{^module, name, arity} = key, info} <- Code.functions_of(code, module),
        not info.injected,
        endpoint?(name, arity, info.kind, behaviours, controller?) or
          (which == :reads and loads?(name, arity, behaviours)),
        do: key
  end

  defp endpoint?(:handle_event, 3, _kind, behaviours, _controller?),
    do: Phoenix.LiveView in behaviours or Phoenix.LiveComponent in behaviours

  defp endpoint?(:handle_in, 3, _kind, behaviours, _controller?),
    do: Phoenix.Channel in behaviours

  defp endpoint?(name, 2, :def, _behaviours, true), do: name not in @plumbing
  defp endpoint?(_name, _arity, _kind, _behaviours, _controller?), do: false

  defp loads?(name, 3, behaviours) when name in [:mount, :handle_params],
    do: Phoenix.LiveView in behaviours

  defp loads?(:join, 3, behaviours), do: Phoenix.Channel in behaviours
  defp loads?(_name, _arity, _behaviours), do: false

  @doc false
  # Whether a policy checks the endpoint: it, or its controller's plug pipeline, calls one, directly or through what
  # it calls, or every route to it goes through a pipeline or `live_session` hook that does.
  @spec checked?(Code.t(), routes(), Code.key(), [module()]) :: boolean()
  def checked?(code, routes, endpoint, policies),
    do:
      checks_policy?(code, endpoint, policies) or
        routed_through_policy?(routes, endpoint, policies, code)

  defp checks_policy?(code, {module, _, _} = endpoint, policies) do
    start =
      Enum.filter(
        [endpoint, {module, :phoenix_controller_pipeline, 2}],
        &Map.has_key?(code.functions, &1)
      )

    calls_module?(start, MapSet.new(start), policies, code)
  end

  defp calls_module?([], _seen, _modules, _code), do: false

  defp calls_module?([key | rest], seen, modules, code) do
    calls = code.functions[key].calls

    if Enum.any?(calls, fn %{target: {module, _, _}} -> module in modules end) do
      true
    else
      next =
        for %{target: target} <- calls,
            Map.has_key?(code.functions, target),
            not MapSet.member?(seen, target),
            uniq: true,
            do: target

      calls_module?(next ++ rest, Enum.into(next, seen), modules, code)
    end
  end

  @doc false
  # Every route to a controller action or LiveView, with the router functions of the pipelines it goes through, read
  # from the routers in scope.
  @spec routes(Code.t(), keyword()) :: routes()
  def routes(code, opts) do
    routers = Enum.filter(code.scope, &String.ends_with?(Atom.to_string(&1), "Router"))
    router_code = Code.load(routers, opts)

    routes =
      for {router, %{routes: routes}} <- router_code.modules,
          route <- routes,
          do: %{route | pipe_through: Enum.map(route.pipe_through, &{router, &1, 2})}

    {routes, router_code}
  end

  # The routes to an endpoint: to a controller action, or to any action of a LiveView, whose callbacks all run over
  # the connection a route opened.
  defp routes_to(routes, {module, name, _arity}) when name in @live,
    do: Enum.filter(routes, &(&1.controller == module))

  defp routes_to(routes, {module, name, _arity}),
    do: Enum.filter(routes, &(&1.controller == module and &1.action == name))

  @doc false
  # A controller action every route reaches with GET or HEAD: a request to read, so what it writes is the server's
  # own bookkeeping, as a cache or a view count is, rather than a change the user asks for.
  @spec reads_only?(routes(), Code.key()) :: boolean()
  def reads_only?({routes, _router_code}, {_module, name, _arity} = endpoint)
      when name not in @live do
    case routes_to(routes, endpoint) do
      [] -> false
      found -> Enum.all?(found, &(&1.verb in ["GET", "HEAD"]))
    end
  end

  def reads_only?(_routes, _endpoint), do: false

  # Whether every route to a controller action or LiveView goes through a pipeline that calls a policy, as
  # `pipe_through :require_admin` does when its plug is one, or a live_session whose `on_mount` hook is or calls one.
  defp routed_through_policy?({routes, router_code}, endpoint, policies, code) do
    case routes_to(routes, endpoint) do
      [] ->
        false

      found ->
        Enum.all?(found, &checked_route?(&1, policies, router_code, code))
    end
  end

  defp checked_route?(route, policies, router_code, code) do
    start = Enum.filter(route.pipe_through, &Map.has_key?(router_code.functions, &1))

    hooks =
      for hook <- route.on_mount,
          Map.has_key?(code.functions, {hook, :on_mount, 4}),
          do: {hook, :on_mount, 4}

    calls_module?(start, MapSet.new(start), policies, router_code) or
      Enum.any?(route.on_mount, &(&1 in policies)) or
      calls_module?(hooks, MapSet.new(hooks), policies, code)
  end

  @doc false
  # The first call `find` picks, from those an endpoint makes without the user asking: in the endpoint, the functions
  # of its module it calls, and the functions it gives the request to, which can read the user asking from it. A call
  # given the user asking is made on their behalf, along with everything it calls. One found past a function of
  # another module is reported at the endpoint's call that led there. `find` takes calls and returns the first it
  # picks, with the path from it to what it found.
  @spec unchecked(Code.t(), Code.key(), ([Code.call()] -> {Code.call(), [map()]} | nil)) ::
          {Code.call(), [map()]} | nil
  def unchecked(code, {module, _, _} = endpoint, find) do
    held? = loads_for_user?(code, module)
    unchecked([{endpoint, nil}], MapSet.new([endpoint]), {module, held?}, code, find)
  end

  defp unchecked([], _seen, _endpoint, _code, _find), do: nil

  defp unchecked([{key, origin} | rest], seen, {module, held?} = endpoint, code, find) do
    info = code.functions[key]
    on_behalf = MapSet.new(on_behalf(info, held?, code))
    requests = MapSet.new(info.actors.requests)

    {followed, outside} =
      info.calls
      |> Enum.reject(&MapSet.member?(on_behalf, {&1.target, &1.line}))
      |> Enum.split_with(fn %{target: {callee, _, _} = target} = call ->
        Map.has_key?(code.functions, target) and
          (callee == module or MapSet.member?(requests, {target, call.line}))
      end)

    case find.(outside) do
      nil ->
        next =
          for %{target: {callee, _, _} = target} = call <- followed,
              not MapSet.member?(seen, target),
              uniq: true,
              do: {target, origin || if(callee == module, do: nil, else: call)}

        unchecked(next ++ rest, Enum.into(next, seen, &elem(&1, 0)), endpoint, code, find)

      {call, path} when origin == nil ->
        {call, path}

      {_call, path} ->
        {origin, [Rules.step(origin) | path]}
    end
  end

  # The calls a function makes on behalf of the user asking: those given the user, those in a function it gives to one
  # that reads the user first, as a helper that checks the user's role and then runs the change does, and, in a
  # LiveView or LiveComponent that loads its records for the user, those given a record its assigns hold.
  defp on_behalf(info, held?, code) do
    guarded =
      for {{guard, _line}, calls} <- info.actors.callbacks,
          guards?(guard, MapSet.new(), code),
          call <- calls,
          do: call

    info.actors.on_behalf ++ guarded ++ if(held?, do: info.actors.held, else: [])
  end

  # A helper that reads the user asking before it runs the function it's given, itself or through a helper it gives
  # its own function to, as `with_domain/4` calling `with_organization/3` does.
  defp guards?(key, seen, code) do
    case code.functions[key] do
      %{actors: %{reads_user: true}} ->
        true

      %{actors: %{callbacks: callbacks}} ->
        seen = MapSet.put(seen, key)

        callbacks
        |> Enum.map(fn {{guard, _line}, _calls} -> guard end)
        |> Enum.uniq()
        |> Enum.any?(&(not MapSet.member?(seen, &1) and guards?(&1, seen, code)))

      nil ->
        false
    end
  end

  # A LiveView whose mount/3 or handle_params/3 loads records for the user asking, or a LiveComponent whose update/2
  # is given the user by its parent, along with the records the parent loaded.
  defp loads_for_user?(code, module) do
    behaviours = Code.behaviours(code, module)

    (Phoenix.LiveView in behaviours and
       Enum.any?([{module, :mount, 3}, {module, :handle_params, 3}], fn key ->
         match?(%{actors: %{on_behalf: [_ | _]}}, code.functions[key])
       end)) or
      (Phoenix.LiveComponent in behaviours and
         match?(%{actors: %{reads_user: true}}, code.functions[{module, :update, 2}]))
  end
end
