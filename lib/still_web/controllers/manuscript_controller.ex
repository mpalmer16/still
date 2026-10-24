defmodule StillWeb.ManuscriptController do
  use StillWeb, :controller
  alias Still.{Manuscript, Storage}

  def show(conn, %{"id" => id, "format" => format}) do
    case Manuscript.export(Storage.collection_location(), id, format) do
      {:ok, export} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_download({:binary, export.body}, filename: export.filename)

      {:error, message} ->
        conn |> put_status(:unprocessable_entity) |> text(message)
    end
  end
end
