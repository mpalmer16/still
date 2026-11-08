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

  test "new writing has a separate Scratch save and later edits stay there", %{
    conn: conn,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    {:ok, view, _} = live(conn, ~p"/?new=1")
    assert has_element?(view, "#save-scratch", "Save to scratch")

    render_submit(view, "save_file", %{
      "writing" => %{"body" => "A thought outside the notebook"},
      "scratch" => true
    })

    assert File.read!(Path.join(folder, "Scratch/A_thought_outside_the_notebook.txt")) ==
             "A thought outside the notebook"

    refute has_element?(view, "#save-scratch")
    assert has_element?(view, "#file-save-status", "Saved on this Mac")
  end

  test "a saved filename can be corrected from its reading details", %{conn: conn, folder: folder} do
    {:ok, _} = Storage.set_folder(folder)
    location = Storage.collection_location()

    {:ok, saved} =
      Poems.save(location, Poems.new(location), %{
        body: "Opening\n\nwords",
        relative_path: "Untitled.txt"
      })

    {:ok, view, _} = live(conn, ~p"/writing/#{saved.id}")
    view |> form("#rename-file-form", file: %{name: "Opening.txt"}) |> render_submit()
    assert has_element?(view, "#rename-file-name[value='Opening.txt']")
    assert render(view) =~ "File renamed"
    refute File.exists?(saved.path)
    assert File.read!(Path.join(folder, "Opening.txt")) == saved.body
  end

  test "editing from Wander can return to the same piece after saving", %{
    conn: conn,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    location = Storage.collection_location()
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "Original words"})

    wander_path = ~p"/w/#{saved.entry_id}?read=1"
    edit_path = ~p"/writing/#{saved.id}/edit?from=wander"
    {:ok, wander, _} = live(conn, wander_path)
    assert has_element?(wander, ~s(a[href="#{edit_path}"]), "Change these words")

    {:ok, edit, _} = live(conn, edit_path)
    assert has_element?(edit, ~s(#back-to-wander[href="#{wander_path}"]), "Back to Wander")

    render_submit(edit, "save_file", %{"writing" => %{"body" => "Revised words"}})
    assert_patch(edit, edit_path)
    assert has_element?(edit, "#read-file", "Save & return to Wander")

    render_submit(edit, "save_file", %{"writing" => %{"body" => "Final words"}, "read" => "true"})
    assert_redirect(edit, wander_path)
    {:ok, returned, _} = live(conn, wander_path)
    assert render(returned) =~ "Final words"
    assert File.read!(saved.path) == "Final words"
  end

  test "unchanged numbered metadata stays saved after the browser sends string values", %{
    conn: conn,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    {:ok, book} = Writing.create_notebook(%{label: "Synthetic notebook"})
    location = Storage.collection_location()
    body = "Title\n\n\tWords\n"

    {:ok, saved} =
      Poems.save(location, Poems.new(location), %{
        body: body,
        title_line: 1,
        notebook_id: book.id,
        list_label: "0000b",
        source_order: 0
      })

    {:ok, view, _} = live(conn, ~p"/writing/#{saved.id}/edit")

    attrs = %{
      "body" => body,
      "title" => "",
      "title_line" => "1",
      "notebook_id" => to_string(book.id),
      "list_label" => "0000b",
      "source_order" => "0",
      "relative_path" => saved.relative_path
    }

    render_change(element(view, "#file-writing-form"), %{"writing" => attrs})
    assert has_element?(view, "#file-writing-form[data-unsaved='false']")
    assert has_element?(view, "#file-save-status", "Saved on this Mac")
    render_click(view, "new_file", %{"writing" => attrs})
    assert_redirect(view, ~p"/?new=1")
    assert {:ok, []} = Poems.revisions(location, saved.id)
  end

  test "a title marks a line in the complete text without duplicating it", %{
    conn: conn,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    {:ok, view, _} = live(conn, ~p"/writing/new")
    assert has_element?(view, "#file-writing-body[wrap='soft']")
    assert has_element?(view, "#file-writing-title[value='']")
    assert has_element?(view, "#copy-file-edit button[aria-label='Copy text'][title='Copy text']")
    body = "  First words\n\n" <> String.duplicate("long line ", 80)
    view |> form("#file-writing-form", writing: %{body: body, title_line: "1"}) |> render_submit()
    {:ok, [saved]} = Poems.list(Storage.collection_location())
    assert saved.title_line == 1
    assert Poems.display_title(saved) == "First words"
    assert File.read!(saved.path) == body
    {:ok, shelf, _} = live(conn, ~p"/writing")
    assert has_element?(shelf, "#saved-#{saved.id} .file-piece-title", "First words")
    {:ok, edit, _} = live(conn, ~p"/writing/#{saved.id}/edit")
    assert has_element?(edit, "#file-writing-title[value='']")

    [payload] =
      edit
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#copy-file-edit")
      |> LazyHTML.attribute("data-persisted")

    assert %{"body" => ^body, "title_in_body" => true} = Jason.decode!(payload)

    assert Enum.any?(Writing.list_entries(), &(&1.file_id == saved.id and &1.body == body))
  end

  test "New protects the latest unsaved words and opens a blank page after Save", %{
    conn: conn,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    {:ok, view, _} = live(conn, ~p"/writing/new")
    assert has_element?(view, "#new-file", "New")

    # New receives the current input directly from the recovery hook, even before phx-change debounce.
    render_click(view, "new_file", %{"writing" => %{"body" => "Latest words", "title" => ""}})
    assert has_element?(view, "#file-save-status", "Save these words")
    assert {:ok, []} = Poems.list(nil)

    render_submit(element(view, "#file-writing-form"), %{
      "writing" => %{"body" => "Latest words", "title" => ""}
    })

    assert {:ok, [saved]} = Poems.list(nil)
    assert saved.body == "Latest words"
    render_click(view, "new_file", %{"writing" => %{"body" => "Typed after Save", "title" => ""}})
    assert has_element?(view, "#file-save-status", "Save these words")
    render_click(view, "new_file", %{"writing" => %{"body" => "Latest words", "title" => ""}})
    assert_redirect(view, ~p"/?new=1")
    {:ok, reopened} = Poems.get(nil, saved.id)
    assert reopened.body == "Latest words"
    {:ok, reading, _} = live(conn, ~p"/writing/#{saved.id}")
    assert has_element?(reading, "h1.sr-only", "Saved writing")
    assert has_element?(reading, "#file-text", "Latest words")
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
    assert File.ls!(folder) == []
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
    |> form("#file-writing-form", writing: %{body: text, title_line: "3"})
    |> render_submit()

    {:ok, [saved]} = Poems.list(Storage.collection_location())
    assert_patch(view, ~p"/writing/#{saved.id}/edit")
    assert File.read!(saved.path) == text
    {:ok, read, html} = live(conn, ~p"/writing/#{saved.id}")
    assert has_element?(read, "#file-text")
    refute has_element?(read, "h1.file-title")
    assert has_element?(read, "#file-title-meaning", "Line 3 in the text is marked as its title")
    assert has_element?(read, "#copy-file-reading button[type='button'][aria-label='Copy text']")

    [payload] =
      read
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#copy-file-reading")
      |> LazyHTML.attribute("data-persisted")

    assert %{"body" => ^text, "title_in_body" => true} = Jason.decode!(payload)

    assert html =~ "&lt;script&gt;fixture&lt;/script&gt;"
    refute html =~ "<script>fixture</script>"
    {:ok, library, _} = live(conn, ~p"/writing")
    assert has_element?(library, "#saved-#{saved.id}", "cobalt")
    assert has_element?(library, ".file-collection-note", folder)
    {:ok, edit, html} = live(conn, ~p"/writing/#{saved.id}/edit")
    assert html =~ "data-persisted"
    assert has_element?(edit, "#file-writing-body[data-draft-key]")
    assert Poems.get(Storage.collection_location(), saved.id) == {:ok, saved}
  end

  test "an empty page can later mark a line without moving it out of the text", %{
    conn: conn,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    {:ok, view, _} = live(conn, ~p"/?new=1")
    view |> form("#file-writing-form", writing: %{body: "", title: ""}) |> render_submit()
    {:ok, [saved]} = Poems.list(Storage.collection_location())
    assert saved.body == "" and saved.title_line == nil

    view
    |> form("#file-writing-form", writing: %{body: "Synthetic title\n", title_line: "1"})
    |> render_submit()

    {:ok, renamed} = Poems.get(Storage.collection_location(), saved.id)
    assert renamed.id == saved.id
    assert File.read!(renamed.path) == "Synthetic title\n"
    assert renamed.path == saved.path
    assert renamed.created_at == saved.created_at
    assert renamed.title_line == 1
    {:ok, read, _} = live(conn, ~p"/writing/#{saved.id}")
    refute has_element?(read, "#file-empty")
    assert has_element?(read, "#file-text", "Synthetic title")
    assert has_element?(read, "#file-revisions")
    {:ok, [earlier]} = Poems.revisions(Storage.collection_location(), saved.id)
    assert earlier.body == "" and earlier.title_line == nil
  end

  test "recording a title line preserves CRLF text and prior database writing", %{
    conn: conn,
    folder: folder
  } do
    {:ok, entry} = Writing.save_entry(nil, "Synthetic list words")
    {:ok, _} = Writing.remember_writing(entry)
    before = Writing.current_writing()
    {:ok, _} = Storage.set_folder(folder)
    location = Storage.collection_location()
    text = "\r\n\tfirst stanza\r\n\r\nlast  \r\n"
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: text, title_line: nil})
    {:ok, edit, _} = live(conn, ~p"/writing/#{saved.id}/edit")

    edit
    |> form("#file-writing-form",
      writing: %{title_line: "2", body: String.replace(text, "\r\n", "\n")}
    )
    |> render_submit()

    {:ok, renamed} = Poems.get(location, saved.id)
    assert File.read!(renamed.path) == text
    assert renamed.title_line == 2
    assert Writing.current_writing() == before
    assert Enum.any?(Writing.list_entries(), &(&1.id == entry.id))
    assert Enum.any?(Writing.list_entries(), &(&1.file_id == saved.id and &1.body == text))
    assert Writing.list_versions(entry) == []
  end

  test "an externally changed title line must be chosen again before it is marked", %{
    conn: conn,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    location = Storage.collection_location()
    body = "Old heading\n\ntext"
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: body, title_line: 1})
    File.write!(saved.path, "New heading\n\ntext")

    assert {:ok, refreshed} = Poems.get(location, saved.id)
    assert refreshed.title_needs_review
    {:ok, edit, _html} = live(conn, ~p"/writing/#{saved.id}/edit")
    assert has_element?(edit, "#file-title-line[value='']")
    assert has_element?(edit, "#file-writing-form", "Choose a line again")

    edit
    |> form("#file-writing-form", writing: %{body: "New heading\n\ntext", title_line: ""})
    |> render_submit()

    assert {:ok, saved_again} = Poems.get(location, saved.id)
    assert saved_again.body == "New heading\n\ntext"
    assert saved_again.title_line == nil
  end

  test "external edits refuse overwrite and keep local submitted words available", %{
    conn: conn,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    location = Storage.collection_location()
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "before", title_line: nil})
    {:ok, edit, _} = live(conn, ~p"/writing/#{saved.id}/edit")
    File.write!(saved.path, "outside words\n")

    html =
      edit
      |> form("#file-writing-form", writing: %{title_line: "", body: "local unsaved words"})
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
    assert File.ls!(other) == []
    edit |> element("#refresh-file-folder") |> render_click()
    assert has_element?(edit, "#file-save-destination", other)

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
