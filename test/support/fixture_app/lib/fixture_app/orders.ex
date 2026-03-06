defmodule FixtureApp.Orders do
  @moduledoc "Public API for the Orders bounded context."

  alias FixtureApp.Accounts

  def place_order(user_id, items) do
    # This is fine: Orders calling the Accounts public API
    account = Accounts.get_account(user_id)
    %{account: account, items: items}
  end
end
