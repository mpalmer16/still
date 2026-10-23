defmodule StillWeb.NativeStorageController do
  use StillWeb, :controller

  alias Still.Storage

  plug :authorize

  def show(conn, _params), do: json(conn, Storage.status())
  def update(conn, %{"folder" => folder}), do: respond(conn, Storage.set_folder(folder))
  def update(conn, _params), do: respond(conn, {:error, "Choose an existing local folder."})
  def delete(conn, _params), do: respond(conn, Storage.clear_folder())
  def backup(conn, _params), do: respond(conn, Storage.backup())

  defp respond(conn, {:ok, status}), do: json(conn, status)

  defp respond(conn, {:error, message}),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: message})

  defp authorize(conn, _opts) do
    expected = Application.get_env(:still, :native_control_token)
    supplied = get_req_header(conn, "x-still-native-token")

    if is_binary(expected) and byte_size(expected) >= 32 and
         match?([_], supplied) and Plug.Crypto.secure_compare(expected, hd(supplied)) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Native controls are unavailable."})
      |> halt()
    end
  end
end
