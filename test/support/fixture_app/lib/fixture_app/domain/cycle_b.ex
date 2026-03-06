defmodule FixtureApp.Domain.CycleB do
  @moduledoc "CYCLE VIOLATION: CycleB depends back on CycleA."

  alias FixtureApp.Domain.CycleA

  def from_a, do: :ok
  def call_a, do: CycleA.call_b()
end
