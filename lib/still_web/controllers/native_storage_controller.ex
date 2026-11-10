defmodule StillWeb.NativeStorageController do
  use StillWeb, :controller

  alias Still.Storage
  alias Still.Writing.Exports

  plug :authorize

  def show(conn, _params), do: json(conn, Storage.status())
  def update(conn, %{"folder" => folder}), do: respond(conn, Storage.set_folder(folder))
  def update(conn, _params), do: respond(conn, {:error, "Choose an existing local folder."})
  def delete(conn, _params), do: respond(conn, Storage.clear_folder())
  def backup(conn, _params), do: respond(conn, Storage.backup())

  def pdf_input(conn, %{"ticket" => ticket}) when is_binary(ticket) do
    location = Storage.collection_location()

    with {:ok, %{scope: scope, id: id, source_token: token}} <-
           Phoenix.Token.verify(StillWeb.Endpoint, "writing-pdf-export", ticket, max_age: 300),
         true <- scope == location.scope,
         {:ok, piece} <- Still.Poems.get(location, id),
         {:ok, prepared} <- Exports.prepare(location, piece, :pdf),
         true <- prepared.source_token == token do
      json(conn, %{title: prepared.title, segments: prepared.segments})
    else
      {:error, message} when is_binary(message) ->
        respond(conn, {:error, message})

      _ ->
        respond(conn, {:error, "The PDF source changed or its request expired. Export it again."})
    end
  end

  def pdf_input(conn, _), do: respond(conn, {:error, "The PDF source request is incomplete."})

  def export_pdf(conn, %{"ticket" => ticket, "pdf" => encoded})
      when is_binary(ticket) and is_binary(encoded) do
    location = Storage.collection_location()

    with {:ok, %{scope: scope, id: id, source_token: token}} <-
           Phoenix.Token.verify(StillWeb.Endpoint, "writing-pdf-export", ticket, max_age: 300),
         true <- scope == location.scope,
         true <- byte_size(encoded) <= 28_000_000,
         {:ok, bytes} <- Base.decode64(encoded),
         {:ok, piece} <- Still.Poems.get(location, id),
         {:ok, path} <- Exports.publish_pdf(location, piece, bytes, token) do
      json(conn, %{path: path})
    else
      {:error, message} when is_binary(message) ->
        respond(conn, {:error, message})

      _ ->
        respond(
          conn,
          {:error, "This PDF export expired or its writing folder changed. Export it again."}
        )
    end
  end

  def export_pdf(conn, _),
    do: respond(conn, {:error, "The PDF export is incomplete. Export it again."})

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
