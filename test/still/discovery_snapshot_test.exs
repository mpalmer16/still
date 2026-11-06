defmodule Still.DiscoverySnapshotTest do
  use Still.DataCase, async: false

  alias Ecto.Changeset
  alias Still.{Repo, Storage, Writing}
  alias Still.Writing.{Discovery, Entry, Files, Version}

  setup do
    base = Path.join(System.tmp_dir!(), "still-discovery-#{Ecto.UUID.generate()}")
    folder = Path.join(base, "writing")
    File.mkdir_p!(Path.join(folder, "First"))
    File.mkdir_p!(Path.join(folder, "Second"))
    old_state = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(base, "state"))
    assert {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      Application.put_env(:still, :storage_state_directory, old_state)
      File.rm_rf!(base)
    end)

    %{folder: folder, location: Storage.collection_location()}
  end

  test "one reading operation batches collection verification instead of querying per file", %{
    folder: folder,
    location: location
  } do
    for number <- 1..100 do
      File.write!(
        Path.join(folder, "First/#{number}.txt"),
        "Synthetic #{number}\n\nThe cobalt lantern shines beside the river."
      )
    end

    assert {:ok, [piece | _]} = Files.list(location)
    counter = :atomics.new(1, [])
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:still, :repo, :query],
        &__MODULE__.count_query/4,
        {self(), counter}
      )

    try do
      Writing.with_collection_snapshot(
        fn ->
          entry = Writing.get_entry!(piece.entry_id)
          before_lists = :atomics.get(counter, 1)
          assert {:ok, listed} = Files.list_read_only(location)
          assert Enum.any?(listed, &(&1.id == piece.id))
          assert {:ok, recovered_list} = Files.list(location)
          assert Enum.any?(recovered_list, &(&1.id == piece.id))
          # A cached listing needs only its collection identity and indexed rows,
          # with no further file reconciliation.
          assert (:atomics.get(counter, 1) - before_lists) in 1..4
          Writing.notebook_neighbors(entry)
          Writing.connections(entry)
          Writing.companions(entry)
          Writing.gravity_field(entry.body, entry_id: entry.id, reading: true)
        end,
        recover: true
      )

      assert :atomics.get(counter, 1) in 1..119
      assert Discovery.current(location) == :none
    after
      :telemetry.detach(handler)
    end
  end

  test "a recovery-required listing cannot reuse a read-only snapshot", %{location: location} do
    {:ok, saved} = Still.Poems.save(location, Still.Poems.new(location), %{body: "earlier words"})
    entry = Repo.get_by!(Entry, file_id: saved.id, collection_scope: location.scope)

    Writing.with_collection_snapshot(fn ->
      assert Discovery.current(location) == {:ok, location.scope}
      refute Discovery.current(location, recover: true) == {:ok, location.scope}

      Repo.insert!(%Version{
        entry_id: entry.id,
        title: entry.title,
        body: entry.body,
        title_line: entry.title_line,
        title_anchor: entry.title_anchor,
        file_prefix: entry.file_prefix
      })

      pending = %{
        "kind" => "save",
        "stage" => nil,
        "old_token" => entry.file_token,
        "body" => "recovered words",
        "prefix" => Base.encode64(entry.file_prefix || ""),
        "title_line" => entry.title_line,
        "title_anchor" => entry.title_anchor,
        "metadata" => %{
          "notebook_id" => entry.notebook_id,
          "notebook" => entry.notebook,
          "source_order" => entry.source_order,
          "list_label" => entry.list_label
        }
      }

      Repo.update!(
        Changeset.change(entry, pending: pending, lock_version: entry.lock_version + 1)
      )

      assert {:ok, [recovered]} = Files.list(location)
      assert recovered.body == "recovered words"
      assert File.read!(saved.path) == "recovered words"
    end)
  end

  test "the next operation observes external edits and moves while retaining earlier words", %{
    folder: folder,
    location: location
  } do
    path = Path.join(folder, "First/3.txt")
    File.write!(path, "Earlier words")
    assert {:ok, [original]} = Files.list(location)

    assert Writing.with_collection_snapshot(fn -> Writing.get_entry!(original.entry_id).body end) ==
             "Earlier words"

    File.write!(path, "Externally changed words")
    File.rename!(path, Path.join(folder, "Second/3.txt"))

    moved = Writing.with_collection_snapshot(fn -> Writing.get_entry!(original.entry_id) end)
    assert moved.file_id == original.id
    assert moved.relative_path == "Second/3.txt"
    assert moved.body == "Externally changed words"
    assert moved.notebook_id != original.notebook_id
    assert {:ok, versions} = Files.revisions(location, original.id)
    assert Enum.any?(versions, &(&1.body == "Earlier words"))
  end

  test "a reading snapshot never permits a stale save and is cleared on failure", %{
    folder: folder,
    location: location
  } do
    path = Path.join(folder, "First/1.txt")
    File.write!(path, "First words")
    assert {:ok, [original]} = Files.list(location)

    assert_raise RuntimeError, "abort reading", fn ->
      Writing.with_collection_snapshot(fn ->
        assert {:ok, current} = Files.get(location, original.id)
        File.write!(path, "Newer external words")
        assert {:error, _} = Files.save(location, current, %{body: "Stale replacement"})
        raise "abort reading"
      end)
    end

    assert Discovery.current(location) == :none
    assert File.read!(path) == "Newer external words"

    assert Writing.with_collection_snapshot(fn -> Writing.get_entry!(original.entry_id).body end) ==
             "Newer external words"
  end

  test "an unavailable folder cannot reuse the preceding reading snapshot", %{
    folder: folder,
    location: location
  } do
    File.write!(Path.join(folder, "First/1.txt"), "Kept words")
    assert {:ok, [original]} = Files.list(location)
    Writing.with_collection_snapshot(fn -> assert Writing.get_entry!(original.entry_id) end)
    File.rename!(folder, folder <> "-away")

    Writing.with_collection_snapshot(fn ->
      assert Files.discovery_scope() == nil
      assert {:error, _} = Files.get(location, original.id)
    end)

    refute Still.Repo.get!(Still.Writing.Entry, original.entry_id).file_missing
    File.rename!(folder <> "-away", folder)
  end

  def count_query(_event, _measurements, _metadata, {owner, counter}) do
    if self() == owner, do: :atomics.add_get(counter, 1, 1)
  end
end
