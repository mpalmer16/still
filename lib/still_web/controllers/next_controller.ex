defmodule StillWeb.NextController do
  use StillWeb, :controller

  def redirect_old_path(conn, params) do
    params =
      params
      |> Map.take(~w(edit from ref on new q view))
      |> Map.filter(fn {_, v} -> is_binary(v) end)

    path =
      if params == %{}, do: ~p"/correspondence/next", else: ~p"/correspondence/next?#{params}"

    redirect(conn, to: path)
  end
end
