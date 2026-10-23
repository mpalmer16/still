defmodule StillWeb.WritingLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Poems, Storage, Writing}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "chosen-folder")
    File.mkdir!(folder)
    on_exit(fn -> Application.put_env(:still, :storage_state_directory, previous) end)
    %{folder: folder, root: root}
  end

  test "untitled pages wrap visually and remain discoverable without rewriting their title", %{
    conn: conn,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    {:ok, view, _} = live(conn, ~p"/writing/new")
    assert has_element?(view, "#file-writing-body[wrap='soft']")
    assert has_element?(view, "#file-writing-title", "")
    body = "  First words\n\n" <> String.duplicate("long line ", 80)
    view |> form("#file-writing-form", writing: %{body: body, title: ""}) |> render_submit()
    {:ok, [saved]} = Poems.list(Storage.collection_location())
    assert saved.title == nil
    assert File.read!(saved.path) == body
    {:ok, shelf, _} = live(conn, ~p"/writing")
    assert has_element?(shelf, "#saved-#{saved.id} .file-piece-title", "First words")
    {:ok, edit, _} = live(conn, ~p"/writing/#{saved.id}/edit")
    assert has_element?(edit, "#file-writing-title[value='']")
    assert Writing.list_entries() == []
  end

  test "blank local draft works without configuring or silently creating a collection", %{
    conn: conn,
    folder: folder
  } do
    {:ok, find, _} = live(conn, ~p"/pages")
    assert has_element?(find, "#saved-writing[href='/writing']")
    {:ok, library, _} = live(conn, ~p"/writing")
    assert has_element?(library, "#writing-local-only", "No collection folder")
    {:ok, view, _} = live(conn, ~p"/?new=1")
    assert has_element?(view, "#file-local-only", "kept only in this browser")
    assert view |> element("#file-writing-title") |> render() =~ "value=\"\""

    view
    |> form("#file-writing-form", writing: %{body: "\n  synthetic draft\n\n", title: ""})
    |> render_submit()

    assert has_element?(view, "#file-problem", "Choose a collection folder")
    assert Storage.collection_location().configured == false
    refute File.exists?(Path.join(folder, "poems"))
    assert Writing.list_entries() == []
  end

  test "transcription saves exact text and reopens as readable escaped writing", %{
    conn: conn,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    {:ok, view, _} = live(conn, ~p"/?new=1")
    text = "\n\n  cobalt <script>fixture</script>  \n\tsecond line\n\nlast stanza\n"

    view
    |> form("#file-writing-form", writing: %{body: text, title: "Synthetic page"})
    |> render_submit()

    {:ok, [saved]} = Poems.list(Storage.collection_location())
    assert_patch(view, ~p"/writing/#{saved.id}/edit")
    assert File.read!(saved.path) == text
    {:ok, read, html} = live(conn, ~p"/writing/#{saved.id}")
    assert has_element?(read, "#file-text")
    assert html =~ "&lt;script&gt;fixture&lt;/script&gt;"
    refute html =~ "<script>fixture</script>"
    {:ok, library, _} = live(conn, ~p"/writing")
    assert has_element?(library, "#saved-#{saved.id}", "Synthetic page")
    assert has_element?(library, ".file-collection-note", Path.join(folder, "poems"))
    {:ok, edit, html} = live(conn, ~p"/writing/#{saved.id}/edit")
    assert html =~ "data-persisted"
    assert has_element?(edit, "#file-writing-body[data-draft-key]")
    assert Poems.get(Storage.collection_location(), saved.id) == {:ok, saved}
  end

  test "empty untitled poem and title rename retain identity, text and earlier words", %{
    conn: conn,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    {:ok, view, _} = live(conn, ~p"/?new=1")
    view |> form("#file-writing-form", writing: %{body: "", title: ""}) |> render_submit()
    {:ok, [saved]} = Poems.list(Storage.collection_location())
    assert saved.body == "" and saved.title == nil

    view
    |> form("#file-writing-form", writing: %{body: "", title: "Synthetic title"})
    |> render_submit()

    {:ok, renamed} = Poems.get(Storage.collection_location(), saved.id)
    assert renamed.id == saved.id and renamed.path == saved.path
    assert renamed.created_at == saved.created_at
    assert renamed.title == "Synthetic title"
    {:ok, read, _} = live(conn, ~p"/writing/#{saved.id}")
    assert has_element?(read, "#file-empty")
    assert has_element?(read, "#file-revisions")
    {:ok, [earlier]} = Poems.revisions(Storage.collection_location(), saved.id)
    assert earlier.body == "" and earlier.title == nil
  end

  test "title-only browser edits preserve CRLF text and prior database writing", %{
    conn: conn,
    folder: folder
  } do
    {:ok, entry} = Writing.save_entry(nil, "Synthetic list words")
    {:ok, _} = Writing.remember_writing(entry)
    before = Writing.current_writing()
    {:ok, _} = Storage.set_folder(folder)
    location = Storage.collection_location()
    text = "\r\n\tfirst stanza\r\n\r\nlast  \r\n"
    {:ok, saved} = Poems.save(location, Poems.new(location), %{title: nil, body: text})
    {:ok, edit, _} = live(conn, ~p"/writing/#{saved.id}/edit")

    edit
    |> form("#file-writing-form",
      writing: %{title: "Changed title", body: String.replace(text, "\r\n", "\n")}
    )
    |> render_submit()

    assert File.read!(saved.path) == text
    assert Writing.current_writing() == before
    assert Writing.list_entries() == [entry]
    assert Writing.list_versions(entry) == []
  end

  test "external edits refuse overwrite and keep local submitted words available", %{
    conn: conn,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    location = Storage.collection_location()
    {:ok, saved} = Poems.save(location, Poems.new(location), %{title: nil, body: "before"})
    {:ok, edit, _} = live(conn, ~p"/writing/#{saved.id}/edit")
    File.write!(saved.path, "outside words\n")

    html =
      edit
      |> form("#file-writing-form", writing: %{title: "Local", body: "local unsaved words"})
      |> render_submit()

    assert has_element?(edit, "#file-problem", "changed on disk")
    assert has_element?(edit, "#file-writing-form[data-unsaved=true][data-save-blocked=true]")
    assert File.read!(saved.path) == "outside words\n"
    refute html =~ "Saved on this Mac"
  end

  test "unavailable and replaced destinations never redirect a save", %{
    conn: conn,
    folder: folder,
    root: root
  } do
    {:ok, _} = Storage.set_folder(folder)
    {:ok, edit, _} = live(conn, ~p"/?new=1")
    File.rename!(folder, folder <> "-unavailable")

    edit
    |> form("#file-writing-form", writing: %{body: "held draft", title: ""})
    |> render_submit()

    assert has_element?(edit, "#file-problem", "unavailable")
    assert Storage.collection_location().folder == folder
    other = Path.join(root, "other-folder")
    File.mkdir!(other)
    {:ok, _} = Storage.set_folder(other)

    edit
    |> form("#file-writing-form", writing: %{body: "held draft", title: ""})
    |> render_submit()

    assert has_element?(edit, "#file-problem", "collection changed")
    refute File.exists?(Path.join(other, "poems"))
    edit |> element("#refresh-file-folder") |> render_click()
    assert has_element?(edit, "#file-save-destination", Path.join(other, "poems"))

    edit
    |> form("#file-writing-form", writing: %{body: "held draft", title: ""})
    |> render_submit()

    {:ok, [saved]} = Poems.list(Storage.collection_location())
    assert saved.body == "held draft"
    assert String.starts_with?(saved.path, other <> "/")
  end

  test "recovery is explicit and reports unavailable browser storage", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/?new=1")
    render_hook(view, "file_recovery_status", %{waiting: true})
    assert has_element?(view, "#file-recovery")
    view |> element("#restore-file-local") |> render_click()
    assert_push_event(view, "file-restore-local", %{})
    render_hook(view, "file_recovery_unavailable", %{})
    assert has_element?(view, "#file-recovery-problem", "cannot keep a local recovery copy")
    assert Storage.collection_location().configured == false
  end
end
