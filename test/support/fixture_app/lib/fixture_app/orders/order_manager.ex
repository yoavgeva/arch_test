defmodule FixtureApp.Orders.OrderManager do
  @moduledoc """
  NAMING VIOLATION: This module is named *Manager.
  The architecture rules ban Manager-suffixed modules.
  """

  def manage_order(order) do
    {:ok, order}
  end
end
