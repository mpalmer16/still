defmodule StillWeb.PoemLiveTest do
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

  test "blank local draft works without configuring or silently creating a collection", %{
    conn: conn,
    folder: folder
  } do
    {:ok, find, _} = live(conn, ~p"/pages")
    assert has_element?(find, "#poems-collection[href='/poems']")
    {:ok, library, _} = live(conn, ~p"/poems")
    assert has_element?(library, "#poems-local-only", "No collection folder")
    {:ok, view, _} = live(conn, ~p"/poems/new")
    assert has_element?(view, "#poem-local-only", "No poem file has been saved")
    assert view |> element("#poem-title") |> render() =~ "value=\"\""

    view
    |> form("#poem-form", poem: %{body: "\n  synthetic draft\n\n", title: ""})
    |> render_submit()

    assert has_element?(view, "#poem-problem", "Choose a collection folder")
    assert Storage.collection_location().configured == false
    refute File.exists?(Path.join(folder, "poems"))
    assert Writing.list_entries() == []
  end

  test "transcription saves exact text and reopens as readable escaped writing", %{
    conn: conn,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    {:ok, view, _} = live(conn, ~p"/poems/new")
    text = "\n\n  cobalt <script>fixture</script>  \n\tsecond line\n\nlast stanza\n"
    view |> form("#poem-form", poem: %{body: text, title: "Synthetic page"}) |> render_submit()
    {:ok, [saved]} = Poems.list(Storage.collection_location())
    assert_patch(view, ~p"/poems/#{saved.id}/edit")
    assert File.read!(saved.path) == text
    {:ok, read, html} = live(conn, ~p"/poems/#{saved.id}")
    assert has_element?(read, "#poem-text")
    assert html =~ "&lt;script&gt;fixture&lt;/script&gt;"
    refute html =~ "<script>fixture</script>"
    {:ok, library, _} = live(conn, ~p"/poems")
    assert has_element?(library, "#poem-#{saved.id}", "Synthetic page")
    assert has_element?(library, "#poem-collection-location", Path.join(folder, "poems"))
    {:ok, edit, html} = live(conn, ~p"/poems/#{saved.id}/edit")
    assert html =~ "data-persisted"
    assert has_element?(edit, "#poem-body[data-draft-key]")
    assert Poems.get(Storage.collection_location(), saved.id) == {:ok, saved}
  end

  test "empty untitled poem and title rename retain identity, text and earlier words", %{
    conn: conn,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    {:ok, view, _} = live(conn, ~p"/poems/new")
    view |> form("#poem-form", poem: %{body: "", title: ""}) |> render_submit()
    {:ok, [saved]} = Poems.list(Storage.collection_location())
    assert saved.body == "" and saved.title == nil
    view |> form("#poem-form", poem: %{body: "", title: "Synthetic title"}) |> render_submit()
    {:ok, renamed} = Poems.get(Storage.collection_location(), saved.id)
    assert renamed.id == saved.id and renamed.path == saved.path
    assert renamed.created_at == saved.created_at
    assert renamed.title == "Synthetic title"
    {:ok, read, _} = live(conn, ~p"/poems/#{saved.id}")
    assert has_element?(read, "#poem-empty")
    assert has_element?(read, "#poem-revisions")
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
    {:ok, edit, _} = live(conn, ~p"/poems/#{saved.id}/edit")

    edit
    |> form("#poem-form",
      poem: %{title: "Changed title", body: String.replace(text, "\r\n", "\n")}
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
    {:ok, edit, _} = live(conn, ~p"/poems/#{saved.id}/edit")
    File.write!(saved.path, "outside words\n")

    html =
      edit
      |> form("#poem-form", poem: %{title: "Local", body: "local unsaved words"})
      |> render_submit()

    assert has_element?(edit, "#poem-problem", "changed on disk")
    assert has_element?(edit, "#poem-form[data-unsaved=true][data-save-blocked=true]")
    assert File.read!(saved.path) == "outside words\n"
    refute html =~ "Saved to your collection"
  end

  test "unavailable and replaced destinations never redirect a save", %{
    conn: conn,
    folder: folder,
    root: root
  } do
    {:ok, _} = Storage.set_folder(folder)
    {:ok, edit, _} = live(conn, ~p"/poems/new")
    File.rename!(folder, folder <> "-unavailable")
    edit |> form("#poem-form", poem: %{body: "held draft", title: ""}) |> render_submit()
    assert has_element?(edit, "#poem-problem", "unavailable")
    assert Storage.collection_location().folder == folder
    other = Path.join(root, "other-folder")
    File.mkdir!(other)
    {:ok, _} = Storage.set_folder(other)
    edit |> form("#poem-form", poem: %{body: "held draft", title: ""}) |> render_submit()
    assert has_element?(edit, "#poem-problem", "collection changed")
    refute File.exists?(Path.join(other, "poems"))
    edit |> element("#refresh-poem-folder") |> render_click()
    assert has_element?(edit, "#poem-destination", Path.join(other, "poems"))
    edit |> form("#poem-form", poem: %{body: "held draft", title: ""}) |> render_submit()
    {:ok, [saved]} = Poems.list(Storage.collection_location())
    assert saved.body == "held draft"
    assert String.starts_with?(saved.path, other <> "/")
  end

  test "recovery is explicit and reports unavailable browser storage", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/poems/new")
    render_hook(view, "poem_recovery_status", %{waiting: true})
    assert has_element?(view, "#poem-recovery")
    view |> element("#restore-poem-local") |> render_click()
    assert_push_event(view, "poem-restore-local", %{})
    render_hook(view, "poem_recovery_unavailable", %{})
    assert has_element?(view, "#poem-recovery-problem", "cannot keep a local recovery copy")
    assert Storage.collection_location().configured == false
  end
end
