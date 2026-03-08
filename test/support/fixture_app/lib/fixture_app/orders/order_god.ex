defmodule FixtureApp.Orders.OrderGod do
  @moduledoc """
  NAMING VIOLATION: This module is named *God.
  The architecture rules ban God-suffixed modules.
  """

  def do_everything(order) do
    {:ok, order}
  end
end
