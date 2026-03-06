defmodule FixtureApp.Accounts do
  @moduledoc "Public API for the Accounts bounded context."

  def get_account(user_id), do: %{id: user_id, name: "User #{user_id}"}
  def list_accounts, do: []
end
