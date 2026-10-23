defmodule StillWeb.SavedWritingTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Poems, Storage, Writing}
  alias Still.Writing.Entry

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "collection")
    File.mkdir_p!(folder)
    {:ok, _} = Storage.set_folder(folder)
    on_exit(fn -> Application.put_env(:still, :storage_state_directory, previous) end)
    %{folder: folder}
  end

  test "explicit Save writes exact title and body, then reopen, rename and revise preserve history",
       %{
         conn: conn,
         folder: folder
       } do
    {:ok, view, _} = live(conn, ~p"/writing/new")
    body = "\n  exact <words> & spaces\n\tsecond line\n\n"

    render_submit(element(view, "#file-writing-form"), %{
      "writing" => %{"title" => "Notes:", "body" => body}
    })

    assert {:ok, [saved]} = Poems.list(Storage.collection_location())
    assert saved.title == "Notes:"
    assert saved.body == body
    assert File.read!(saved.path) == body
    assert_patch(view, ~p"/writing/#{saved.id}/edit")

    {:ok, reopened, reopened_html} = live(conn, ~p"/writing/#{saved.id}/edit")

    assert [persisted] =
             reopened_html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#file-writing-body")
             |> LazyHTML.attribute("data-persisted")

    assert Jason.decode!(persisted) == %{"title" => "Notes:", "body" => body}

    renamed_body = body <> "last line\n"

    render_submit(element(reopened, "#file-writing-form"), %{
      "writing" => %{"title" => "Renamed notes", "body" => renamed_body}
    })

    assert {:ok, renamed} = Poems.get(Storage.collection_location(), saved.id)
    assert renamed.title == "Renamed notes"
    assert renamed.body == renamed_body

    assert renamed.path ==
             Path.join([folder, "poems", "Renamed notes -- #{saved.id}", "poem.txt"])

    assert {:ok, [revision]} = Poems.revisions(Storage.collection_location(), saved.id)
    assert revision.title == "Notes:" and revision.body == body
    assert Writing.list_entries() == []
  end

  test "a stale snapshot preserves both disk contents and the submitted local form", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/writing/new")

    render_submit(element(view, "#file-writing-form"), %{
      "writing" => %{"title" => "Before", "body" => "Original on disk"}
    })

    assert {:ok, [saved]} = Poems.list(Storage.collection_location())
    {:ok, stale, _} = live(conn, ~p"/writing/#{saved.id}/edit")
    File.write!(saved.path, "Changed outside Still")

    render_submit(element(stale, "#file-writing-form"), %{
      "writing" => %{"title" => "My local title", "body" => "My unsaved form"}
    })

    assert has_element?(stale, "#file-problem", "changed on disk")
    assert has_element?(stale, "#file-writing-form[data-save-blocked='true']")
    assert has_element?(stale, "#file-writing-form[data-unsaved='true']")
    assert File.read!(saved.path) == "Changed outside Still"
  end

  test "the saved shelf shows only file-backed writing, and trash requires confirmation", %{
    conn: conn
  } do
    historical = historical_entry("Historical Lists page")
    legacy_now = legacy_now_entry("Legacy Now page")
    {:ok, view, _} = live(conn, ~p"/writing/new")

    render_submit(element(view, "#file-writing-form"), %{
      "writing" => %{"title" => "Saved file", "body" => "Words kept as a file"}
    })

    assert {:ok, [saved]} = Poems.list(Storage.collection_location())
    {:ok, shelf, _} = live(conn, ~p"/writing")
    assert has_element?(shelf, "#saved-#{saved.id}", "Saved file")
    refute has_element?(shelf, "#saved-#{historical.id}")
    refute has_element?(shelf, "#saved-#{legacy_now.id}")
    refute has_element?(shelf, "#saved-#{historical.id}", "Historical Lists page")
    refute has_element?(shelf, "#saved-#{legacy_now.id}", "Legacy Now page")

    {:ok, read, _} = live(conn, ~p"/writing/#{saved.id}")
    element(read, "#delete-file") |> render_click()
    assert has_element?(read, "#delete-confirmation")
    assert has_element?(read, "#file-text", "Words kept as a file")
    element(read, "#confirm-delete-file") |> render_click()
    assert_redirect(read, ~p"/writing?trash=1")

    {:ok, trash, _} = live(conn, ~p"/writing?trash=1")
    assert has_element?(trash, "#saved-#{saved.id}", "Saved file")
    element(trash, "button", "Restore") |> render_click()
    assert has_element?(trash, "#writing-empty", "Nothing in Trash")
    {:ok, restored} = Poems.get(Storage.collection_location(), saved.id)
    assert restored.body == "Words kept as a file"

    {:ok, shelf, _} = live(conn, ~p"/writing")
    assert has_element?(shelf, "#saved-#{saved.id}", "Saved file")
    {:ok, read_again, _} = live(conn, ~p"/writing/#{saved.id}")
    element(read_again, "#delete-file") |> render_click()
    element(read_again, "#confirm-delete-file") |> render_click()
    {:ok, trash_again, _} = live(conn, ~p"/writing?trash=1")
    element(trash_again, "button", "Delete permanently…") |> render_click()
    assert has_element?(trash_again, "#purge-confirmation")
    assert {:ok, [trashed]} = Poems.list_trash(Storage.collection_location())
    assert trashed.id == saved.id
    element(trash_again, "#confirm-purge-file") |> render_click()
    assert has_element?(trash_again, "#writing-empty", "Nothing in Trash")

    assert {:ok, []} = Poems.list_trash(Storage.collection_location())
    refute File.exists?(saved.path)

    assert Writing.get_entry!(historical.id).body == historical.body
    assert Writing.get_entry!(legacy_now.id).body == legacy_now.body
  end

  test "a new blank file Save becomes Now without replacing the earlier saved page", %{conn: conn} do
    {:ok, first, _} = live(conn, ~p"/writing/new")

    render_submit(element(first, "#file-writing-form"), %{
      "writing" => %{"title" => "The desk's page", "body" => "Saved current words"}
    })

    assert {:ok, [saved]} = Poems.list(Storage.collection_location())

    {:ok, blank, _} = live(conn, ~p"/writing/new")
    assert editor_body(blank) == ""

    render_change(element(blank, "#file-writing-form"), %{
      "writing" => %{"title" => "", "body" => "Separate blank draft"}
    })

    render_submit(element(blank, "#file-writing-form"), %{
      "writing" => %{"title" => "A separate page", "body" => "Separate blank draft"}
    })

    assert {:ok, pieces} = Poems.list(Storage.collection_location())
    assert length(pieces) == 2
    new_saved = Enum.find(pieces, &(&1.id != saved.id))
    earlier_saved = Enum.find(pieces, &(&1.id == saved.id))
    assert new_saved.title == "A separate page"
    assert earlier_saved.id == saved.id
    assert earlier_saved.title == "The desk's page"
    assert earlier_saved.body == "Saved current words"

    {:ok, now, _} = live(conn, ~p"/")
    assert has_element?(now, "#file-writing-title[value='A separate page']")
    assert editor_body(now) == "Separate blank draft"
    assert Writing.list_entries() == []
  end

  defp editor_body(view) do
    view
    |> element("#file-writing-body")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
  end

  defp historical_entry(title) do
    %Entry{}
    |> Entry.changeset(%{
      origin: "before",
      title: title,
      body: "Historical words",
      notebook: "Early Notebooks/Lists 1",
      source_order: 1,
      source_key: Ecto.UUID.generate()
    })
    |> Still.Repo.insert!()
  end

  defp legacy_now_entry(title) do
    %Entry{}
    |> Entry.changeset(%{origin: "now", title: title, body: "Legacy words"})
    |> Still.Repo.insert!()
  end
end
