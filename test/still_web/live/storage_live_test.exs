defmodule StillWeb.StorageLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Storage, Writing}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    folder = Path.join(root, "synchronized")
    File.mkdir_p!(folder)
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "local-state"))
    on_exit(fn -> Application.put_env(:still, :storage_state_directory, previous) end)
    %{folder: folder}
  end

  test "no destination is required to keep writing and browser Find exposes settings", %{
    conn: conn
  } do
    {:ok, find, _} = live(conn, ~p"/pages")
    assert has_element?(find, "#storage-settings[href='/storage']")
    {:ok, view, html} = live(conn, ~p"/storage")
    assert html =~ "You can keep writing normally"
    assert has_element?(view, "#backup-now[disabled]")
    assert has_element?(view, "#backup-folder-form")
    assert Storage.status().folder == nil
    assert render_click(view, "backup") =~ "Choose a backup folder"
  end

  test "selection persists, can change and clear, and leaves Now and its revisions alone", %{
    conn: conn,
    folder: folder,
    tmp_dir: root
  } do
    {:ok, first} = Writing.save_entry(nil, "Synthetic original writing")
    {:ok, current} = Writing.save_entry(first, "Synthetic current writing", checkpoint: true)
    {:ok, _} = Writing.remember_writing(current)
    versions = Writing.list_versions(current)
    {:ok, view, _} = live(conn, ~p"/storage")
    view |> form("#backup-folder-form", storage: %{folder: folder}) |> render_submit()
    assert has_element?(view, "#backup-folder-path", folder)
    {:ok, reopened, _} = live(conn, ~p"/storage")
    assert has_element?(reopened, "#backup-folder-path", folder)
    other = Path.join(root, "other-destination")
    File.mkdir_p!(other)
    reopened |> form("#backup-folder-form", storage: %{folder: other}) |> render_submit()
    assert Storage.status().folder == other
    reopened |> element("#clear-backup-folder") |> render_click()
    assert has_element?(reopened, "#no-backup-folder")
    assert File.dir?(folder) and File.dir?(other)
    assert Writing.current_writing().id == current.id
    assert Writing.get_entry!(current.id) == current
    assert Writing.list_versions(current) == versions
  end

  test "browser manual backup confirms local completion and shows verified freshness", %{
    conn: conn,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    {:ok, view, _} = live(conn, ~p"/storage")
    html = view |> element("#backup-now") |> render_click()
    assert html =~ "Backup completed on this computer"
    assert html =~ "Cloud synchronization has not been confirmed"
    assert has_element?(view, "#last-backup", "Last successful backup")
    assert has_element?(view, "#backup-freshness", "matches the last verified backup")
    status = Storage.status()
    assert File.regular?(status.last_backup.path)
    refute status.changed
    view |> element("#refresh-backup-status") |> render_click()
    assert has_element?(view, "#backup-freshness", "matches the last verified backup")
  end

  test "missing destination stays configured and gives actionable guidance", %{
    conn: conn,
    folder: folder,
    tmp_dir: root
  } do
    {:ok, _} = Storage.set_folder(folder)
    File.rmdir!(folder)
    {:ok, view, _} = live(conn, ~p"/storage")
    assert has_element?(view, "#backup-folder-path", folder)
    assert has_element?(view, "#storage-guidance", "Reconnect its drive")
    html = view |> element("#backup-now") |> render_click()
    assert html =~ "storage-problem"
    refute html =~ "Backup completed on this computer"
    refute File.exists?(folder)
    missing = Path.join(root, "not-created")
    view |> form("#backup-folder-form", storage: %{folder: missing}) |> render_submit()
    assert Storage.status().folder == folder
    refute File.exists?(missing)
  end

  test "destination warnings appear once while distinct action errors remain visible", %{
    conn: conn,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    File.rmdir!(folder)
    {:ok, view, _} = live(conn, ~p"/storage")
    assert has_element?(view, "#storage-guidance", "Reconnect its drive")

    for action <- ["#backup-now", "#open-backup-folder"] do
      view |> element(action) |> render_click()
      assert view |> element(".storage-room [role='alert']") |> render() =~ "Reconnect its drive"
      assert has_element?(view, "#storage-problem", "Reconnect its drive")
      refute has_element?(view, "#storage-guidance")
    end

    view
    |> form("#backup-folder-form", storage: %{folder: "relative-folder"})
    |> render_submit()

    assert has_element?(view, "#storage-problem", "must be absolute")
    assert has_element?(view, "#storage-guidance", "Reconnect its drive")

    view |> element("#refresh-backup-status") |> render_click()
    refute has_element?(view, "#storage-problem")
    assert view |> element(".storage-room [role='alert']") |> render() =~ "Reconnect its drive"
    assert Storage.status().folder == folder
    refute File.exists?(folder)
  end
end
