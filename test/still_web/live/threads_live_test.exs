defmodule StillWeb.ThreadsLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Desk, Poems, Repo, Storage, Writing}
  alias Still.Writing.Entry
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    folder = Path.join(root, "collection")
    File.mkdir!(folder)
    {:ok, _} = Storage.set_folder(folder)
    %{location: Storage.collection_location(), folder: folder}
  end

  test "a word crosses old and saved writing, unfolds whole pages, and leaves every word and cursor intact",
       %{conn: conn, location: location} do
    old =
      historical(
        "Window:Rain:",
        "\tA window remembers <script>rain</script>  \n\nAn untouched ending.\n"
      )

    {:ok, piece} =
      Poems.save(location, Poems.new(location), %{
        title: "A newer window",
        body: "  At the window, another day.  \r\n\r\nThe last line stays.\r\n"
      })

    :ok = Desk.remember(location, %{id: piece.id, saved: true, beside: nil})
    {:ok, cursor} = Desk.current(location)
    {:ok, arrival, _} = live(conn, ~p"/threads")
    assert has_element?(arrival, ".thread-word", "window")
    assert has_element?(arrival, "#thread-crossing")
    {:ok, view, html} = live(conn, ~p"/threads?word=window")
    assert has_element?(view, "#open-threads[aria-current=page]")
    assert has_element?(view, "#thread-left", "Window:Rain:")
    assert has_element?(view, "#thread-right", "A newer window")
    assert has_element?(view, "#thread-left mark", "window")
    assert html =~ "&lt;script&gt;rain&lt;/script&gt;"
    refute has_element?(view, "#thread-crossing script")
    refute has_element?(view, "#thread-crossing", "An untouched ending.")
    view |> element("#thread-whole-pages") |> render_click()
    assert has_element?(view, "#thread-crossing", "An untouched ending.")
    assert has_element?(view, "#thread-crossing", "The last line stays.")
    assert has_element?(view, "#thread-left a[href='/w/#{old.id}?read=1']")
    assert has_element?(view, "#thread-right a[href='/writing/#{piece.id}']")
    view |> element("#thread-passages") |> render_click()
    refute has_element?(view, "#thread-crossing", "An untouched ending.")
    assert Writing.get_entry!(old.id) == old
    assert Writing.list_versions(old) == []
    assert Poems.get(location, piece.id) == {:ok, piece}
    assert Poems.revisions(location, piece.id) == {:ok, []}
    assert Desk.current(location) == {:ok, cursor}
  end

  test "following a page starts with its recurring words and can follow a new exact word", %{
    conn: conn
  } do
    a = historical("First", "window orchard")
    historical("Second", "window river")
    historical("Third", "river orchard")
    {:ok, view, _} = live(conn, ~p"/threads?from=#{"before:#{a.id}"}")
    assert has_element?(view, ".thread-word", "window")
    assert has_element?(view, ".thread-word", "orchard")
    refute has_element?(view, ".thread-word", "river")
    view |> form("#thread-word-form", thread: %{word: "two words"}) |> render_submit()
    assert has_element?(view, "#thread-input-problem", "Choose one word")
    view |> form("#thread-word-form", thread: %{word: "RIVER"}) |> render_submit()
    assert has_element?(view, "#thread-word-heading h2", "river")
    assert has_element?(view, "#thread-crossing")
  end

  test "an empty collection, unmatched word, and missing source are honest quiet states", %{
    conn: conn
  } do
    {:ok, empty, _} = live(conn, ~p"/threads")
    assert has_element?(empty, "#threads-empty", "As you keep pages")
    refute has_element?(empty, "#thread-crossing")
    historical("Elsewhere", "windowsills quietly gather")
    {:ok, missing, _} = live(conn, ~p"/threads?word=window&from=before:999999")
    assert has_element?(missing, "#threads-source-missing")
    assert has_element?(missing, "#threads-empty", "That word is quiet here")
    refute has_element?(missing, "#thread-crossing")
  end

  test "a broken selected folder stays visible while historical words remain readable", %{
    conn: conn,
    folder: folder
  } do
    historical("First", "window rain")
    historical("Second", "window light")
    File.rm_rf!(folder)
    {:ok, view, _} = live(conn, ~p"/threads?word=window")
    assert has_element?(view, "#threads-problem[role=alert]")
    assert has_element?(view, "#thread-crossing")
    refute File.exists?(folder)
  end

  defp historical(title, body) do
    Repo.insert!(
      Entry.changeset(%Entry{}, %{
        origin: "before",
        title: title,
        body: body,
        notebook: "Synthetic notebook",
        source_key: Ecto.UUID.generate()
      })
    )
  end
end
