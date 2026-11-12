defmodule Still.CorrespondenceTest do
  use Still.DataCase, async: false

  alias Still.{Correspondence, LocalRecord, Poems, Repo, Storage}

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

    snapshot_row =
      Repo.get_by!(LocalRecord,
        scope: location.scope,
        kind: "snapshot",
        record_key: sent.snapshot_ref
      )

    assert snapshot_row.bytes
           |> Jason.decode!()
           |> Map.fetch!("pieces")
           |> hd()
           |> Map.fetch!("body") == changed.body

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

    revision =
      Repo.get_by!(LocalRecord,
        scope: location.scope,
        kind: "revision",
        record_key: "journal:#{journal.id}:1"
      )

    assert revision.data["notes"] == journal.notes

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

  test "packets can be assembled without a destination and link a live cover letter", %{
    location: location
  } do
    {:ok, poem} = save_piece("Manuscript", "the manuscript\n")
    {:ok, letter} = save_piece("Scratch letter", "Dear editors,\n\nPlease read this.\n")

    assert {:ok, packet} =
             Correspondence.save_packet(location, %{
               title: "Unassigned packet",
               piece_ids: [poem.id],
               cover_letter_piece_id: letter.id
             })

    assert packet.journal_id == nil
    assert packet.cover_letter == nil
    assert packet.cover_letter_piece_id == letter.id

    assert {:error, "Choose a destination before sending this packet."} =
             Correspondence.submit(location, packet.id, packet.token, "2026-11-12")

    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())

    assert {:ok, packet} =
             Correspondence.save_packet(
               location,
               %{
                 title: packet.title,
                 journal_id: journal.id,
                 piece_ids: packet.piece_ids,
                 cover_letter_piece_id: letter.id
               },
               packet.id,
               packet.token
             )

    {:ok, edited_letter} = Poems.get(location, letter.id)

    {:ok, _} =
      Poems.save(location, edited_letter, %{title: edited_letter.title, body: "new words"})

    assert {:error, message} =
             Correspondence.submit(location, packet.id, packet.token, "2026-11-12")

    assert message =~ "linked cover letter changed"
  end

  test "linked letter is frozen at submission and duplicate starts fresh for another destination",
       %{location: location} do
    {:ok, poem} = save_piece("Manuscript", "exact poem\n")
    {:ok, letter} = save_piece("Scratch letter", "Dear editors,\n\nExact letter.\n")
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())

    assert {:ok, packet} =
             Correspondence.save_packet(location, %{
               title: "Original packet",
               journal_id: journal.id,
               piece_ids: [poem.id],
               cover_letter_piece_id: letter.id
             })

    assert {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-11-12")
    assert sent.snapshot.cover_letter == letter.body
    assert sent.cover_letter == sent.snapshot.cover_letter

    assert {:ok, _notes} =
             Still.Correspondence.PacketNotes.save(location, sent.id, "latest private notes", nil)

    {:ok, current_letter} = Poems.get(location, letter.id)
    {:ok, _} = Poems.save(location, current_letter, %{title: current_letter.title, body: "later"})
    assert {:ok, reopened} = Correspondence.packet(location, sent.id)
    assert reopened.snapshot.cover_letter == letter.body

    assert {:ok, duplicate} = Correspondence.duplicate_packet(location, sent.id, sent.token)
    assert duplicate.id != sent.id
    assert duplicate.journal_id == nil
    assert duplicate.status == "preparing"
    assert duplicate.snapshot_ref == nil
    assert duplicate.cover_letter_piece_id == letter.id
    assert duplicate.cover_letter == nil
    assert duplicate.preparation_notes == "latest private notes"
    assert {:ok, still_sent} = Correspondence.packet(location, sent.id)
    assert still_sent.snapshot.cover_letter == letter.body
  end

  test "linked cover letter review includes nested poem sources", %{location: location} do
    alias Still.Writing.PoemReferences

    {:ok, source} = save_piece("Source", "source words\n")

    {:ok, letter} =
      save_piece("Scratch letter", "Dear editors,\n" <> PoemReferences.marker(source))

    {:ok, poem} = save_piece("Manuscript", "poem words\n")
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())

    assert {:ok, packet} =
             Correspondence.save_packet(location, %{
               journal_id: journal.id,
               piece_ids: [poem.id],
               cover_letter_piece_id: letter.id
             })

    {:ok, current_source} = Poems.get(location, source.id)

    {:ok, _} =
      Poems.save(location, current_source, %{title: current_source.title, body: "changed source"})

    assert {:error, message} =
             Correspondence.submit(location, packet.id, packet.token, "2026-11-12")

    assert message =~ "linked cover letter changed"
  end

  test "missing linked cover letters are rejected", %{location: location} do
    {:ok, poem} = save_piece("Manuscript", "the manuscript\n")
    missing_id = Ecto.UUID.generate()

    assert {:error, message} =
             Correspondence.save_packet(location, %{
               piece_ids: [poem.id],
               cover_letter_piece_id: missing_id
             })

    assert message =~ "linked cover letter is missing"
  end

  test "submitted snapshots preserve title meaning separately from identical display text", %{
    location: location
  } do
    {:ok, automatic} =
      Poems.save(location, Poems.new(location), %{body: "Same words\nfirst-line prose"})

    {:ok, explicit} =
      Poems.save(location, Poems.new(location), %{
        body: "Preface\nSame words\nexplicit prose",
        title_line: 2
      })

    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())

    {:ok, packet} =
      Correspondence.save_packet(location, packet_attrs(journal.id, [automatic.id, explicit.id]))

    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-23")
    [first, second] = sent.snapshot.pieces

    assert first.title == second.title
    assert first.title_in_body and second.title_in_body
    assert first.title_line == nil
    assert first.title_source == "first_line"
    assert second.title_line == 2
    assert second.title_source == "explicit"
    assert first.body == "Same words\nfirst-line prose"
    assert second.body == "Preface\nSame words\nexplicit prose"
  end

  test "corrupt database records fail visibly while collection files remain untouched", %{
    collection: collection
  } do
    location = Storage.collection_location()
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())

    row =
      Repo.get_by!(LocalRecord, scope: location.scope, kind: "journal", record_key: journal.id)

    row
    |> LocalRecord.changeset(%{data: %{"id" => journal.id, "name" => "corrupt"}})
    |> Repo.update!()

    assert {:error, message} = Correspondence.overview(location)
    assert message =~ "malformed"
    refute File.exists?(Path.join(collection, "correspondence"))
  end

  test "tampered frozen snapshot bytes are reported rather than exported", %{location: location} do
    {:ok, piece} = save_piece("Snapshot", "original")
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())
    {:ok, packet} = Correspondence.save_packet(location, packet_attrs(journal.id, [piece.id]))
    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-23")

    row =
      Repo.get_by!(LocalRecord,
        scope: location.scope,
        kind: "snapshot",
        record_key: sent.snapshot_ref
      )

    row |> LocalRecord.changeset(%{bytes: row.bytes <> " tampered"}) |> Repo.update!()
    assert {:error, message} = Correspondence.export_packet(location, packet.id)
    assert message =~ "snapshot"
  end

  test "recorded event chronology cannot be reordered", %{location: location} do
    {:ok, piece} = save_piece("Chronology", "body")
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())
    {:ok, packet} = Correspondence.save_packet(location, packet_attrs(journal.id, [piece.id]))
    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-23")

    {:ok, awaiting} = Correspondence.set_status(location, sent.id, sent.token, "awaiting")
    row = Repo.get_by!(LocalRecord, scope: location.scope, kind: "packet", record_key: packet.id)
    data = row.data
    earlier = DateTime.from_naive!(~N[2000-01-01 00:00:00], "Etc/UTC") |> DateTime.to_iso8601()
    events = List.update_at(data["events"], 1, &Map.put(&1, "at", earlier))
    row |> LocalRecord.changeset(%{data: Map.put(data, "events", events)}) |> Repo.update!()

    assert {:error, _} = Correspondence.packet(location, awaiting.id)
  end

  test "reading an empty configured collection does not create correspondence files", %{
    collection: collection,
    location: location
  } do
    assert {:ok, %{journals: [], packets: [], pieces: []}} = Correspondence.overview(location)
    assert Repo.all(Ecto.Query.from(r in LocalRecord, where: r.scope == ^location.scope)) == []
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

  test "correspondence records stay in SQLite and never create collection metadata files", %{
    location: location,
    collection: collection
  } do
    {:ok, _journal} = Correspondence.save_journal(location, journal_attrs())

    assert not is_nil(
             Repo.one(
               Ecto.Query.from(r in LocalRecord,
                 where: r.scope == ^location.scope and r.kind == "journal"
               )
             )
           )

    refute File.exists?(Path.join(collection, "correspondence"))
  end

  test "a failed stale update preserves the previous valid journal record", %{location: location} do
    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())

    {:ok, current} =
      Correspondence.save_journal(
        location,
        Map.put(journal_attrs(), :notes, "new"),
        journal.id,
        journal.token
      )

    assert {:error, _} =
             Correspondence.save_journal(
               location,
               Map.put(journal_attrs(), :notes, "stale"),
               journal.id,
               journal.token
             )

    assert {:ok, reopened} = Correspondence.journal(location, journal.id)
    assert reopened.notes == "new"
    assert reopened.token == current.token
  end

  test "invalid journal URLs and stale preparation exports fail before producing a manuscript", %{
    location: location
  } do
    bad = Map.put(journal_attrs(), :website, "javascript:alert(1)")
    assert {:error, message} = Correspondence.save_journal(location, bad)
    assert message =~ "HTTP or HTTPS"
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
