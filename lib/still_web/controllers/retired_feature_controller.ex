defmodule StillWeb.RetiredFeatureController do
  use StillWeb, :controller

  def index(conn, _params), do: redirect(conn, to: ~p"/")
end
