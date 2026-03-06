defmodule FixtureApp.Repo.OrderRepo do
  @moduledoc "Order repository — bottom layer."

  def find(id), do: %{id: id}
  def all, do: []
end
