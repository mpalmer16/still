defmodule Still.Correspondence.PacketNotesBatchTest do
  use Still.DataCase, async: false

  alias Still.{Correspondence, LocalRecord, Poems, Repo, Storage}
  alias Still.Correspondence.PacketNotes

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "still-packet-notes-batch-#{System.unique_integer([:positive])}"
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

    %{root: root, location: Storage.collection_location()}
  end

  test "batches legacy fallback, saved notes, and an explicit clear", %{location: location} do
    first = packet(location, "Legacy fallback")
    second = packet(location, "Saved notes")
    cleared = packet(location, "Must stay cleared")

    {:ok, first_notes} = PacketNotes.get(location, first.id)
    {:ok, _} = PacketNotes.save(location, second.id, "Latest private notes", nil)
    {:ok, clear_initial} = PacketNotes.get(location, cleared.id)
    {:ok, _} = PacketNotes.save(location, cleared.id, "", clear_initial.token)

    assert {:ok, result} = PacketNotes.bodies(location, [first, second, cleared])

    assert result == %{
             first.id => "Legacy fallback",
             second.id => "Latest private notes",
             cleared.id => ""
           }

    assert first_notes.body == "Legacy fallback"
  end

  test "reads only requested scope and does not query for an empty packet set", %{
    location: location,
    root: root
  } do
    local_packet = packet(location, "Local legacy")
    other_folder = Path.join(root, "other")
    File.mkdir_p!(other_folder)
    assert {:ok, _} = Storage.set_folder(other_folder)
    other_location = Storage.collection_location()

    Repo.insert!(%LocalRecord{
      scope: other_location.scope,
      kind: "packet_notes",
      record_key: local_packet.id,
      data: %{"packet_id" => local_packet.id, "body" => "Other scope"}
    })

    assert {:ok, _} = Storage.set_folder(location.folder)

    id = local_packet.id

    assert {:ok, %{^id => "Local legacy"}} =
             PacketNotes.bodies(location, [local_packet])

    counter = query_counter()
    assert {:ok, %{}} = PacketNotes.bodies(location, [])
    assert :atomics.get(counter, 1) == 0
  end

  test "one notes query serves many packets", %{location: location} do
    packets = Enum.map(1..30, fn n -> packet(location, "Legacy #{n}") end)

    for p <- packets,
        do: assert({:ok, _} = PacketNotes.save(location, p.id, "Saved #{p.id}", nil))

    counter = query_counter()
    assert {:ok, bodies} = PacketNotes.bodies(location, packets)
    assert map_size(bodies) == 30
    assert :atomics.get(counter, 1) == 1
  end

  test "malformed requested saved notes fail instead of using legacy text", %{location: location} do
    p = packet(location, "Legacy")
    {:ok, _} = PacketNotes.save(location, p.id, "Private", nil)
    row = Repo.get_by!(LocalRecord, scope: location.scope, kind: "packet_notes", record_key: p.id)
    Repo.update!(LocalRecord.changeset(row, %{data: %{"packet_id" => p.id, "body" => nil}}))

    assert {:error, "The saved packet notes are malformed."} = PacketNotes.bodies(location, [p])
  end

  test "unavailable and switched collections do not return fallbacks", %{
    location: location,
    root: root
  } do
    p = packet(location, "Legacy")
    moved = location.folder <> "-moved"
    File.rename!(location.folder, moved)
    assert {:error, message} = PacketNotes.bodies(location, [p])
    assert message =~ "unavailable"
    File.rename!(moved, location.folder)

    other = Path.join(root, "other")
    File.mkdir_p!(other)
    assert {:ok, _} = Storage.set_folder(other)
    assert {:error, message} = PacketNotes.bodies(location, [p])
    assert message =~ "active collection changed"
  end

  defp packet(location, notes) do
    {:ok, piece} = Poems.save(location, Poems.new(location), %{body: "Words"})

    {:ok, journal} =
      Correspondence.save_journal(location, %{name: "A place #{Ecto.UUID.generate()}"})

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Packet",
        journal_id: journal.id,
        piece_ids: [piece.id],
        preparation_notes: notes
      })

    packet
  end

  defp query_counter do
    counter = :atomics.new(1, [])
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:still, :repo, :query],
        fn _, _, meta, c ->
          if String.contains?(meta[:query] || "", "local_records") do
            :atomics.add(c, 1, 1)
          end
        end,
        counter
      )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler) end)
    counter
  end
end
