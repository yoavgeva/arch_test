defmodule FixtureApp.Orders.Checkout do
  @moduledoc "Checkout logic - intentionally violates isolation (calls Inventory internals)."

  # VIOLATION: Orders internal calling Inventory internal (not public API)
  alias FixtureApp.Inventory.Repo, as: InventoryRepo

  def calculate_total(items) do
    # Violation: directly accessing Inventory.Repo (internal module)
    stock = InventoryRepo.get_stock(items)
    Enum.sum(Enum.map(stock, & &1.price))
  end
end
