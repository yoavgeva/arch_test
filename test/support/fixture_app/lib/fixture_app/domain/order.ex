defmodule FixtureApp.Domain.Order do
  @moduledoc "Domain entity — pure business logic, no external dependencies."

  defstruct [:id, :user_id, :items, :total]

  def calculate_total(%__MODULE__{items: items}) do
    Enum.reduce(items, 0, fn item, acc -> acc + item.price end)
  end
end
