defmodule StillWeb.NativeStorageController do
  use StillWeb, :controller

  alias Still.Storage
  alias Still.Correspondence.PacketExports
  alias Still.Writing.Exports

  plug :authorize

  def show(conn, _params), do: json(conn, Storage.status())
  def update(conn, %{"folder" => folder}), do: respond(conn, Storage.set_folder(folder))
  def update(conn, _params), do: respond(conn, {:error, "Choose an existing local folder."})
  def delete(conn, _params), do: respond(conn, Storage.clear_folder())
  def backup(conn, _params), do: respond(conn, Storage.backup())

  def pdf_input(conn, %{"ticket" => ticket}) when is_binary(ticket) do
    location = Storage.collection_location()

    with {:ok, claims} <- verify_pdf_ticket(ticket),
         true <- claims.scope == location.scope,
         {:ok, prepared} <- prepare_pdf_input(location, claims),
         true <- prepared.source_token == claims.source_token do
      json(conn, %{title: prepared.title, segments: native_segments(prepared.segments)})
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

    with {:ok, claims} <- verify_pdf_ticket(ticket),
         true <- claims.scope == location.scope,
         true <- byte_size(encoded) <= 28_000_000,
         {:ok, bytes} <- Base.decode64(encoded),
         {:ok, path} <- publish_pdf(location, claims, bytes) do
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

  defp verify_pdf_ticket(ticket) do
    with {:ok, claims} <-
           Phoenix.Token.verify(StillWeb.Endpoint, "writing-pdf-export", ticket, max_age: 300),
         true <-
           is_map(claims) and is_binary(claims[:scope]) and is_binary(claims[:id]) and
             is_binary(claims[:source_token]),
         true <- is_nil(claims[:kind]) or claims[:kind] == "packet",
         true <- claims[:kind] != "packet" or is_nonempty_binary(claims[:request_id]) do
      {:ok, claims}
    else
      _ -> {:error, "The PDF source changed or its request expired. Export it again."}
    end
  end

  defp is_nonempty_binary(value), do: is_binary(value) and value != ""

  defp prepare_pdf_input(location, %{kind: "packet", id: id}),
    do: PacketExports.prepare(location, id)

  # Tickets issued before packet export was added have no kind and remain writing exports.
  defp prepare_pdf_input(location, %{id: id}) do
    with {:ok, piece} <- Still.Poems.get(location, id),
         do: Exports.prepare(location, piece, :pdf)
  end

  defp publish_pdf(location, %{kind: "packet", id: id, source_token: token}, bytes),
    do: PacketExports.publish_pdf(location, id, bytes, token)

  defp publish_pdf(location, %{id: id, source_token: token}, bytes) do
    with {:ok, piece} <- Still.Poems.get(location, id),
         do: Exports.publish_pdf(location, piece, bytes, token)
  end

  defp native_segments(segments) do
    Enum.map(segments, fn segment ->
      segment
      |> Map.put_new(:page_break_before, false)
    end)
  end

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
