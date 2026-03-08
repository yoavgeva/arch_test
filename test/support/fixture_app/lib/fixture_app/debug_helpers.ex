defmodule FixtureApp.DebugHelpers do
  @moduledoc """
  CONVENTION VIOLATIONS: This module contains IO.puts, dbg, and bare raise string.
  Used to verify that convention checks catch these patterns.
  """

  def process(item) do
    IO.puts("processing item")
    item
  end

  def inspect_item(item) do
    # credo:disable-for-next-line Credo.Check.Warning.Dbg
    dbg(item)
    item
  end

  def validate!(item) do
    if is_nil(item), do: raise("item must not be nil")
    item
  end
end
