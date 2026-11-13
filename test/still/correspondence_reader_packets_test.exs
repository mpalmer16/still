defmodule Still.CorrespondenceReaderPacketsTest do
  use Still.DataCase, async: false

  alias Still.{Correspondence, LocalRecord, Poems, Repo, Storage}
  alias Still.Correspondence.ReaderPackets
  alias Still.Writing.Entry

  setup do
    root =
      Path.join(System.tmp_dir!(), "still-reader-packets-#{System.unique_integer([:positive])}")

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

  test "draft listing avoids snapshots and sent packets", %{location: location} do
    one = piece(location, "One", "One's words\n")
    two = piece(location, "Two", "Two's words\n")
    draft = packet(location, [one], "Draft")
    submitted = packet(location, [two], "Sent")
    assert {:ok, _} = Correspondence.submit(location, submitted.id, submitted.token, "2026-11-01")

    assert {:ok, listed} = Correspondence.draft_packets(location)
    assert Enum.map(listed, & &1.id) == [draft.id]
    assert hd(listed).snapshot_ref == nil
    refute Map.has_key?(hd(listed), :snapshot)
  end

  test "append preserves packet metadata and old review tokens, and duplicate add is a no-op", %{
    location: location
  } do
    original = piece(location, "Original", "Original exact words\n")
    letter = piece(location, "Cover", "Dear editors\n")
    added = piece(location, "Added", "New exact words\n")
    {:ok, journal} = Correspondence.save_journal(location, %{name: "Review Journal"})

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Specific packet",
        journal_id: journal.id,
        piece_ids: [original],
        preparation_notes: "Retain these notes\n",
        cover_letter_piece_id: letter
      })

    # Alter the old source and linked letter after preparation; appending must not
    # silently bless either changed item as reviewed.
    {:ok, original_now} = Poems.get(location, original)

    {:ok, _} =
      Poems.save(location, original_now, %{title: original_now.title, body: "Revised old words"})

    {:ok, letter_now} = Poems.get(location, letter)

    {:ok, _} =
      Poems.save(location, letter_now, %{title: letter_now.title, body: "Revised letter"})

    {:ok, added_now} = Poems.get(location, added)
    old_piece_token = packet.piece_tokens[original]
    old_letter_token = packet.cover_letter_piece_token
    before = File.read!(Path.join(location.folder, original_now.relative_path))

    assert {:ok, appended} =
             Correspondence.add_to_packet(
               location,
               added,
               packet.id,
               packet.token,
               added_now.token
             )

    assert appended.piece_ids == [original, added]
    assert appended.piece_tokens[original] == old_piece_token
    assert appended.cover_letter_piece_token == old_letter_token
    assert appended.title == packet.title
    assert appended.preparation_notes == packet.preparation_notes
    assert appended.cover_letter_piece_id == letter
    assert appended.events == packet.events

    stored =
      Repo.get_by!(LocalRecord, scope: location.scope, kind: "packet", record_key: packet.id)

    refute Map.has_key?(stored.data, "token")
    assert File.read!(Path.join(location.folder, original_now.relative_path)) == before

    assert {:error, message} =
             Correspondence.submit(location, appended.id, appended.token, "2026-11-02")

    assert message =~ "changed after packet preparation"

    {:ok, added_latest} = Poems.get(location, added)

    {:ok, _} =
      Poems.save(location, added_latest, %{
        title: added_latest.title,
        body: "Changed after append"
      })

    assert {:ok, same} =
             Correspondence.add_to_packet(
               location,
               added,
               packet.id,
               appended.token,
               added_now.token
             )

    assert same.token == appended.token

    revisions =
      Repo.all(
        from r in LocalRecord,
          where:
            r.scope == ^location.scope and r.kind == "revision" and
              r.record_key == ^("packet:" <> packet.id <> ":1")
      )

    assert length(revisions) == 1
  end

  test "rejects stale packet and stale source tokens", %{location: location} do
    first = piece(location, "First", "first")
    candidate = piece(location, "Candidate", "candidate")
    packet = packet(location, [first], "Draft")
    {:ok, current} = Poems.get(location, candidate)
    {:ok, _} = Poems.save(location, current, %{title: current.title, body: "externally changed"})

    assert {:error, message} =
             Correspondence.add_to_packet(
               location,
               candidate,
               packet.id,
               packet.token,
               current.token
             )

    assert message =~ "changed"

    assert {:error, stale_source} =
             Correspondence.start_packet(location, candidate, current.token, "Stale")

    assert stale_source =~ "changed"
    {:ok, latest} = Poems.get(location, candidate)

    assert {:ok, created} =
             Correspondence.start_packet(location, candidate, latest.token, "Fresh")

    assert created.title == "Fresh"
    assert created.piece_ids == [candidate]

    assert {:error, stale} =
             Correspondence.add_to_packet(
               location,
               candidate,
               packet.id,
               "old packet token",
               "new token"
             )

    assert stale =~ "changed on disk"
  end

  test "rejects unavailable, switched, deleted, and sent packet drafts", %{
    root: root,
    location: location
  } do
    source = piece(location, "Source", "source")
    candidate = piece(location, "Candidate", "candidate")
    draft = packet(location, [source], "Draft")
    {:ok, candidate_now} = Poems.get(location, candidate)
    moved = location.folder <> "-away"
    File.rename!(location.folder, moved)

    assert {:error, _} =
             Correspondence.add_to_packet(
               location,
               candidate,
               draft.id,
               draft.token,
               candidate_now.token
             )

    File.rename!(moved, location.folder)

    other = Path.join(root, "other")
    File.mkdir_p!(other)
    assert {:ok, _} = Storage.set_folder(other)

    assert {:error, message} =
             Correspondence.add_to_packet(
               location,
               candidate,
               draft.id,
               draft.token,
               candidate_now.token
             )

    assert message =~ "collection changed"
    assert {:ok, _} = Storage.set_folder(location.folder)

    assert {:ok, sent} = Correspondence.submit(location, draft.id, draft.token, "2026-11-03")

    assert {:error, _} =
             Correspondence.add_to_packet(
               location,
               candidate,
               sent.id,
               sent.token,
               candidate_now.token
             )

    # Simulate a packet removed from the local database while its stale reader is open.
    Repo.delete!(
      Repo.get_by!(LocalRecord, scope: location.scope, kind: "packet", record_key: sent.id)
    )

    assert {:error, _} =
             Correspondence.add_to_packet(
               location,
               candidate,
               sent.id,
               sent.token,
               candidate_now.token
             )
  end

  test "reader packet creation and addition reject a stale current reading", %{
    location: location
  } do
    source_id = piece(location, "Current title", "Current exact words\n")
    {:ok, opened} = Poems.get(location, source_id)
    {:ok, _changed} = Poems.save(location, opened, %{title: opened.title, body: "Changed words"})

    assert {:error, message} = ReaderPackets.create(location, opened, "Stale packet")
    assert message =~ "changed"

    first_id = piece(location, "First", "First words")
    packet = packet(location, [first_id], "Draft")

    assert {:error, add_message} =
             ReaderPackets.add(location, opened, packet.id, packet.token)

    assert add_message =~ "changed"
    assert {:ok, unchanged} = Correspondence.packet(location, packet.id)
    assert unchanged.piece_ids == [first_id]
  end

  test "reader packet actions refuse a switched or unavailable collection", %{
    root: root,
    location: location
  } do
    source_id = piece(location, "Source", "Source words")
    {:ok, opened} = Poems.get(location, source_id)
    packet = packet(location, [piece(location, "Already in draft", "Existing words")], "Draft")
    moved = location.folder <> "-offline"
    File.rename!(location.folder, moved)

    assert {:error, unavailable} = ReaderPackets.create(location, opened, "Unavailable")
    assert unavailable =~ "unavailable"
    assert {:error, _} = ReaderPackets.add(location, opened, packet.id, packet.token)

    File.rename!(moved, location.folder)
    other_folder = Path.join(root, "other-collection")
    File.mkdir_p!(other_folder)
    assert {:ok, _} = Storage.set_folder(other_folder)

    assert {:error, switched} = ReaderPackets.create(location, opened, "Switched")
    assert switched =~ "changed"
    assert {:error, _} = ReaderPackets.add(location, opened, packet.id, packet.token)
    assert {:ok, _} = Storage.set_folder(location.folder)
  end

  test "a notebook reading uses its indexed revision and refuses later title metadata", %{
    location: location
  } do
    id = piece(location, "Exact title", "Exact body\n")
    source = Repo.get_by!(Entry, file_id: id)
    {:ok, opened} = Poems.get(location, id)
    bytes = File.read!(opened.path)

    assert {:ok, packet} = ReaderPackets.create(location, source, "From a notebook")
    assert packet.piece_ids == [id]

    assert {:ok, _} = Poems.set_title_role(location, opened, nil)
    assert File.read!(opened.path) == bytes
    assert {:error, message} = ReaderPackets.create(location, source, "An older reading")
    assert message =~ "changed"
    assert {:error, _} = ReaderPackets.add(location, source, packet.id, packet.token)
  end

  test "historical reading copies exact text once and packet addition reuses its stable file", %{
    location: location
  } do
    historical = historical_entry("A: Clear Title:", "  first line\r\n\n\tlast line\n")
    original = Repo.get!(Entry, historical.id)
    exact_copy = original.title <> "\n\n" <> original.body

    assert ReaderPackets.supported?(original)
    assert ReaderPackets.historical?(original)
    assert {:ok, packet} = ReaderPackets.create(location, original, "Historical draft")
    [copy_id] = packet.piece_ids
    assert {:ok, copy} = Poems.get(location, copy_id)
    assert copy.title == original.title
    assert copy.body == exact_copy
    assert File.read!(copy.path) == exact_copy

    assert {:ok, same_packet} = ReaderPackets.add(location, original, packet.id, packet.token)
    assert same_packet.piece_ids == [copy_id]
    assert {:ok, [same_copy]} = Poems.list(location)
    assert same_copy.id == copy_id
    assert same_copy.body == exact_copy
    assert Repo.get!(Entry, original.id) == original
  end

  test "historical source edits and later saved-copy edits are rejected", %{location: location} do
    historical = historical_entry("Old title", "Old exact words\n")
    original = Repo.get!(Entry, historical.id)
    assert {:ok, packet} = ReaderPackets.create(location, original, "Historical draft")

    changed_source = Repo.get!(Entry, original.id)
    {:ok, _changed_source} = Still.Writing.save_entry(changed_source, "Changed historical words")

    assert {:error, source_message} =
             ReaderPackets.add(location, original, packet.id, packet.token)

    assert source_message =~ "changed"

    # Restore the indexed source to prove the saved, identity-linked copy has its own guard.
    current_source = Repo.get!(Entry, original.id)
    {:ok, restored_source} = Still.Writing.save_entry(current_source, original.body)

    {:ok, restored_source} =
      Repo.update(Ecto.Changeset.change(restored_source, title: original.title))

    {:ok, copy} = Poems.get(location, hd(packet.piece_ids))

    {:ok, _edited_copy} =
      Poems.save(location, copy, %{title: "Edited copy", body: "Different words"})

    assert {:error, copy_message} =
             ReaderPackets.add(location, restored_source, packet.id, packet.token)

    assert copy_message =~ "saved copy"
    assert {:ok, unchanged_packet} = Correspondence.packet(location, packet.id)
    assert unchanged_packet.piece_ids == packet.piece_ids
  end

  defp historical_entry(title, body) do
    {:ok, entry} = Still.Writing.save_entry(nil, body)

    entry
    |> Ecto.Changeset.change(
      origin: "before",
      source_key: "reader-packet-historical-#{System.unique_integer([:positive])}",
      title: title
    )
    |> Repo.update!()
  end

  defp piece(location, title, body) do
    poem = Poems.new(location)
    {:ok, saved} = Poems.save(location, poem, %{title: title, body: body})
    saved.id
  end

  defp packet(location, ids, title) do
    {:ok, journal} = Correspondence.save_journal(location, %{name: "Journal #{title}"})

    {:ok, saved} =
      Correspondence.save_packet(location, %{title: title, piece_ids: ids, journal_id: journal.id})

    saved
  end
end
