defmodule Still.CorrespondencePacketExportsTest do
  use Still.DataCase, async: false

  alias Still.{Correspondence, Poems, Storage}
  alias Still.Correspondence.PacketExports
  alias Still.Writing.PoemReferences

  setup do
    root = Path.join(System.tmp_dir!(), "still-packet-exports-#{Ecto.UUID.generate()}")
    collection = Path.join(root, "collection")
    File.mkdir_p!(collection)
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    assert {:ok, _} = Storage.set_folder(collection)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:still, :storage_state_directory, previous),
        else: Application.delete_env(:still, :storage_state_directory)

      File.rm_rf!(root)
    end)

    %{location: Storage.collection_location(), root: root}
  end

  test "prepares ordered linked manuscript text without correspondence notes", %{
    location: location
  } do
    {:ok, source} = save_piece(location, "Source", "Linked exact\r\nwords")

    {:ok, first} =
      save_piece(location, "First", "First exact\n" <> PoemReferences.marker(source))

    {:ok, second} = save_piece(location, "Second", "  Second exact\n")
    {:ok, journal} = save_journal(location)

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Same Packet",
        journal_id: journal.id,
        piece_ids: [first.id, second.id],
        preparation_notes: "PRIVATE preparation notes",
        cover_letter: "PRIVATE cover letter"
      })

    assert {:ok, prepared} = PacketExports.prepare(location, packet.id)
    assert prepared.title == "Same Packet"

    assert Enum.map(prepared.segments, &{&1.kind, &1.page_break_before}) ==
             [{:text, false}, {:text, true}]

    assert hd(prepared.segments).body ==
             "First\n\nFirst exact\nSource\n\nLinked exact\r\nwords"

    assert Enum.at(prepared.segments, 1).body == "Second\n\n  Second exact\n"
    refute inspect(prepared.segments) =~ "PRIVATE"
    assert prepared.path =~ "same-packet-"
    assert prepared.path =~ "/collection Exports/Packets/"

    {:ok, another} =
      Correspondence.save_packet(location, %{
        title: "Same Packet",
        journal_id: journal.id,
        piece_ids: [second.id]
      })

    assert {:ok, other_prepared} = PacketExports.prepare(location, another.id)
    refute prepared.path == other_prepared.path
  end

  test "changed reviewed source requires packet review before preparing or publishing", %{
    location: location
  } do
    {:ok, source} = save_piece(location, "Source", "Original")
    {:ok, host} = save_piece(location, "Host", PoemReferences.marker(source))
    {:ok, journal} = save_journal(location)

    attrs = %{title: "Review", journal_id: journal.id, piece_ids: [host.id]}
    {:ok, packet} = Correspondence.save_packet(location, attrs)
    File.write!(source.path, "Changed after packet review")

    assert {:error, message} = PacketExports.prepare(location, packet.id)
    assert message =~ "changed after packet preparation"

    pdf = "%PDF-1.4\nminimal\n%%EOF"
    assert {:error, _} = PacketExports.publish_pdf(location, packet.id, pdf, "stale")

    {:ok, reviewed} = Correspondence.save_packet(location, attrs, packet.id, packet.token)
    assert {:ok, prepared} = PacketExports.prepare(location, reviewed.id)
    assert hd(prepared.segments).body =~ "Changed after packet review"
  end

  test "sent packet exports retain frozen text after originals are edited and removed", %{
    location: location
  } do
    {:ok, piece} = save_piece(location, "Frozen", "Original submitted words")
    {:ok, journal} = save_journal(location)

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Sent packet",
        journal_id: journal.id,
        piece_ids: [piece.id],
        preparation_notes: "PRIVATE note",
        cover_letter: "PRIVATE letter"
      })

    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-11-10")
    {:ok, before} = PacketExports.prepare(location, sent.id)
    assert before.frozen?
    assert hd(before.segments).body == "Frozen\n\nOriginal submitted words"

    File.write!(piece.path, "Changed current words")
    File.rm!(piece.path)
    assert {:ok, after_edit} = PacketExports.prepare(location, sent.id)
    assert after_edit.source_token == before.source_token
    assert after_edit.segments == before.segments

    assert {:ok, _} =
             Correspondence.respond(
               location,
               sent.id,
               sent.token,
               "declined",
               "PRIVATE response",
               "2026-11-11"
             )

    assert {:ok, after_response} = PacketExports.prepare(location, sent.id)
    assert after_response.source_token == before.source_token
  end

  test "publish checks PDF framing and refuses to overwrite an unowned file", %{
    location: location
  } do
    {:ok, piece} = save_piece(location, "Owned safety", "Words")
    {:ok, journal} = save_journal(location)

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Owned safety",
        journal_id: journal.id,
        piece_ids: [piece.id]
      })

    {:ok, prepared} = PacketExports.prepare(location, packet.id)
    pdf = "%PDF-1.4\nminimal\n%%EOF"
    File.mkdir_p!(Path.dirname(prepared.path))
    File.write!(prepared.path, "writer file")

    assert {:error, message} =
             PacketExports.publish_pdf(location, packet.id, pdf, prepared.source_token)

    assert message =~ "left untouched"
    assert File.read!(prepared.path) == "writer file"

    assert {:error, _} =
             PacketExports.publish_pdf(location, packet.id, "%PDF-1.4", prepared.source_token)
  end

  defp save_piece(location, title, body),
    do: Poems.save(location, Poems.new(location), %{title: title, body: body})

  defp save_journal(location),
    do: Correspondence.save_journal(location, %{name: "Packet Export Journal"})
end
