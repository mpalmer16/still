defmodule Still.Correspondence.PacketExports do
  @moduledoc "Prepares reviewed correspondence packets for PDF export."

  alias Still.Correspondence

  @max_pdf_bytes 20_000_000

  @doc "Prepare exact packet manuscript text, expanding only words verified by Correspondence."
  def prepare(location, packet_id) do
    with {:ok, exported} <- Correspondence.export_packet(location, packet_id),
         {:ok, segments} <- manuscript_segments(exported.pieces) do
      packet = exported.packet

      source_token =
        source_token(packet.id, packet.title, packet.piece_ids, packet.snapshot_ref, segments)

      relative_path = relative_path(packet.title, packet.id)

      with {:ok, path} <- Still.Writing.Exports.artifact_path(location, relative_path) do
        {:ok,
         %{
           title: packet.title,
           segments: segments,
           source_token: source_token,
           packet_id: packet.id,
           path: path,
           relative_path: relative_path,
           frozen?: exported.frozen?
         }}
      end
    end
  end

  @doc "Publish PDF bytes only if the packet manuscript still matches the prepared review."
  def publish_pdf(location, packet_id, bytes, expected_source_token)
      when is_binary(bytes) and is_binary(expected_source_token) do
    with :ok <- valid_pdf(bytes),
         {:ok, result} <-
           Still.Writing.Files.with_collection_lock(location, fn _active ->
             with {:ok, prepared} <- prepare(location, packet_id),
                  true <- prepared.source_token == expected_source_token do
               Still.Writing.Exports.publish_artifact(
                 location,
                 "packet:" <> packet_id,
                 prepared.relative_path,
                 bytes,
                 expected_source_token
               )
             else
               false -> stale()
               {:error, _} = error -> error
               _ -> {:error, "The PDF export could not be prepared safely."}
             end
           end) do
      {:ok, result}
    else
      {:error, _} = error -> error
      _ -> {:error, "The PDF export could not be prepared safely."}
    end
  end

  def publish_pdf(_, _, _, _), do: {:error, "The PDF export could not be prepared safely."}

  defp manuscript_segments(pieces) do
    if is_list(pieces) and pieces != [] and Enum.all?(pieces, &valid_piece?/1) do
      {:ok,
       pieces
       |> Enum.with_index()
       |> Enum.map(fn {piece, index} ->
         body =
           if piece.title_in_body do
             piece.body
           else
             piece.title <> "\n\n" <> piece.body
           end

         %{kind: :text, body: body, page_break_before: index > 0}
       end)}
    else
      {:error, "The packet has no complete manuscript text to export."}
    end
  end

  defp valid_piece?(%{id: id, title: title, body: body, title_in_body: title_in_body}),
    do:
      is_binary(id) and is_binary(title) and is_binary(body) and
        is_boolean(title_in_body) and String.valid?(title) and String.valid?(body)

  defp valid_piece?(_), do: false

  defp source_token(packet_id, title, piece_ids, snapshot_ref, segments) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({packet_id, title, piece_ids, snapshot_ref, segments}, [
        :deterministic
      ])
    )
    |> Base.encode16(case: :lower)
  end

  defp relative_path(title, packet_id) do
    slug =
      title
      |> String.normalize(:nfd)
      |> String.replace(~r/\p{Mn}/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 60)

    slug = if slug in [nil, ""], do: "packet", else: slug
    short_id = String.replace(packet_id, "-", "") |> String.slice(0, 8)
    Path.join(["Packets", "#{slug}-#{short_id}.pdf"])
  end

  defp valid_pdf(bytes) do
    if byte_size(bytes) <= @max_pdf_bytes and String.starts_with?(bytes, "%PDF-") and
         String.contains?(bytes, "%%EOF") do
      :ok
    else
      {:error, "The PDF is incomplete or larger than 20 MB; nothing was exported."}
    end
  end

  defp stale, do: {:error, "The packet changed after review; review it again before exporting."}
end
