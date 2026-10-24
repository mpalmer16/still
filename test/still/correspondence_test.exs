defmodule Still.CorrespondenceTest do
  use ExUnit.Case, async: false

  alias Still.{Correspondence, Poems, Storage}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "still-correspondence-test-#{System.unique_integer([:positive])}"
      )

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

    %{root: root, collection: collection, location: Storage.collection_location()}
  end

  test "preparation detects changed writing and sent snapshot stays exact through edit and acceptance",
       %{location: location} do
    {:ok, first} =
      save_piece("Original title", "  first exact words\r\n\tindented second line\n\n")

    {:ok, second} = save_piece("Second title", "second exact words\n")
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())

    attrs = packet_attrs(journal.id, [first.id, second.id])
    assert {:ok, packet} = Correspondence.save_packet(location, attrs)
    assert packet.status == "preparing"
    assert packet.piece_ids == [first.id, second.id]

    assert {:ok, changed} =
             Poems.save(location, first, %{title: first.title, body: "changed after review"})

    assert {:error, message} =
             Correspondence.submit(location, packet.id, packet.token, ~D[2026-10-23])

    assert message =~ "changed after packet preparation"

    assert {:ok, reviewed} = Correspondence.save_packet(location, attrs, packet.id, packet.token)

    assert {:ok, sent} =
             Correspondence.submit(location, reviewed.id, reviewed.token, "2026-10-23")

    assert sent.status == "submitted"
    assert sent.snapshot.journal_name == "A Synthetic Journal"
    assert Enum.map(sent.snapshot.pieces, & &1.id) == [first.id, second.id]
    assert Enum.map(sent.snapshot.pieces, & &1.body) == [changed.body, second.body]

    first_snapshot_path =
      Path.join([
        Storage.collection_location().folder,
        "correspondence",
        "snapshots",
        sent.snapshot_ref,
        first.id <> ".txt"
      ])

    assert File.read!(first_snapshot_path) == changed.body

    {:ok, current} = Poems.get(location, first.id)

    {:ok, _edited} =
      Poems.save(location, current, %{title: current.title, body: "later revision"})

    assert {:ok, reopened} = Correspondence.packet(location, packet.id)
    assert Enum.at(reopened.snapshot.pieces, 0).body == changed.body

    assert {:ok, %{frozen?: true, journal: %{name: "A Synthetic Journal"}, pieces: frozen}} =
             Correspondence.export_packet(location, packet.id)

    assert Enum.at(frozen, 0).body == changed.body

    assert {:ok, accepted} =
             Correspondence.respond(
               location,
               packet.id,
               sent.token,
               "accepted",
               "One piece accepted",
               "2026-10-23",
               [second.id]
             )

    assert accepted.accepted_piece_ids == [second.id]
    assert {:ok, history} = Correspondence.history(location, second.id)
    assert length(history) == 1
    assert hd(history).snapshot.body == second.body
    assert {:ok, remaining} = Correspondence.overlap(location, [first.id, second.id])
    assert Enum.map(remaining, & &1.piece_id) == [first.id]

    assert {:ok, accepted_all} =
             Correspondence.respond(
               location,
               packet.id,
               accepted.token,
               "accepted",
               "Second piece accepted",
               "2026-10-24",
               [first.id]
             )

    assert accepted_all.accepted_piece_ids == [second.id, first.id]
    assert {:ok, []} = Correspondence.overlap(location, [first.id, second.id])
  end

  test "stale journal and packet revisions are rejected", %{location: location} do
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())

    assert {:ok, updated} =
             Correspondence.save_journal(
               location,
               Map.put(journal_attrs(), :notes, "new note"),
               journal.id,
               journal.token
             )

    assert {:error, message} =
             Correspondence.save_journal(
               location,
               Map.put(journal_attrs(), :notes, "stale"),
               journal.id,
               journal.token
             )

    assert message =~ "changed on disk"
    assert updated.notes == "new note"

    history_path =
      Path.join([
        Storage.collection_location().folder,
        "correspondence",
        "revisions",
        journal.id,
        journal.token <> ".json"
      ])

    assert Jason.decode!(File.read!(history_path))["notes"] == journal.notes

    {:ok, piece} = save_piece("Untitled", "Words")
    {:ok, packet} = Correspondence.save_packet(location, packet_attrs(journal.id, [piece.id]))

    assert {:error, _} =
             Correspondence.save_packet(
               location,
               packet_attrs(journal.id, [piece.id]),
               packet.id,
               "stale-token"
             )
  end

  test "corrupt records and symlinked correspondence folders fail visibly without changing outside files",
       %{collection: collection} do
    {:ok, journal} = Correspondence.save_journal(Storage.collection_location(), journal_attrs())
    journal_path = Path.join([collection, "correspondence", "journals", journal.id <> ".json"])
    File.write!(journal_path, "{ broken")
    assert {:error, message} = Correspondence.overview(Storage.collection_location())
    assert message =~ "malformed"

    File.rm_rf!(Path.join(collection, "correspondence"))
    outside = Path.join(collection, "outside-correspondence")
    File.mkdir!(outside)
    keep = Path.join(outside, "keep.txt")
    File.write!(keep, "leave this")
    File.ln_s!(outside, Path.join(collection, "correspondence"))
    assert {:error, message} = Correspondence.overview(Storage.collection_location())
    assert message =~ "symlink"
    assert File.read!(keep) == "leave this"
  end

  test "tampered frozen snapshot is reported rather than exported", %{
    location: location,
    collection: collection
  } do
    {:ok, piece} = save_piece("Snapshot", "original")
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())
    {:ok, packet} = Correspondence.save_packet(location, packet_attrs(journal.id, [piece.id]))
    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-23")
    ref = sent.snapshot_ref
    path = Path.join([collection, "correspondence", "snapshots", ref, piece.id <> ".txt"])
    File.write!(path, File.read!(path) <> " tampered")
    assert {:error, message} = Correspondence.export_packet(location, packet.id)
    assert message =~ "snapshot"
  end

  test "recorded event chronology cannot be reordered", %{
    location: location,
    collection: collection
  } do
    {:ok, piece} = save_piece("Chronology", "body")
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())
    {:ok, packet} = Correspondence.save_packet(location, packet_attrs(journal.id, [piece.id]))
    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-23")

    {:ok, awaiting} = Correspondence.set_status(location, sent.id, sent.token, "awaiting")
    path = Path.join([collection, "correspondence", "packets", packet.id <> ".json"])
    raw = path |> File.read!() |> Jason.decode!()
    earlier = DateTime.from_naive!(~N[2000-01-01 00:00:00], "Etc/UTC") |> DateTime.to_iso8601()
    events = List.update_at(raw["events"], 1, &Map.put(&1, "at", earlier))
    File.write!(path, Jason.encode!(Map.put(raw, "events", events), pretty: true) <> "\n")

    assert {:error, _} = Correspondence.packet(location, awaiting.id)
  end

  test "reading an empty configured collection does not create correspondence files", %{
    collection: collection,
    location: location
  } do
    refute File.exists?(Path.join(collection, "correspondence"))
    assert {:ok, %{journals: [], packets: [], pieces: []}} = Correspondence.overview(location)
    refute File.exists?(Path.join(collection, "correspondence"))
  end

  test "concurrent journal edits from one token accept only one writer", %{location: location} do
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())

    results =
      ["first", "second"]
      |> Enum.map(fn note ->
        Task.async(fn ->
          Correspondence.save_journal(
            location,
            Map.put(journal_attrs(), :notes, note),
            journal.id,
            journal.token
          )
        end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
  end

  test "a partial correspondence store is reported and its missing folders are not recreated", %{
    location: location,
    collection: collection
  } do
    {:ok, _journal} = Correspondence.save_journal(location, journal_attrs())
    packets = Path.join([collection, "correspondence", "packets"])
    File.rm_rf!(packets)
    assert {:error, message} = Correspondence.overview(location)
    assert message =~ "incomplete"
    refute File.exists?(packets)
  end

  test "a failed update preserves the previous valid journal record", %{
    location: location,
    collection: collection
  } do
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())
    corr = Path.join(collection, "correspondence")
    outside = Path.join(collection, "outside-revisions")
    File.mkdir!(outside)
    File.ln_s!(outside, Path.join(corr, "revisions"))

    assert {:error, _} =
             Correspondence.save_journal(
               location,
               Map.put(journal_attrs(), :notes, "new"),
               journal.id,
               journal.token
             )

    assert {:ok, current} = Correspondence.journal(location, journal.id)
    assert current.notes == journal.notes
    assert current.token == journal.token
    assert File.ls!(outside) == []
  end

  test "invalid journal URLs and stale preparation exports fail before producing a manuscript", %{
    location: location,
    collection: collection
  } do
    bad = Map.put(journal_attrs(), :website, "javascript:alert(1)")
    assert {:error, message} = Correspondence.save_journal(location, bad)
    assert message =~ "HTTP or HTTPS"
    refute File.exists?(Path.join(collection, "correspondence"))

    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())
    {:ok, piece} = save_piece("Reviewed", "before")
    {:ok, packet} = Correspondence.save_packet(location, packet_attrs(journal.id, [piece.id]))
    {:ok, _changed} = Poems.save(location, piece, %{title: piece.title, body: "after"})
    assert {:error, message} = Correspondence.export_packet(location, packet.id)
    assert message =~ "changed after packet preparation"
  end

  test "an unavailable selected collection returns a visible error", %{location: location} do
    File.rename!(location.folder, location.folder <> "-moved")
    assert {:error, message} = Correspondence.overview(location)
    assert message =~ "unavailable"
  end

  test "correspondence requires the configured collection folder" do
    assert {:ok, _} = Storage.clear_folder()
    assert {:error, message} = Correspondence.overview(nil)
    assert message =~ "Choose a collection folder"
  end

  defp save_piece(title, body) do
    piece = Poems.new(nil)
    Poems.save(Storage.collection_location(), piece, %{title: title, body: body})
  end

  defp journal_attrs do
    %{
      name: "A Synthetic Journal",
      website: "https://example.invalid",
      submission_url: "https://example.invalid/submit",
      interests: "Place and memory",
      guidelines: "Three poems",
      windows: "Unknown; check website",
      fee: "None known",
      simultaneous_policy: "Unverified",
      response_expectation: nil,
      notes: "Synthetic record",
      verified: false,
      shortlisted: true
    }
  end

  defp packet_attrs(journal_id, piece_ids) do
    %{
      title: "October packet",
      journal_id: journal_id,
      piece_ids: piece_ids,
      preparation_notes: "Check line breaks",
      cover_letter: "Dear editors"
    }
  end
end
