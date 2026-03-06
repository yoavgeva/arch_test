defmodule FixtureApp.Domain.CycleA do
  @moduledoc "CYCLE VIOLATION: CycleA depends on CycleB which depends back on CycleA."

  alias FixtureApp.Domain.CycleB

  def call_b, do: CycleB.from_a()
end
