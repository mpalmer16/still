defmodule StillWeb.HealthController do
  use StillWeb, :controller

  alias Still.Repo

  def index(conn, _params) do
    case Repo.query("SELECT 1") do
      {:ok, _} -> text(conn, "ok")
      {:error, _} -> conn |> put_status(:service_unavailable) |> text("unavailable")
    end
  end
end
