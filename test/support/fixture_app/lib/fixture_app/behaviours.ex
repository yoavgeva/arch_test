defmodule FixtureApp.Behaviours do
  @moduledoc "Behaviour fixtures for architecture tests."

  defmodule MyBehaviour do
    @moduledoc "A simple behaviour used in tests."
    @callback run(term()) :: term()
  end

  defmodule MyProtocol do
    @moduledoc "A simple protocol used in tests."
    @fallback_to_any false
    defprotocol Content do
      @spec describe(t()) :: String.t()
      def describe(value)
    end
  end

  defmodule Implementing do
    @moduledoc "A module that implements MyBehaviour."
    @behaviour FixtureApp.Behaviours.MyBehaviour

    @impl true
    def run(x), do: x
  end

  defmodule NonImplementing do
    @moduledoc "A module that does not implement MyBehaviour."
    def hello, do: :world
  end
end
