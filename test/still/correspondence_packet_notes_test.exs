defmodule Still.CorrespondencePacketNotesTest do
  use Still.DataCase, async: false

  alias Still.{Correspondence, Poems, Storage}
  alias Still.Correspondence.PacketNotes

  setup do
    root =
      Path.join(System.tmp_dir!(), "still-packet-notes-#{System.unique_integer([:positive])}")

    collection = Path.join(root, "collection")
    File.mkdir_p!(collection)
    old_state = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    assert {:ok, _} = Storage.set_folder(collection)

    on_exit(fn ->
      if old_state,
        do: Application.put_env(:still, :storage_state_directory, old_state),
        else: Application.delete_env(:still, :storage_state_directory)

      File.rm_rf!(root)
    end)

    %{root: root, location: Storage.collection_location()}
  end

  test "legacy preparation notes are a read-only fallback", %{location: location} do
    packet = make_packet(location)

    assert {:ok, notes} = PacketNotes.get(location, packet)
    assert notes == %{packet_id: packet.id, body: "Check line breaks", token: nil}
    assert Repo.get_by(Still.LocalRecord, scope: location.scope, kind: "packet_notes") == nil
  end

  test "notes preserve exact whitespace and reject stale edits", %{location: location} do
    packet = make_packet(location)
    exact = "\tOpening\r\n\r\n  indented\nlast line  "

    assert {:ok, initial} = PacketNotes.get(location, packet.id)
    assert {:ok, saved} = PacketNotes.save(location, packet.id, exact, initial.token)
    assert saved.body == exact
    assert is_binary(saved.token)
    assert {:ok, unchanged} = PacketNotes.save(location, packet.id, exact, saved.token)
    assert unchanged.token == saved.token
    assert {:ok, []} = revisions(location.scope, packet.id)

    assert {:error, message} =
             PacketNotes.save(location, packet.id, "stale overwrite", initial.token)

    assert message =~ "changed on disk"
    assert {:ok, reread} = PacketNotes.get(location, packet.id)
    assert reread.body == exact

    assert {:ok, _second_version} =
             PacketNotes.save(location, packet.id, exact <> "\n", unchanged.token)

    assert {:ok, [_revision]} = revisions(location.scope, packet.id)
  end

  test "ongoing notes remain editable after submission without changing packet or sent text", %{
    location: location
  } do
    packet = make_packet(location)
    assert {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-23")
    original_token = sent.token
    original_snapshot = sent.snapshot

    assert {:ok, fallback} = PacketNotes.get(location, sent.id)
    assert fallback.body == "Check line breaks"

    assert {:ok, saved} =
             PacketNotes.save(location, sent.id, "Follow up in winter\n", fallback.token)

    assert saved.body == "Follow up in winter\n"

    assert {:ok, reopened} = Correspondence.packet(location, sent.id)
    assert reopened.token == original_token
    assert reopened.preparation_notes == "Check line breaks"
    assert reopened.snapshot == original_snapshot

    assert {:ok, second} = PacketNotes.save(location, sent.id, "Reply arrived", saved.token)
    assert second.body == "Reply arrived"
    assert {:ok, current_packet} = Correspondence.packet(location, sent.id)
    assert current_packet.token == original_token
    assert current_packet.snapshot == original_snapshot
    assert {:ok, [_first]} = revisions(location.scope, sent.id)
  end

  test "missing and changed collections never return legacy fallback", %{
    root: root,
    location: location
  } do
    packet = make_packet(location)
    moved = location.folder <> "-moved"
    File.rename!(location.folder, moved)

    assert {:error, message} = PacketNotes.get(location, packet.id)
    assert message =~ "unavailable"

    File.rename!(moved, location.folder)
    second = Path.join(root, "second-collection")
    File.mkdir_p!(second)
    assert {:ok, _} = Storage.set_folder(second)

    assert {:error, changed} = PacketNotes.get(location, packet.id)
    assert changed =~ "active collection changed"
  end

  test "notes reject invalid text", %{location: location} do
    packet = make_packet(location)
    assert {:error, _} = PacketNotes.save(location, packet.id, "bad" <> <<0>>, nil)
    assert {:error, _} = PacketNotes.save(location, packet.id, <<255>>, nil)
    assert {:error, _} = PacketNotes.save(location, packet.id, :not_text, nil)
  end

  defp make_packet(location) do
    piece = Poems.new(location)

    assert {:ok, piece} =
             Poems.save(location, piece, %{title: "A poem", body: "Exact poem words\n"})

    assert {:ok, journal} = Correspondence.save_journal(location, %{name: "A Journal"})

    assert {:ok, packet} =
             Correspondence.save_packet(location, %{
               title: "A packet",
               journal_id: journal.id,
               piece_ids: [piece.id],
               preparation_notes: "Check line breaks",
               cover_letter: "Dear editors"
             })

    packet
  end

  defp revisions(scope, packet_id) do
    rows =
      Repo.all(
        from r in Still.LocalRecord,
          where:
            r.scope == ^scope and r.kind == "revision" and
              like(r.record_key, ^("packet_notes:" <> packet_id <> ":%"))
      )

    {:ok, rows}
  end
end
