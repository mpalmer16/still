defmodule StillWeb.HealthControllerTest do
  use StillWeb.ConnCase

  test "health checks the database", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert response(conn, 200) == "ok"
  end

  test "a non-local host cannot reach writing", %{conn: conn} do
    conn = conn |> Map.put(:host, "outside.example") |> get(~p"/")
    assert response(conn, 403) == "Still is available only on localhost"
  end
end
