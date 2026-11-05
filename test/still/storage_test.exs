defmodule Still.StorageTest do
  use Still.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Still.Repo
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
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM collection_folders WHERE root LIKE ?", [
          "%#{Path.basename(root)}%"
        ])
      end)

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
    assert {:error, _} = backup()

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
    assert {:ok, configured} = Storage.set_folder(folder)
    folder = configured.folder
    {entry_id, room_id} = create_fixture_rows()

    try do
      assert {:ok, status} =
               backup()

      assert status.configured
      assert status.available
      assert File.regular?(status.last_backup.path)
      assert File.read!(status.last_backup.path) |> binary_part(0, 16) == "SQLite format 3\0"
      refute status.changed
      assert Storage.status().last_backup == status.last_backup
      assert status.last_backup.path == Path.join(folder, "still-backup.sqlite3")
      assert File.ls!(folder) == ["still-backup.sqlite3"]

      # A filesystem timestamp change alone does not mean writing changed.
      :ok = File.touch(Still.Repo.config()[:database])
      refute Storage.status().changed

      :ok = File.chmod(folder, 0o500)
      assert {:error, _} = backup()
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
      File.rm!(backup_path)
      missing = Storage.status()
      assert missing.changed
      assert missing.last_backup.path == backup_path
      assert missing.error =~ "missing"
    after
      remove_fixture_rows(entry_id, room_id)
    end
  end

  test "automatic backup skips unchanged databases and replaces the verified file after a change",
       %{
         folder: folder
       } do
    check = fn -> Sandbox.unboxed_run(Repo, &Storage.backup_if_needed/0) end
    assert :skipped = check.()
    assert {:ok, configured} = Storage.set_folder(folder)
    {entry_id, room_id} = create_fixture_rows()

    try do
      assert {:ok, initial} = check.()
      assert :unchanged = check.()
      scope = Sandbox.unboxed_run(Repo, fn -> Storage.collection_location().scope end)

      update_row("UPDATE entries SET pending = '{}', collection_scope = ? WHERE id = ?", [
        scope,
        entry_id
      ])

      assert :skipped = check.()

      update_row("UPDATE entries SET body = ?, pending = 'null' WHERE id = ?", [
        "new words",
        entry_id
      ])

      assert {:ok, updated} = check.()
      assert updated.last_backup.path == initial.last_backup.path
      refute updated.changed
      assert File.ls!(configured.folder) == ["still-backup.sqlite3"]
      assert :unchanged = check.()
    after
      remove_fixture_rows(entry_id, room_id)
    end
  end

  test "an unavailable destination retains its proof and works again when reconnected", %{
    folder: folder
  } do
    assert {:ok, configured} = Storage.set_folder(folder)
    folder = configured.folder
    assert {:ok, backed} = backup()
    original = File.read!(backed.last_backup.path)
    disconnected = folder <> "-disconnected"
    File.rename!(folder, disconnected)

    unavailable = Storage.status()
    assert unavailable.folder == folder
    refute unavailable.available
    assert unavailable.changed
    assert unavailable.last_backup == backed.last_backup
    assert unavailable.error =~ "Reconnect its drive"
    assert {:error, message} = backup()
    assert message =~ "Reconnect its drive"
    assert {:error, _} = Storage.set_folder(folder <> "-missing")
    assert Storage.status().folder == folder
    refute File.exists?(folder)

    File.rename!(disconnected, folder)
    reconnected = Storage.status()
    assert reconnected.available
    refute reconnected.changed
    assert reconnected.error == nil
    assert reconnected.last_backup == backed.last_backup
    assert File.read!(backed.last_backup.path) == original
  end

  test "changing or clearing a destination clears only its associated success proof", %{
    folder: folder
  } do
    assert {:ok, configured} = Storage.set_folder(folder)
    folder = configured.folder

    assert {:ok, _status} =
             backup()

    alternate = folder <> "-alternate"
    File.mkdir_p!(alternate)

    assert {:ok, changed} = Storage.set_folder(alternate)
    alternate = changed.folder
    assert changed.folder == alternate
    assert changed.last_backup == nil
    assert changed.changed

    assert {:ok, cleared} = Storage.clear_folder()
    refute cleared.configured
    assert cleared.folder == nil
    assert cleared.last_backup == nil
  end

  test "a settings write failure preserves the last saved folder", %{folder: folder, state: state} do
    assert {:ok, configured} = Storage.set_folder(folder)
    folder = configured.folder

    assert {:ok, backup_status} =
             backup()

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
    assert {:ok, configured} = Storage.set_folder(folder)
    folder = configured.folder
    state_file = state |> Path.join("*.json") |> Path.wildcard() |> hd()
    File.write!(state_file, "not valid settings")

    status = Storage.status()
    assert status.changed
    assert status.error =~ "could not be read"
    assert {:error, message} = backup()
    assert message =~ "could not be read"

    assert {:ok, repaired} = Storage.set_folder(folder)
    assert repaired.configured
    assert repaired.folder == folder
    assert repaired.last_backup == nil
  end

  test "altered backup contents lose their proof and the next verified backup replaces the one file",
       %{
         folder: folder
       } do
    {entry_id, room_id} = create_fixture_rows()

    try do
      assert {:ok, configured} = Storage.set_folder(folder)
      folder = configured.folder
      assert {:ok, first} = backup()
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
      assert {:ok, second} = backup()
      refute second.changed
      assert second.last_backup.path == path
      refute File.read!(path) == altered
      assert File.ls!(folder) == ["still-backup.sqlite3"]

      assert %{rows: [["original words"]]} =
               Ecto.Adapters.SQL.Sandbox.unboxed_run(Still.Repo, fn ->
                 Still.Repo.query!("SELECT body FROM entries WHERE id = ?", [entry_id])
               end)
    after
      remove_fixture_rows(entry_id, room_id)
    end
  end

  test "refuses an unrecognized backup path and refuses a folder containing the live database", %{
    folder: folder
  } do
    final = Path.join(folder, "still-backup.sqlite3")
    File.write!(final, "keep this ordinary file")
    assert {:ok, _} = Storage.set_folder(folder)
    assert {:error, _} = backup()
    assert File.read!(final) == "keep this ordinary file"

    db_root = Path.dirname(Still.Repo.config()[:database])
    assert {:error, message} = Storage.set_folder(db_root)
    assert message =~ "outside Still's live database"

    alias_root = Path.join(Path.dirname(folder), "live-database-parent-alias")
    File.ln_s!(db_root, alias_root)
    assert {:error, message} = Storage.set_folder(alias_root)
    assert message =~ "outside Still's live database"
  end

  test "preserves a valid but unrelated SQLite file at the backup name", %{folder: folder} do
    sqlite = Path.join(Path.dirname(folder), "unrelated.sqlite3")
    File.touch!(sqlite)
    {:ok, db} = Exqlite.start_link(database: sqlite, mode: :readwrite)

    try do
      Exqlite.query!(db, "CREATE TABLE unrelated (words TEXT)")
      Exqlite.query!(db, "INSERT INTO unrelated VALUES ('keep these words')")
    after
      GenServer.stop(db)
    end

    final = Path.join(folder, "still-backup.sqlite3")
    File.copy!(sqlite, final)
    original = File.read!(final)
    assert {:ok, _} = Storage.set_folder(folder)

    assert {:error, message} = backup()
    assert message =~ "not a Still backup"
    assert File.read!(final) == original
    assert Storage.status().last_backup == nil
  end

  test "refuses a valid Still database backup with a different collection identity", %{
    folder: folder
  } do
    other_root = folder <> "-other-collection"

    other_id =
      Sandbox.unboxed_run(Repo, fn -> Still.Writing.Files.collection_scope(other_root) end)

    unrelated = Path.join(Path.dirname(folder), "different-collection.sqlite3")
    {:ok, db} = Exqlite.start_link(database: Repo.config()[:database], mode: :readwrite)

    try do
      Exqlite.query!(db, "VACUUM INTO ?", [unrelated])
    after
      GenServer.stop(db)
    end

    final = Path.join(folder, "still-backup.sqlite3")
    File.copy!(unrelated, final)
    original = File.read!(final)
    assert {:ok, _} = Storage.set_folder(folder)

    assert {:error, message} = backup()
    assert message =~ "belongs to another collection"
    assert File.read!(final) == original

    assert %{rows: [[^other_id]]} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.query!("SELECT id FROM collection_folders WHERE root = ?", [other_root])
             end)
  end

  test "restores only to a new local SQLite file outside the selected writing folder", %{
    folder: folder
  } do
    assert {:ok, _} = Storage.set_folder(folder)
    assert {:ok, status} = backup()
    destination = Path.join(Path.dirname(folder), "restored.sqlite3")
    assert {:ok, ^destination} = Storage.restore_backup(status.last_backup.path, destination)

    assert :ok =
             Exqlite.start_link(database: destination, mode: :readonly)
             |> then(fn {:ok, db} ->
               GenServer.stop(db)
               :ok
             end)

    assert {:error, _} = Storage.restore_backup(status.last_backup.path, destination)

    assert {:error, _} =
             Storage.restore_backup(status.last_backup.path, Path.join(folder, "inside.sqlite3"))

    assert {:error, _} =
             Storage.restore_backup(status.last_backup.path, Still.Repo.config()[:database])
  end

  defp create_fixture_rows do
    Sandbox.unboxed_run(Repo, fn ->
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
    Sandbox.unboxed_run(Repo, fn -> Repo.query!(sql, params) end)
  end

  defp remove_fixture_rows(entry_id, room_id) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("DELETE FROM versions WHERE entry_id = ?", [entry_id])
      Repo.query!("DELETE FROM room_states WHERE id = ?", [room_id])
      Repo.query!("DELETE FROM entries WHERE id = ?", [entry_id])
    end)
  end

  defp backup, do: Sandbox.unboxed_run(Repo, fn -> Storage.backup() end)
end
