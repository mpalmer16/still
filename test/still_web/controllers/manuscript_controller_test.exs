defmodule StillWeb.ManuscriptControllerTest do
  use StillWeb.ConnCase, async: false
  alias Still.{Correspondence, Poems, Storage}

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    collection = Path.join(dir, "collection")
    File.mkdir_p!(collection)
    {:ok, _} = Storage.set_folder(collection)
    location = Storage.collection_location()

    {:ok, piece} =
      Poems.save(location, Poems.new(location), %{
        title: "A synthetic manuscript",
        body: "  first\r\n\r\nsecond\n"
      })

    {:ok, journal} = Correspondence.save_journal(location, %{name: "A synthetic destination"})

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Synthetic packet",
        journal_id: journal.id,
        piece_ids: [piece.id]
      })

    %{location: location, piece: piece, packet: packet}
  end

  test "DOCX is a noncached download and never marks a packet sent", %{
    conn: conn,
    location: loc,
    packet: p
  } do
    response = get(conn, "/correspondence/packets/#{p.id}/export/docx")
    assert response.status == 200
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert [disposition] = get_resp_header(response, "content-disposition")
    assert disposition =~ "attachment;"
    assert disposition =~ ".docx"
    assert {:ok, _} = :zip.extract(response.resp_body, [:memory])
    assert {:ok, current} = Correspondence.packet(loc, p.id)
    assert current.status == "preparing"
    assert current.snapshot_ref == nil
    assert current.token == p.token
  end

  test "sent download uses frozen exact text after original revision", %{
    conn: conn,
    location: loc,
    packet: p,
    piece: piece
  } do
    {:ok, sent} = Correspondence.submit(loc, p.id, p.token, "2026-10-23")
    {:ok, _} = Poems.save(loc, piece, %{title: "Different title", body: "different words"})
    response = get(conn, "/correspondence/packets/#{p.id}/export/txt")
    assert response.status == 200
    assert response.resp_body == piece.body
    assert {:ok, reopened} = Correspondence.packet(loc, p.id)
    assert reopened.token == sent.token
  end

  test "unavailable collection fails without serving a fallback", %{conn: conn, packet: p} do
    {:ok, _} = Storage.clear_folder()
    response = get(conn, "/correspondence/packets/#{p.id}/export/txt")
    assert response.status == 422
    assert response.resp_body =~ "Choose a collection folder"
    assert get_resp_header(response, "content-disposition") == []
  end

  test "unsupported export format and invalid identifiers fail clearly", %{conn: conn, packet: p} do
    assert get(conn, "/correspondence/packets/#{p.id}/export/pdf").status == 422
    assert get(conn, "/correspondence/packets/invalid/export/txt").status == 422
  end
end
