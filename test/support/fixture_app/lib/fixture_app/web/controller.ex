defmodule FixtureApp.Web.Controller do
  @moduledoc """
  Web controller — LAYER VIOLATION: calls Repo directly instead of going
  through the context layer.
  """

  # VIOLATION: Web layer calling Repo layer directly
  alias FixtureApp.Repo.OrderRepo

  def index do
    OrderRepo.all()
  end
end
