defmodule Still.CorrespondencePoemReferencesTest do
  use Still.DataCase, async: false

  alias Still.{Correspondence, Poems, Storage}
  alias Still.Writing.PoemReferences

  setup do
    root =
      Path.join(System.tmp_dir!(), "still-corr-poem-references-#{Ecto.UUID.generate()}")

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

    %{location: Storage.collection_location()}
  end

  test "source edits stale a prepared packet until it is reviewed again", %{location: location} do
    {:ok, source} = save_piece(location, "Source", "Original source\r\nwords")

    {:ok, host} =
      save_piece(
        location,
        "Host",
        "Opening\r\n" <> PoemReferences.marker(source) <> "\r\nClosing"
      )

    {:ok, journal} = save_journal(location)
    attrs = packet_attrs(journal.id, [host.id])
    {:ok, packet} = Correspondence.save_packet(location, attrs)

    File.write!(source.path, "Changed source\r\nwords")

    assert {:error, export_message} = Correspondence.export_packet(location, packet.id)
    assert export_message =~ "changed after packet preparation"

    assert {:error, stale_message} =
             Correspondence.submit(location, packet.id, packet.token, "2026-11-10")

    assert stale_message =~ "changed after packet preparation"

    assert {:ok, reviewed} = Correspondence.save_packet(location, attrs, packet.id, packet.token)

    assert {:ok, submitted} =
             Correspondence.submit(location, reviewed.id, reviewed.token, "2026-11-10")

    assert hd(submitted.snapshot.pieces).body ==
             "Host\n\nOpening\r\nChanged source\r\nwords\r\nClosing"
  end

  test "submission freezes the expanded words after a later source edit", %{location: location} do
    {:ok, source} = save_piece(location, "Source", "Exact source\r\nline\n")

    {:ok, host} =
      save_piece(
        location,
        "Host",
        "Host words\n" <> PoemReferences.marker(source) <> "\nAfter"
      )

    {:ok, journal} = save_journal(location)
    {:ok, packet} = Correspondence.save_packet(location, packet_attrs(journal.id, [host.id]))
    {:ok, submitted} = Correspondence.submit(location, packet.id, packet.token, "2026-11-10")
    frozen_body = "Host\n\nHost words\nSource\n\nExact source\r\nline\n\nAfter"
    assert hd(submitted.snapshot.pieces).body == frozen_body

    File.write!(source.path, "New words")
    assert {:ok, exported} = Correspondence.export_packet(location, packet.id)
    assert exported.frozen?
    assert hd(exported.pieces).body == frozen_body
  end

  test "a missing linked poem blocks packet preparation and submission", %{location: location} do
    {:ok, source} = save_piece(location, "Source", "Words")
    {:ok, host} = save_piece(location, "Host", "Host\n" <> PoemReferences.marker(source))
    {:ok, journal} = save_journal(location)
    {:ok, packet} = Correspondence.save_packet(location, packet_attrs(journal.id, [host.id]))

    File.rm!(source.path)

    assert {:error, message} =
             Correspondence.submit(location, packet.id, packet.token, "2026-11-10")

    assert message =~ "linked poem is unavailable"
    assert {:ok, preparing} = Correspondence.packet(location, packet.id)
    assert preparing.status == "preparing"
    assert preparing.snapshot_ref == nil
  end

  test "source markers inside linked text remain literal and are not recursively expanded", %{
    location: location
  } do
    {:ok, deep} = save_piece(location, "Deep", "Deep words")
    {:ok, source} = save_piece(location, "Source", "Source\n" <> PoemReferences.marker(deep))
    {:ok, host} = save_piece(location, "Host", PoemReferences.marker(source))
    {:ok, journal} = save_journal(location)
    {:ok, packet} = Correspondence.save_packet(location, packet_attrs(journal.id, [host.id]))

    assert {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-11-10")

    assert hd(sent.snapshot.pieces).body ==
             "Host\n\nSource\n\nSource\n" <> PoemReferences.marker(deep)
  end

  defp save_piece(location, title, body) do
    Poems.save(location, Poems.new(location), %{title: title, body: body})
  end

  defp save_journal(location) do
    Correspondence.save_journal(location, %{
      name: "Synthetic Journal",
      website: "https://example.invalid",
      submission_url: "https://example.invalid/submit",
      interests: "Poems",
      guidelines: "A short packet",
      windows: "Open",
      fee: "None",
      simultaneous_policy: "Unknown",
      verified: false,
      shortlisted: true
    })
  end

  defp packet_attrs(journal_id, piece_ids) do
    %{
      title: "Linked poem packet",
      journal_id: journal_id,
      piece_ids: piece_ids,
      preparation_notes: "Review linked text",
      cover_letter: "Dear editors"
    }
  end
end
