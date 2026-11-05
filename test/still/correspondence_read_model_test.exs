defmodule Still.CorrespondenceReadModelTest do
  use Still.DataCase, async: false

  alias Still.{Correspondence, LocalRecord, Poems, Repo, Storage}
  alias Still.Writing.Version

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "still-correspondence-read-model-#{System.unique_integer([:positive])}"
      )

    folder = Path.join(root, "collection")
    File.mkdir_p!(folder)
    old_state = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    assert {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      if old_state,
        do: Application.put_env(:still, :storage_state_directory, old_state),
        else: Application.delete_env(:still, :storage_state_directory)

      File.rm_rf!(root)
    end)

    %{location: Storage.collection_location()}
  end

  test "overview counts earlier saves and targeted history and overlap preserve validated sent text",
       %{location: location} do
    piece = Poems.new(nil)
    {:ok, piece} = Poems.save(location, piece, %{title: "Current title", body: "Current words"})

    Repo.insert!(%Version{
      entry_id: Repo.get_by!(Still.Writing.Entry, file_id: piece.id).id,
      body: "Earlier words"
    })

    {:ok, journal} = Correspondence.save_journal(location, %{name: "Synthetic Place"})

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Test packet",
        journal_id: journal.id,
        piece_ids: [piece.id],
        preparation_notes: nil,
        cover_letter: nil
      })

    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-20")

    assert {:ok, %{pieces: [%{id: id, revision_count: 1}]}} = Correspondence.overview(location)
    assert id == piece.id

    assert {:ok, [history]} = Correspondence.history(location, piece.id)
    assert history.packet.id == sent.id
    assert history.journal.id == journal.id
    assert history.snapshot.body == piece.body

    assert {:ok, [overlap]} = Correspondence.overlap(location, [piece.id])
    assert overlap.packet.snapshot.pieces |> hd() |> Map.fetch!(:body) == piece.body
  end

  test "overview, history, and overlap fail closed when a frozen snapshot is corrupted", %{
    location: location
  } do
    {piece, sent} = sent_packet(location)

    row =
      Repo.get_by!(LocalRecord,
        scope: location.scope,
        kind: "snapshot",
        record_key: sent.snapshot_ref
      )

    Repo.update!(LocalRecord.changeset(row, %{bytes: row.bytes <> "corrupt"}))

    assert {:error, message} = Correspondence.overview(location)
    assert message =~ "snapshot"
    assert {:error, message} = Correspondence.history(location, piece.id)
    assert message =~ "snapshot"
    assert {:error, message} = Correspondence.overlap(location, [piece.id])
    assert message =~ "snapshot"
  end

  test "overview reflects an ordinary file edit on the next read", %{location: location} do
    piece = Poems.new(nil)
    {:ok, piece} = Poems.save(location, piece, %{title: "External title", body: "Original body"})
    path = Path.join(location.folder, piece.relative_path)
    bytes = File.read!(path)
    assert String.contains?(bytes, "Original body")
    File.write!(path, String.replace(bytes, "Original body", "Changed outside Still"))

    assert {:ok, %{pieces: [%{id: id, body: body}]}} = Correspondence.overview(location)
    assert id == piece.id
    assert body =~ "Changed outside Still"
  end

  defp sent_packet(location) do
    piece = Poems.new(nil)
    {:ok, piece} = Poems.save(location, piece, %{title: "Frozen", body: "Frozen words"})
    {:ok, journal} = Correspondence.save_journal(location, %{name: "Snapshot Place"})

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Snapshot packet",
        journal_id: journal.id,
        piece_ids: [piece.id],
        preparation_notes: nil,
        cover_letter: nil
      })

    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-21")
    {piece, sent}
  end
end
