defmodule FixtureApp.Orders.OrderService do
  @moduledoc "Order service - has a layer violation (calls Repo directly)."

  # VIOLATION: Service calling Repo directly (skip context layer)
  alias FixtureApp.Repo.OrderRepo

  def get_order(id) do
    OrderRepo.find(id)
  end

  def list_orders do
    OrderRepo.all()
  end
end
