defmodule FixtureApp.Inventory.Item do
  @moduledoc "Inventory item — internal module."

  defstruct [:id, :name, :price, :stock]

  def find(id), do: %__MODULE__{id: id, name: "Item #{id}", price: 9.99, stock: 100}
  def all, do: [find(1), find(2)]
end
