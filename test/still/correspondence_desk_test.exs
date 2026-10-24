defmodule Still.CorrespondenceDeskTest do
  use ExUnit.Case, async: false

  alias Still.{Correspondence, Poems, Storage}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "still-correspondence-desk-test-#{System.unique_integer([:positive])}"
      )

    collection = Path.join(root, "collection")
    File.mkdir_p!(collection)
    previous_state = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    assert {:ok, _} = Storage.set_folder(collection)

    on_exit(fn ->
      if previous_state,
        do: Application.put_env(:still, :storage_state_directory, previous_state),
        else: Application.delete_env(:still, :storage_state_directory)

      File.rm_rf!(root)
    end)

    %{root: root, collection: collection, location: Storage.collection_location()}
  end

  test "an older collection reads an empty desk without creating correspondence data", %{
    collection: collection,
    location: location
  } do
    assert {:ok, %{piece_id: nil, token: nil, updated_at: nil}} = Correspondence.desk(location)
    refute File.exists?(Path.join(collection, "correspondence"))

    assert {:error, _} = Correspondence.place_on_desk(location, Ecto.UUID.generate(), nil)
    assert {:error, _} = Correspondence.place_on_desk(location, "not-a-uuid", nil)
    refute File.exists?(Path.join(collection, "correspondence"))
  end

  test "pin, change, explicit clear, and reload use compare-and-swap tokens", %{
    collection: collection,
    location: location
  } do
    {:ok, first} = save_piece(location, "First", "First exact body.")
    {:ok, second} = save_piece(location, "Second", "Second exact body.")

    assert {:ok, first_desk} = Correspondence.place_on_desk(location, first.id, nil)
    assert first_desk.piece_id == first.id
    assert is_binary(first_desk.token)
    assert is_binary(first_desk.updated_at)
    assert {:ok, ^first_desk} = Correspondence.desk(location)

    assert {:ok, second_desk} =
             Correspondence.place_on_desk(location, second.id, first_desk.token)

    assert second_desk.piece_id == second.id

    assert {:error, stale_message} =
             Correspondence.place_on_desk(location, first.id, first_desk.token)

    assert stale_message =~ "changed since it was opened"
    assert {:ok, ^second_desk} = Correspondence.desk(location)

    assert {:ok, cleared} = Correspondence.clear_desk(location, second_desk.token)
    assert cleared.piece_id == nil
    assert is_binary(cleared.token)
    assert is_binary(cleared.updated_at)
    assert {:ok, ^cleared} = Correspondence.desk(location)

    raw =
      Path.join([collection, "correspondence", "desk.json"])
      |> File.read!()
      |> Jason.decode!()

    assert raw["format"] == "still-correspondence-desk"
    assert raw["version"] == 1
    assert raw["piece_id"] == nil

    revision =
      Path.join([
        collection,
        "correspondence",
        "revisions",
        "desk",
        second_desk.token <> ".json"
      ])

    assert File.read!(revision) != ""
  end

  test "a missing file with an old token is stale and external writes invalidate old tokens", %{
    collection: collection,
    location: location
  } do
    {:ok, piece} = save_piece(location, "Pinned", "Pinned body.")
    {:ok, pinned} = Correspondence.place_on_desk(location, piece.id, nil)
    desk_path = Path.join([collection, "correspondence", "desk.json"])

    File.rm!(desk_path)
    assert {:error, _} = Correspondence.clear_desk(location, pinned.token)
    assert {:ok, %{piece_id: nil, token: nil, updated_at: nil}} = Correspondence.desk(location)

    {:ok, repinned} = Correspondence.place_on_desk(location, piece.id, nil)

    external_bytes =
      Jason.encode!(
        %{
          "format" => "still-correspondence-desk",
          "version" => 1,
          "piece_id" => nil,
          "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        },
        pretty: true
      ) <> "\n"

    File.write!(desk_path, external_bytes)
    assert {:error, message} = Correspondence.clear_desk(location, repinned.token)
    assert message =~ "changed since it was opened"
    assert File.read!(desk_path) == external_bytes
    assert {:ok, external_state} = Correspondence.desk(location)
    assert external_state.piece_id == nil
    assert external_state.token != repinned.token
  end

  test "malformed and symlink desk records are rejected without replacing their target", %{
    collection: collection,
    root: root,
    location: location
  } do
    {:ok, piece} = save_piece(location, "Pinned", "Pinned body.")
    {:ok, _} = Correspondence.place_on_desk(location, piece.id, nil)
    desk_path = Path.join([collection, "correspondence", "desk.json"])

    File.write!(desk_path, "{broken json")
    assert {:error, _} = Correspondence.desk(location)
    assert File.read!(desk_path) == "{broken json"

    updated_at = DateTime.utc_now() |> DateTime.to_iso8601()

    missing_piece_id =
      Jason.encode!(%{
        "format" => "still-correspondence-desk",
        "version" => 1,
        "updated_at" => updated_at
      })

    File.write!(desk_path, missing_piece_id)
    assert {:error, _} = Correspondence.desk(location)
    assert File.read!(desk_path) == missing_piece_id

    unknown_format =
      Jason.encode!(%{
        "format" => "other-desk-format",
        "version" => 1,
        "piece_id" => piece.id,
        "updated_at" => updated_at
      })

    File.write!(desk_path, unknown_format)
    assert {:error, _} = Correspondence.desk(location)
    assert File.read!(desk_path) == unknown_format

    File.rm!(desk_path)
    target = Path.join(root, "external.json")
    File.write!(target, "leave this alone")
    File.ln_s!(target, desk_path)

    assert {:error, _} = Correspondence.desk(location)
    assert {:error, _} = Correspondence.clear_desk(location, nil)
    assert File.read!(target) == "leave this alone"
    assert File.lstat!(desk_path).type == :symlink
  end

  test "a desk cannot be read or changed after switching collections", %{
    root: root,
    location: location
  } do
    {:ok, piece} = save_piece(location, "Pinned", "Pinned body.")
    {:ok, pinned} = Correspondence.place_on_desk(location, piece.id, nil)
    other_collection = Path.join(root, "other")
    File.mkdir_p!(other_collection)
    assert {:ok, _} = Storage.set_folder(other_collection)

    assert {:error, message} = Correspondence.desk(location)
    assert message =~ "active collection changed"
    assert {:error, _} = Correspondence.place_on_desk(location, piece.id, pinned.token)
    assert {:error, _} = Correspondence.clear_desk(location, pinned.token)
    refute File.exists?(Path.join(other_collection, "correspondence"))
  end

  test "a configured collection that becomes unavailable cannot read or write its desk", %{
    collection: collection,
    location: location
  } do
    {:ok, piece} = save_piece(location, "Pinned", "Pinned body.")
    {:ok, pinned} = Correspondence.place_on_desk(location, piece.id, nil)
    moved_collection = collection <> "-moved"
    assert :ok = File.rename(collection, moved_collection)

    assert {:error, _} = Correspondence.desk(location)
    assert {:error, _} = Correspondence.place_on_desk(location, piece.id, pinned.token)
    assert {:error, _} = Correspondence.clear_desk(location, pinned.token)
    refute File.exists?(Path.join(collection, "correspondence"))
  end

  test "pinning and clearing leave source and packet bytes unchanged", %{
    collection: collection,
    location: location
  } do
    {:ok, piece} =
      save_piece(location, "Packet piece", "Exact source words\r\nwith line endings.\n")

    {:ok, journal} = Correspondence.save_journal(location, %{name: "Desk Journal"})

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Existing packet",
        journal_id: journal.id,
        piece_ids: [piece.id]
      })

    source_bytes = File.read!(piece.path)
    packet_path = Path.join([collection, "correspondence", "packets", packet.id <> ".json"])
    packet_bytes = File.read!(packet_path)

    {:ok, pinned} = Correspondence.place_on_desk(location, piece.id, nil)
    assert {:ok, _cleared} = Correspondence.clear_desk(location, pinned.token)

    assert File.read!(piece.path) == source_bytes
    assert File.read!(packet_path) == packet_bytes
  end

  defp save_piece(location, title, body),
    do: Poems.save(location, Poems.new(location), %{title: title, body: body})
end
