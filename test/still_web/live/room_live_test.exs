defmodule StillWeb.RoomLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Repo, Writing}
  alias Still.Writing.{Appearance, Entry}

  @tag :tmp_dir
  test "the writing menu keeps controls off the page and returns focus without changing words", %{
    conn: conn,
    tmp_dir: root
  } do
    folder = Path.join(root, "writing")
    File.mkdir_p!(folder)
    {:ok, _} = Still.Storage.set_folder(folder)
    location = Still.Storage.collection_location()
    body = "Still here\n\tincluding these spaces  \n"

    {:ok, piece} =
      Still.Writing.Files.save(location, Still.Writing.Files.new(location), %{body: body})

    {:ok, view, _} = live(conn, ~p"/writing/#{piece.id}/edit")
    assert has_element?(view, "#writing-menu-toggle[aria-haspopup=dialog]", "Menu")
    assert has_element?(view, "#writing-menu[hidden]")
    refute has_element?(view, ".room-light-control")
    refute has_element?(view, "#file-writing-form .file-writing-footer")
    assert has_element?(view, "#writing-menu #save-file[form=file-writing-form]")
    assert has_element?(view, "#writing-menu #file-relative-path[form=file-writing-form]")

    assert has_element?(
             view,
             "#writing-menu #copy-file-edit[data-body-selector='#file-writing-body']"
           )

    view |> element("#writing-menu-toggle") |> render_click()
    assert has_element?(view, "#writing-menu[role=dialog][aria-modal=true]:not([hidden])")
    assert has_element?(view, "#room-content[inert][aria-hidden=true]")
    assert_push_event(view, "room-focus", %{id: "writing-menu-close", clear_return: true})
    view |> element("#light-toggle") |> render_click()
    assert has_element?(view, "#writing-menu #room-light-form select#room-color")
    assert_push_event(view, "room-focus", %{id: "room-color"})

    view
    |> form("#room-light-form", appearance: %{color: "sepia"})
    |> render_change()

    assert has_element?(view, ".writing-frame[data-color=sepia]")
    assert has_element?(view, "#room-content[inert] #file-writing-body")
    assert has_element?(view, "#writing-menu:not([hidden])")
    view |> element("#writing-menu-close") |> render_click()
    assert has_element?(view, "#writing-menu[hidden]")
    refute has_element?(view, "#room-content[inert]")
    assert_push_event(view, "room-focus", %{id: "file-writing-body", clear_return: true})
    assert File.read!(piece.path) == body
    assert {:ok, []} = Still.Writing.Files.revisions(location, piece.id)
  end

  @tag :tmp_dir
  test "page width is remembered without changing words and remains separate from Letters", %{
    conn: conn,
    tmp_dir: root
  } do
    folder = Path.join(root, "writing")
    File.mkdir_p!(folder)
    {:ok, _} = Still.Storage.set_folder(folder)
    location = Still.Storage.collection_location()
    body = "An opening\n\tand its branch\n"

    {:ok, piece} =
      Still.Writing.Files.save(location, Still.Writing.Files.new(location), %{body: body})

    old =
      before(
        "room-width",
        "Early Notebooks/Lists 3",
        "A:Remembered:Page:",
        "Earlier notebook words"
      )

    {:ok, view, _} = live(conn, ~p"/writing/#{piece.id}/edit")
    view |> element("#page-width-toggle") |> render_click()
    assert has_element?(view, "#room-page-width[min='560'][max='1600']")
    view |> form("#room-page-form", page: %{width: "1400"}) |> render_change()
    assert Still.Writing.Appearance.width() == 1400
    assert has_element?(view, ".site-frame[style*='--page-width: 1400px']")
    assert File.read!(piece.path) == body

    {:ok, reader, _} = live(conn, ~p"/read/#{piece.entry_id}")
    assert has_element?(reader, ".site-frame[style*='--page-width: 1400px']")
    assert render(reader) =~ "An opening"
    assert Writing.get_entry!(piece.entry_id).body == body
    assert Writing.list_versions(Writing.get_entry!(piece.entry_id)) == []

    {:ok, wander, _} = live(conn, ~p"/w/#{piece.entry_id}")
    assert has_element?(wander, ".site-frame[style*='--page-width: 1400px']")
    assert render(wander) =~ "An opening"

    {:ok, notebook, _} = live(conn, ~p"/notebooks/read/#{old.id}")
    assert has_element?(notebook, ".site-frame[style*='--page-width: 1400px']")
    assert render(notebook) =~ "Earlier notebook words"
    assert Writing.get_entry!(old.id).body == "Earlier notebook words"
    assert Writing.list_versions(old) == []

    view |> element("#letters-toggle") |> render_click()
    refute has_element?(view, "#room-page-form")
    assert Still.Writing.Appearance.width() == 1400
    assert Writing.room_letters() == 50
    {:ok, reopened, _} = live(conn, ~p"/writing/#{piece.id}/edit")
    assert has_element?(reopened, ".site-frame[style*='--page-width: 1400px']")

    for invalid <- ["bad", "0.2", "-1", "559", "1601"] do
      render_change(reopened, "change_width", %{"page" => %{"width" => invalid}})
      assert Still.Writing.Appearance.width() == 1400
    end

    render_click(reopened, "reset_width", %{})
    assert Still.Writing.Appearance.width() == 0
    refute has_element?(reopened, ".site-frame[style*='--page-width:']")
    assert File.read!(piece.path) == body
    assert {:ok, []} = Still.Writing.Files.revisions(location, piece.id)
  end

  test "changing the color persists across writing, Find, Saved writing, and notebooks", %{
    conn: conn
  } do
    body = "A line / another line\n\tand its branch"
    {:ok, entry} = Writing.save_entry(nil, body)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ".writing-frame[data-color=graphite]")
    view |> element("#light-toggle", "Color") |> render_click()
    assert has_element?(view, "select#room-color option[value=graphite][selected]", "Graphite")
    refute has_element?(view, "#room-light-form input[type=range]")

    for {color, label} <- [
          {"sepia", "Sepia"},
          {"blue", "Night blue"},
          {"forest", "Forest"},
          {"plum", "Plum"},
          {"light", "Light"}
        ] do
      assert has_element?(view, "#room-color option[value=#{color}]", label)

      view
      |> form("#room-light-form", appearance: %{color: color})
      |> render_change()

      assert has_element?(view, ".writing-frame[data-color=#{color}]")
      assert has_element?(view, "#room-color option[value=#{color}][selected]")
    end

    assert Appearance.color() == "light"
    assert Writing.get_entry!(entry.id).body == body
    assert Writing.list_versions(entry) == []
    assert has_element?(view, "#file-writing-form textarea")

    {:ok, found, _html} = live(conn, ~p"/pages")
    found |> element("#light-toggle") |> render_click()
    assert has_element?(found, "#room-color option[value=light][selected]")

    {:ok, saved, _html} = live(conn, ~p"/writing")
    assert has_element?(saved, ".writing-frame[data-color=light]")

    {:ok, notebooks, _html} = live(conn, ~p"/notebooks")
    assert has_element?(notebooks, ".writing-frame[data-color=light]")
  end

  test "invalid color values leave the chosen color and current words intact", %{conn: conn} do
    {:ok, entry} = Writing.save_entry(nil, "The words already here")
    {:ok, _} = Appearance.set_color("sepia")
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#light-toggle") |> render_click()

    render_change(view, "change_room_color", %{"appearance" => %{"color" => "bright"}})
    render_change(view, "change_room_color", %{"appearance" => %{}})

    assert Appearance.color() == "sepia"
    assert has_element?(view, ".writing-frame[data-color=sepia]")
    assert has_element?(view, "#room-color option[value=sepia][selected]")
    assert Writing.get_entry!(entry.id).body == "The words already here"
    assert Writing.list_versions(entry) == []
  end

  test "letters persist through writing, Before and Find without changing the words", %{
    conn: conn
  } do
    body = "A line / another line\n\tand its branch"
    {:ok, entry} = Writing.save_entry(nil, body)
    old = before("letters", "Early Notebooks/Lists 3", "These:Letters:", "Untouched before")
    {:ok, _} = Appearance.set_color("forest")
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#letters-toggle") |> render_click()
    assert has_element?(view, "#room-letters-size[value='50'][min='0'][max='100']")
    assert has_element?(view, "#room-letters-size[aria-label='Change the size of the writing']")

    view
    |> element("#room-letters-form")
    |> render_change(%{"letters" => %{"size" => "23"}})

    assert_push_event(view, "letters-changed", %{size: 23})
    assert Writing.room_letters() == 23
    assert Appearance.color() == "forest"
    assert has_element?(view, ".site-frame[style*='--letters: 0.23']")
    assert has_element?(view, "#file-writing-body")

    view |> element("#room-close") |> render_click()
    refute has_element?(view, "#room-letters-form")
    assert has_element?(view, "#file-writing-body")

    {:ok, read, _html} = live(conn, ~p"/w/#{old.id}")
    assert has_element?(read, ".writing-frame[data-color=forest]")
    assert has_element?(read, ".site-frame[style*='--letters: 0.23']")
    read |> element("#letters-toggle") |> render_click()
    assert has_element?(read, "#room-letters-size[value='23']")

    {:ok, found, _html} = live(conn, ~p"/pages")
    assert has_element?(found, ".site-frame[style*='--letters: 0.23']")
    found |> element("#letters-toggle") |> render_click()
    assert has_element?(found, "#room-letters-size[value='23']")
    assert Writing.get_entry!(entry.id).body == body
    assert Writing.get_entry!(old.id).body == "Untouched before"
    assert Writing.list_versions(entry) == []
    assert Writing.list_versions(old) == []
  end

  test "Letters, Color and the room map open separately and invalid size leaves the room intact",
       %{
         conn: conn
       } do
    {:ok, entry} = Writing.save_entry(nil, "The words already here")
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#light-toggle") |> render_click()
    assert has_element?(view, "#room-light-form")
    view |> element("#letters-toggle") |> render_click()
    refute has_element?(view, "#room-light-form")
    assert has_element?(view, "#letters-toggle[aria-expanded='true']")

    for value <- ["large", "50.5", "50px", nil, %{}] do
      render_change(view, "change_letters", %{"letters" => %{"size" => value}})
    end

    render_change(view, "change_letters", %{"letters" => %{}})
    assert Writing.room_letters() == 50
    assert Appearance.color() == "graphite"
    assert has_element?(view, "#room-letters-size[value='50']")
    assert has_element?(view, ".site-frame[style*='--letters: 0.5']")

    view |> element("#landscape-toggle") |> render_click()
    refute has_element?(view, "#room-letters-form")
    assert has_element?(view, "#letters-toggle[aria-expanded='false']")
    assert has_element?(view, "#room-landscape")
    view |> element("#letters-toggle") |> render_click()
    refute has_element?(view, "#room-landscape")
    assert has_element?(view, "#file-writing-body")
    assert Writing.get_entry!(entry.id).body == "The words already here"
    assert Writing.list_versions(entry) == []
  end

  test "revealing the room keeps the editor mounted and only visits existing places", %{
    conn: conn
  } do
    before("one", "Early Notebooks/Lists 3", "A:Place:", "old words")
    before("two", "Early Notebooks/Lists 3", "Another:Place:", "other old words")
    {:ok, now} = Writing.save_entry(nil, "The page in the room")
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#room-landscape")
    view |> element("#landscape-toggle") |> render_click()

    assert has_element?(
             view,
             "#room-content[inert][aria-hidden='true'] #file-writing-form textarea"
           )

    assert has_element?(
             view,
             "#room-landscape a[href='/notebooks?notebook=Early+Notebooks%2FLists+3']",
             "Lists 3"
           )

    assert has_element?(view, "#landscape-index[href='/notebooks']", "All notebooks")
    assert has_element?(view, "#landscape-now[href='/']", "Write")
    refute render(view) =~ "Lists 8"
    refute render(view) =~ "Early Notebooks/Lists 3"
    assert Writing.get_entry!(now.id).body == "The page in the room"

    view |> element("#room-close") |> render_click()
    refute has_element?(view, "#room-landscape")
    refute has_element?(view, "#room-content[inert]")
    assert has_element?(view, "#file-writing-form textarea")
    assert Writing.list_versions(now) == []
  end

  test "an empty room opens straight into writing without fabricated notebook places", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#landscape-toggle") |> render_click()

    assert has_element?(view, "#landscape-now[href='/']")
    refute has_element?(view, "#room-landscape .landscape-place:not(.landscape-now)")
    assert Writing.list_entries() == []
  end

  test "Now returns to an unsaved beside page after leaving through Find or the landscape", %{
    conn: conn
  } do
    parent = before("parent", "Early Notebooks/Lists 3", "The:Words:Before:", "words from before")
    {:ok, previous} = Writing.save_entry(nil, "A different saved page")
    {:ok, _previous_view, _html} = live(conn, ~p"/w/#{previous.id}")
    {:ok, beside_view, _html} = live(conn, ~p"/?beside=#{parent.id}")

    render_change(element(beside_view, "#file-writing-form"), %{
      "writing" => %{"body" => "Unfinished words beside the earlier page"}
    })

    assert {:ok, %{saved: false, beside: beside_id}} =
             Still.Desk.current(Still.Storage.collection_location())

    assert beside_id == parent.id
    {:ok, found, _html} = live(conn, ~p"/pages")
    assert has_element?(found, "#return-to-writing[href='/']")
    found |> element("#landscape-toggle") |> render_click()
    assert has_element?(found, "#landscape-now[href='/']")
    {:ok, returned, _} = live(conn, ~p"/")
    assert has_element?(returned, ".beside-title", parent.title)

    assert length(Writing.list_entries()) == 2
    assert Writing.get_entry!(previous.id).body == "A different saved page"
    assert Writing.get_entry!(parent.id).body == "words from before"
  end

  defp before(key, notebook, title, body) do
    %Entry{}
    |> Entry.changeset(%{
      source_key: key,
      source_group: key,
      notebook: notebook,
      source_order: 0,
      origin: "before",
      title: title,
      body: body
    })
    |> Repo.insert!()
  end
end
