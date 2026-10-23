defmodule Still.StorageTest do
  use ExUnit.Case, async: false

  alias Still.Storage

  setup do
    root =
      Path.join(System.tmp_dir!(), "still-storage-test-#{System.unique_integer([:positive])}")

    folder = Path.join(root, "backups")
    state = Path.join(root, "state")
    File.mkdir_p!(folder)
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, state)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:still, :storage_state_directory, previous),
        else: Application.delete_env(:still, :storage_state_directory)

      File.rm_rf!(root)
    end)

    %{folder: folder, state: state}
  end

  test "starts without a destination and requires an existing absolute folder", %{folder: folder} do
    initial = Storage.status()
    refute initial.configured
    refute initial.available
    assert initial.changed
    assert {:error, _} = Storage.backup()

    assert {:error, _} = Storage.set_folder("relative-folder")
    assert {:error, _} = Storage.set_folder(Path.join(folder, "missing"))
    file = Path.join(folder, "a-file")
    File.write!(file, "not a folder")
    assert {:error, _} = Storage.set_folder(file)
    :ok = File.chmod(folder, 0o500)
    assert {:error, _} = Storage.set_folder(folder)
    :ok = File.chmod(folder, 0o700)

    assert {:ok, status} = Storage.set_folder(folder)
    assert status.configured
    assert status.available
    assert status.last_backup == nil
  end

  test "publishes a verified snapshot and tracks logical content changes", %{folder: folder} do
    assert {:ok, _} = Storage.set_folder(folder)
    {entry_id, room_id} = create_fixture_rows()

    try do
      assert {:ok, status} =
               Ecto.Adapters.SQL.Sandbox.unboxed_run(Still.Repo, fn -> Storage.backup() end)

      assert status.configured
      assert status.available
      assert File.regular?(status.last_backup.path)
      assert File.read!(status.last_backup.path) |> binary_part(0, 16) == "SQLite format 3\0"
      refute status.changed
      assert Storage.status().last_backup == status.last_backup
      assert File.ls!(folder) |> Enum.reject(&String.ends_with?(&1, ".partial")) |> length() == 1

      # A filesystem timestamp change alone does not mean writing changed.
      :ok = File.touch(Still.Repo.config()[:database])
      refute Storage.status().changed

      :ok = File.chmod(folder, 0o500)
      assert {:error, _} = Storage.backup()
      failed = Storage.status()
      assert failed.last_backup == status.last_backup
      refute failed.changed
      :ok = File.chmod(folder, 0o700)

      update_row("UPDATE entries SET body = ? WHERE id = ?", ["changed words", entry_id])
      assert Storage.status().changed
      update_row("UPDATE entries SET body = ? WHERE id = ?", ["original words", entry_id])
      refute Storage.status().changed

      update_row("UPDATE versions SET body = ? WHERE entry_id = ?", ["changed revision", entry_id])

      assert Storage.status().changed
      update_row("UPDATE versions SET body = ? WHERE entry_id = ?", ["earlier words", entry_id])
      refute Storage.status().changed

      update_row("UPDATE room_states SET light = ? WHERE id = ?", [51, room_id])
      assert Storage.status().changed
      update_row("UPDATE room_states SET light = ? WHERE id = ?", [38, room_id])
      refute Storage.status().changed

      backup_path = status.last_backup.path
      File.rm_rf!(Path.dirname(backup_path))
      missing = Storage.status()
      assert missing.changed
      assert missing.last_backup.path == backup_path
      assert missing.error =~ "missing"
    after
      remove_fixture_rows(entry_id, room_id)
    end
  end

  test "changing or clearing a destination clears only its associated success proof", %{
    folder: folder
  } do
    assert {:ok, _} = Storage.set_folder(folder)

    assert {:ok, _status} =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Still.Repo, fn -> Storage.backup() end)

    alternate = folder <> "-alternate"
    File.mkdir_p!(alternate)

    assert {:ok, changed} = Storage.set_folder(alternate)
    assert changed.folder == alternate
    assert changed.last_backup == nil
    assert changed.changed

    assert {:ok, cleared} = Storage.clear_folder()
    refute cleared.configured
    assert cleared.folder == nil
    assert cleared.last_backup == nil
  end

  test "a settings write failure preserves the last saved folder", %{folder: folder, state: state} do
    assert {:ok, _} = Storage.set_folder(folder)

    assert {:ok, backup_status} =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Still.Repo, fn -> Storage.backup() end)

    state_file = state |> Path.join("*.json") |> Path.wildcard() |> hd()
    saved = state_file <> ".saved"
    :ok = File.rename(state_file, saved)
    :ok = File.mkdir(state_file)
    alternate = folder <> "-alternate"
    File.mkdir_p!(alternate)

    assert {:error, message} = Storage.set_folder(alternate)
    assert message =~ "Could not save backup settings"

    File.rm_rf!(state_file)
    :ok = File.rename(saved, state_file)
    restored = Storage.status()
    assert restored.folder == folder
    assert restored.last_backup == backup_status.last_backup
  end

  test "corrupt settings fail closed until an explicit folder update", %{
    folder: folder,
    state: state
  } do
    assert {:ok, _} = Storage.set_folder(folder)
    state_file = state |> Path.join("*.json") |> Path.wildcard() |> hd()
    File.write!(state_file, "not valid settings")

    status = Storage.status()
    assert status.changed
    assert status.error =~ "could not be read"
    assert {:error, message} = Storage.backup()
    assert message =~ "could not be read"

    assert {:ok, repaired} = Storage.set_folder(folder)
    assert repaired.configured
    assert repaired.folder == folder
    assert repaired.last_backup == nil
  end

  test "altered backup contents lose their proof and another backup never replaces them", %{
    folder: folder
  } do
    {entry_id, room_id} = create_fixture_rows()

    try do
      assert {:ok, _} = Storage.set_folder(folder)
      assert {:ok, first} = Storage.backup()
      path = first.last_backup.path
      {:ok, snapshot} = Exqlite.start_link(database: path, mode: :readwrite)

      try do
        Exqlite.query!(snapshot, "UPDATE entries SET body = ? WHERE id = ?", [
          "altered snapshot",
          entry_id
        ])
      after
        GenServer.stop(snapshot)
      end

      altered = File.read!(path)
      status = Storage.status()
      assert status.changed
      assert status.error =~ "no longer matches"
      assert {:ok, second} = Storage.backup()
      refute second.changed
      refute second.last_backup.path == path
      assert File.read!(path) == altered
      assert length(File.ls!(folder)) == 2

      assert %{rows: [["original words"]]} =
               Ecto.Adapters.SQL.Sandbox.unboxed_run(Still.Repo, fn ->
                 Still.Repo.query!("SELECT body FROM entries WHERE id = ?", [entry_id])
               end)
    after
      remove_fixture_rows(entry_id, room_id)
    end
  end

  defp create_fixture_rows do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Still.Repo, fn ->
      %{rows: [[entry_id]]} =
        Still.Repo.query!("""
        INSERT INTO entries (body, lock_version, origin, source, inserted_at, updated_at)
        VALUES ('original words', 1, 'now', '{}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """)

      %{rows: [[room_id]]} =
        Still.Repo.query!(
          "INSERT INTO room_states (recent, light, letters) VALUES ('{}', 38, 50) RETURNING id"
        )

      Still.Repo.query!(
        """
        INSERT INTO versions (entry_id, title, body, inserted_at)
        VALUES (?, NULL, 'earlier words', CURRENT_TIMESTAMP)
        """,
        [entry_id]
      )

      {entry_id, room_id}
    end)
  end

  defp update_row(sql, params) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Still.Repo, fn -> Still.Repo.query!(sql, params) end)
  end

  defp remove_fixture_rows(entry_id, room_id) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Still.Repo, fn ->
      Still.Repo.query!("DELETE FROM versions WHERE entry_id = ?", [entry_id])
      Still.Repo.query!("DELETE FROM room_states WHERE id = ?", [room_id])
      Still.Repo.query!("DELETE FROM entries WHERE id = ?", [entry_id])
    end)
  end
end
