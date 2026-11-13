defmodule Still.Correspondence.ReaderPackets do
  @moduledoc "Adds the current reading to a packet without changing the reading place."

  alias Still.{Correspondence, Poems, Repo, Storage}
  alias Still.Writing.Entry

  def supported?(%{file_id: id, file_token: token}) when is_binary(id) and is_binary(token),
    do: true

  def supported?(%{id: id, token: token}) when is_binary(id) and is_binary(token), do: true

  def supported?(%{file_id: nil, origin: "before", source_key: key})
      when is_binary(key) and key != "",
      do: true

  def supported?(_), do: false

  def historical?(%{file_id: nil, origin: "before"}), do: true
  def historical?(_), do: false

  def create(location, source, title) do
    with :ok <- current_collection(location),
         {:ok, piece} <- reading_piece(location, source) do
      Correspondence.start_packet(location, piece.id, piece.token, title)
    end
  end

  def add(location, source, packet_id, packet_token) do
    with :ok <- current_collection(location),
         {:ok, packet} <- Correspondence.packet(location, packet_id),
         :ok <- fresh_draft(packet, packet_token),
         {:ok, piece} <- reading_piece(location, source) do
      Correspondence.add_to_packet(location, piece.id, packet_id, packet_token, piece.token)
    end
  end

  defp current_collection(%{scope: scope, available: true}) do
    current = Storage.collection_location()

    if current.available && current.scope == scope,
      do: :ok,
      else:
        {:error, "The writing folder changed or is unavailable. Reopen this piece to continue."}
  end

  defp current_collection(_),
    do: {:error, "The writing folder is unavailable. Reconnect it before adding writing."}

  defp fresh_draft(%{status: "preparing", snapshot_ref: nil, token: token}, token)
       when is_binary(token),
       do: :ok

  defp fresh_draft(%{status: "preparing"}, _),
    do: {:error, "This draft changed. Refresh drafts and choose it again."}

  defp fresh_draft(_, _), do: {:error, "Only a draft packet can receive writing."}

  defp reading_piece(
         location,
         %Entry{file_id: id, file_token: token, collection_scope: scope} = source
       )
       when is_binary(id) and is_binary(token) do
    if scope == location.scope do
      with {:ok, piece} <- Poems.get(location, id) do
        current = Repo.get(Entry, source.id)

        if current && current.file_id == id && current.file_token == token &&
             current.lock_version == source.lock_version,
           do: {:ok, piece},
           else: {:error, "This piece changed since you opened it. Reopen it before adding it."}
      end
    else
      {:error, "This piece belongs to a different writing folder. Reopen it to continue."}
    end
  end

  defp reading_piece(location, %{id: id, token: token, scope: scope})
       when is_binary(id) and is_binary(token) do
    if scope == location.scope,
      do: current_piece(location, id, token),
      else: {:error, "This piece belongs to a different writing folder. Reopen it to continue."}
  end

  defp reading_piece(location, %Entry{file_id: nil, origin: "before", source_key: key} = source)
       when is_binary(key) and key != "" do
    current = Repo.get(Entry, source.id)

    if current && current.source_key == key && current.lock_version == source.lock_version &&
         current.body == source.body && current.title == source.title do
      with {:ok, piece} <- Poems.from_historical(location, current) do
        expected = if source.title, do: source.title <> "\n\n" <> source.body, else: source.body

        if piece.body == expected,
          do: {:ok, piece},
          else:
            {:error,
             "The saved copy of this List has changed. Open that copy in Correspondence before adding it."}
      end
    else
      {:error, "This List changed. Reopen it before adding it to a packet."}
    end
  end

  defp reading_piece(_, _), do: {:error, "Choose current saved writing to add to a packet."}

  defp current_piece(location, id, token) do
    with {:ok, piece} <- Poems.get(location, id) do
      if piece.token == token,
        do: {:ok, piece},
        else: {:error, "This piece changed since you opened it. Reopen it before adding it."}
    end
  end
end
