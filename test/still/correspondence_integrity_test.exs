defmodule Still.CorrespondenceIntegrityTest do
  use Still.DataCase, async: false

  alias Still.{Correspondence, Poems, Storage, Writing}

  setup do
    root =
      Path.join(System.tmp_dir!(), "still-corr-integrity-#{System.unique_integer([:positive])}")

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

    %{root: root, collection: collection, location: Storage.collection_location()}
  end

  test "the correspondence collection includes file writing and leaves legacy Lists untouched", %{
    location: location
  } do
    {:ok, legacy} = Writing.save_entry(nil, "SQLite-only legacy list\nwith private words")
    before_entries = Writing.list_entries()
    {:ok, file_piece} = save_piece("File manuscript", "File-backed words")
    {:ok, _journal} = Correspondence.save_journal(location, journal_attrs())

    {:ok, overview} = Correspondence.overview(location)
    assert Enum.map(overview.pieces, & &1.id) == [file_piece.id]
    refute Enum.any?(overview.pieces, &String.contains?(&1.body, "SQLite-only"))
    assert Writing.list_entries() == before_entries
    assert legacy in Writing.list_entries()
    assert Writing.list_versions(legacy) == []
  end

  test "a prepared packet refuses an externally changed source and preserves both copies", %{
    location: location
  } do
    {:ok, piece} = save_piece("Reviewed", "reviewed exact words")
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())
    {:ok, packet} = Correspondence.save_packet(location, packet_attrs(journal.id, [piece.id]))

    File.write!(piece.path, "external editor words\n")

    assert {:error, message} =
             Correspondence.submit(location, packet.id, packet.token, "2026-10-23")

    assert message =~ "changed after packet preparation"
    assert File.read!(piece.path) == "external editor words\n"
    assert {:ok, persisted_packet} = Correspondence.packet(location, packet.id)
    assert persisted_packet.status == "preparing"
    assert persisted_packet.snapshot_ref == nil
    assert File.ls!(Path.join([location.folder, "correspondence", "snapshots"])) == []
  end

  test "a packet from another collection scope cannot write into the currently selected collection",
       %{root: root, location: location} do
    {:ok, piece} = save_piece("Scoped", "original collection")
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())
    {:ok, packet} = Correspondence.save_packet(location, packet_attrs(journal.id, [piece.id]))

    other = Path.join(root, "other-collection")
    File.mkdir_p!(other)
    assert {:ok, _} = Storage.set_folder(other)

    assert {:error, message} =
             Correspondence.submit(location, packet.id, packet.token, "2026-10-23")

    assert message =~ "active collection changed"
    refute File.exists?(Path.join(other, "correspondence"))

    assert {:ok, _} = Storage.set_folder(location.folder)
    assert {:ok, still_preparing} = Correspondence.packet(location, packet.id)
    assert still_preparing.status == "preparing"
  end

  test "the sent snapshot survives source rename and trash", %{location: location} do
    {:ok, piece} = save_piece("Before rename", "the exact submitted body\r\nsecond line\r\n")
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())
    {:ok, packet} = Correspondence.save_packet(location, packet_attrs(journal.id, [piece.id]))
    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-23")
    frozen = hd(sent.snapshot.pieces)

    {:ok, current} = Poems.get(location, piece.id)
    {:ok, renamed} = Poems.save(location, current, %{title: "After rename", body: current.body})
    assert renamed.path != piece.path
    {:ok, _trashed} = Poems.trash(location, renamed)

    assert {:ok, exported} = Correspondence.export_packet(location, packet.id)
    assert exported.frozen?
    assert hd(exported.pieces).body == frozen.body
    assert hd(exported.pieces).title == frozen.title
    assert frozen.body == "the exact submitted body\r\nsecond line\r\n"
  end

  test "malformed event data and malformed snapshot members return errors instead of crashing", %{
    location: location,
    collection: collection
  } do
    {:ok, piece} = save_piece("Malformed", "safe body")
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())
    {:ok, packet} = Correspondence.save_packet(location, packet_attrs(journal.id, [piece.id]))
    packet_path = Path.join([collection, "correspondence", "packets", packet.id <> ".json"])
    raw_packet = Jason.decode!(File.read!(packet_path))
    File.write!(packet_path, Jason.encode!(Map.put(raw_packet, "events", ["not an event map"])))
    assert {:error, _} = Correspondence.packet(location, packet.id)

    # Recreate a valid packet, submit it, then alter the snapshot and update the
    # record digest to model a syntactically valid but structurally malformed file.
    File.rm!(packet_path)

    {:ok, replacement} =
      Correspondence.save_packet(location, packet_attrs(journal.id, [piece.id]))

    packet_path = Path.join([collection, "correspondence", "packets", replacement.id <> ".json"])
    {:ok, sent} = Correspondence.submit(location, replacement.id, replacement.token, "2026-10-23")

    snapshot_path =
      Path.join([collection, "correspondence", "snapshots", sent.snapshot_ref <> ".json"])

    bad_snapshot = snapshot_path |> File.read!() |> Jason.decode!() |> Map.put("pieces", [42])
    snapshot_bytes = Jason.encode!(bad_snapshot, pretty: true) <> "\n"
    File.write!(snapshot_path, snapshot_bytes)
    raw_packet = packet_path |> File.read!() |> Jason.decode!()
    digest = :crypto.hash(:sha256, snapshot_bytes) |> Base.encode16(case: :lower)

    File.write!(
      packet_path,
      Jason.encode!(Map.put(raw_packet, "snapshot_digest", digest), pretty: true) <> "\n"
    )

    assert {:error, _} = Correspondence.packet(location, sent.id)
    assert File.read!(snapshot_path) == snapshot_bytes
  end

  test "a preparing packet cannot carry a submitted lifecycle event", %{
    location: location,
    collection: collection
  } do
    {:ok, piece} = save_piece("Lifecycle", "safe body")
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())
    {:ok, packet} = Correspondence.save_packet(location, packet_attrs(journal.id, [piece.id]))
    packet_path = Path.join([collection, "correspondence", "packets", packet.id <> ".json"])
    raw = packet_path |> File.read!() |> Jason.decode!()

    event = %{
      "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "date" => "2026-10-23",
      "kind" => "submitted",
      "note" => nil
    }

    File.write!(packet_path, Jason.encode!(Map.put(raw, "events", [event]), pretty: true) <> "\n")

    assert {:error, _} = Correspondence.packet(location, packet.id)
  end

  test "overlapping pieces remain visible until submission is terminal; partial acceptance is recorded per piece",
       %{location: location} do
    {:ok, first} = save_piece("First", "first")
    {:ok, second} = save_piece("Second", "second")
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())

    {:ok, packet} =
      Correspondence.save_packet(location, packet_attrs(journal.id, [first.id, second.id]))

    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-23")
    assert {:ok, overlap} = Correspondence.overlap(location, [first.id, second.id])
    assert Enum.map(overlap, & &1.piece_id) == [first.id, second.id]

    {:ok, accepted} =
      Correspondence.respond(
        location,
        sent.id,
        sent.token,
        "accepted",
        "Second accepted",
        "2026-10-23",
        [second.id]
      )

    assert accepted.accepted_piece_ids == [second.id]
    assert Enum.find(accepted.events, &(&1.kind == "response")).accepted_piece_ids == [second.id]
    assert {:ok, unresolved_overlap} = Correspondence.overlap(location, [first.id, second.id])
    assert Enum.map(unresolved_overlap, & &1.piece_id) == [first.id]

    {:ok, completed} =
      Correspondence.respond(
        location,
        accepted.id,
        accepted.token,
        "declined",
        "The remaining piece was returned",
        "2026-10-24"
      )

    assert completed.accepted_piece_ids == [second.id]
    assert Enum.count(completed.events, &(&1.kind == "response")) == 2
    assert {:ok, []} = Correspondence.overlap(location, [first.id, second.id])
    assert {:ok, first_history} = Correspondence.history(location, first.id)
    assert hd(first_history).snapshot.body == "first"
    assert {:ok, second_history} = Correspondence.history(location, second.id)
    assert hd(second_history).snapshot.body == "second"
  end

  defp save_piece(title, body) do
    Poems.save(Storage.collection_location(), Poems.new(nil), %{title: title, body: body})
  end

  defp journal_attrs do
    %{
      name: "Integrity Journal #{System.unique_integer([:positive])}",
      website: "https://example.invalid",
      submission_url: "https://example.invalid/submit",
      interests: "Synthetic",
      guidelines: "Synthetic only",
      windows: "Unknown",
      fee: "Unknown",
      simultaneous_policy: "unknown",
      response_expectation: nil,
      notes: nil,
      verified: false,
      shortlisted: false
    }
  end

  defp packet_attrs(journal_id, piece_ids) do
    %{
      title: "Synthetic integrity packet",
      journal_id: journal_id,
      piece_ids: piece_ids,
      preparation_notes: nil,
      cover_letter: nil
    }
  end
end
