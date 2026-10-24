defmodule StillWeb.HistoricalSavedWritingLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Poems, Storage, Writing}

  @moduletag :tmp_dir
  setup %{tmp_dir: root} do
    old = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "collection")
    File.mkdir_p!(folder)
    {:ok, _} = Storage.set_folder(folder)

    {:ok, entry} =
      insert_entry(%{
        origin: "before",
        source_key: "synthetic-promotion",
        title: "The:Cedars:",
        body: "The cedars\n\n  keep a quiet line",
        notebook: "Early Notebooks/Lists 2"
      })

    on_exit(fn -> Application.put_env(:still, :storage_state_directory, old) end)
    %{entry: entry, location: Storage.collection_location()}
  end

  test "historical reading explicitly opens one editable saved version with a changeable title",
       %{conn: conn, entry: entry, location: location} do
    {:ok, reading, _} = live(conn, ~p"/w/#{entry.id}?read=1")
    render_click(element(reading, "#add-to-saved-writing"))
    assert {:ok, [piece]} = Poems.list(location)
    assert_redirect(reading, ~p"/writing/#{piece.id}/edit")
    {:ok, editor, _} = live(conn, ~p"/writing/#{piece.id}/edit")
    assert has_element?(editor, "#file-writing-title[value='The:Cedars:']")
    assert render(element(editor, "#file-writing-body")) =~ entry.body

    render_submit(element(editor, "#file-writing-form"), %{
      "writing" => %{"title" => "The Cedars", "body" => entry.body}
    })

    assert {:ok, renamed} = Poems.get(location, piece.id)
    assert renamed.title == "The Cedars"
    assert Writing.get_entry!(entry.id).title == entry.title
    {:ok, again, _} = live(conn, ~p"/w/#{entry.id}?read=1")
    render_click(element(again, "#add-to-saved-writing"))
    assert_redirect(again, ~p"/writing/#{piece.id}/edit")
    assert {:ok, [_]} = Poems.list(location)
    {:ok, saved, _} = live(conn, ~p"/writing/#{piece.id}")
    assert has_element?(saved, "#historical-writing-source", "Early Notebooks · Lists 2")
    assert has_element?(saved, ".file-title", "The Cedars")
  end

  test "missing destination explains setup without modifying the original", %{
    conn: conn,
    entry: entry,
    location: location
  } do
    before = Writing.get_entry!(entry.id)
    {:ok, _} = Storage.clear_folder()
    {:ok, reading, _} = live(conn, ~p"/w/#{entry.id}?read=1")
    render_click(element(reading, "#add-to-saved-writing"))
    assert render(reading) =~ "Choose a collection folder before saving writing."
    assert Writing.get_entry!(entry.id).body == before.body
    assert Writing.get_entry!(entry.id).title == before.title
    assert {:error, _} = Poems.list(location)
  end

  defp insert_entry(attrs),
    do: Still.Repo.insert(Writing.change_entry(Writing.new_entry(), attrs))
end
