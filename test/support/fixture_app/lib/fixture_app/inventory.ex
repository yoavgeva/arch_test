defmodule FixtureApp.Inventory do
  @moduledoc "Public API for the Inventory bounded context."

  alias FixtureApp.Inventory.Item

  def get_item(id), do: Item.find(id)
  def list_items, do: Item.all()
end
