defmodule StillWeb.RoomLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Repo, Writing}
  alias Still.Writing.Entry

  test "changing the light persists across pages without changing writing", %{conn: conn} do
    body = "A line / another line\n\tand its branch"
    {:ok, entry} = Writing.save_entry(nil, body)
    {:ok, view, _html} = live(conn, ~p"/w/#{entry.id}")

    view |> element("#light-toggle") |> render_click()
    assert has_element?(view, "#room-light-angle[value='38']")

    view
    |> element("#room-light-form")
    |> render_change(%{"light" => %{"angle" => "214"}})

    assert Writing.room_light() == 214
    assert Writing.get_entry!(entry.id).body == body
    assert Writing.list_versions(entry) == []
    assert has_element?(view, "#writing-form textarea")

    {:ok, found, _html} = live(conn, ~p"/pages")
    found |> element("#light-toggle") |> render_click()
    assert has_element?(found, "#room-light-angle[value='214']")
  end

  test "invalid light values leave the light and current words intact", %{conn: conn} do
    {:ok, entry} = Writing.save_entry(nil, "The words already here")
    {:ok, view, _html} = live(conn, ~p"/w/#{entry.id}")
    view |> element("#light-toggle") |> render_click()

    render_change(view, "change_light", %{"light" => %{"angle" => "bright"}})
    render_change(view, "change_light", %{"light" => %{}})

    assert Writing.room_light() == 38
    assert Writing.get_entry!(entry.id).body == "The words already here"
    assert Writing.list_versions(entry) == []
    assert has_element?(view, "#room-light-angle[value='38']")
  end

  test "letters persist through writing, Before and Find without changing the words", %{
    conn: conn
  } do
    body = "A line / another line\n\tand its branch"
    {:ok, entry} = Writing.save_entry(nil, body)
    old = before("letters", "Early Notebooks/Lists 3", "These:Letters:", "Untouched before")
    {:ok, 214} = Writing.set_room_light(214)
    {:ok, view, _html} = live(conn, ~p"/w/#{entry.id}")

    view |> element("#letters-toggle") |> render_click()
    assert has_element?(view, "#room-letters-size[value='50'][min='0'][max='100']")
    assert has_element?(view, "#room-letters-size[aria-label='Change the size of the writing']")

    view
    |> element("#room-letters-form")
    |> render_change(%{"letters" => %{"size" => "23"}})

    assert_push_event(view, "letters-changed", %{size: 23})
    assert Writing.room_letters() == 23
    assert Writing.room_light() == 214
    assert has_element?(view, ".site-frame[style*='--letters: 0.23']")
    assert has_element?(view, "#writing-body")

    view |> element("#room-close") |> render_click()
    refute has_element?(view, "#room-letters-form")
    assert has_element?(view, "#writing-body")

    {:ok, read, _html} = live(conn, ~p"/w/#{old.id}")
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

  test "letters, light and place each open alone and invalid size leaves the room intact", %{
    conn: conn
  } do
    {:ok, entry} = Writing.save_entry(nil, "The words already here")
    {:ok, view, _html} = live(conn, ~p"/w/#{entry.id}")
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
    assert Writing.room_light() == 38
    assert has_element?(view, "#room-letters-size[value='50']")
    assert has_element?(view, ".site-frame[style*='--letters: 0.5']")

    view |> element("#landscape-toggle") |> render_click()
    refute has_element?(view, "#room-letters-form")
    assert has_element?(view, "#letters-toggle[aria-expanded='false']")
    assert has_element?(view, "#room-landscape")
    view |> element("#letters-toggle") |> render_click()
    refute has_element?(view, "#room-landscape")
    assert has_element?(view, "#writing-body")
    assert Writing.get_entry!(entry.id).body == "The words already here"
    assert Writing.list_versions(entry) == []
  end

  test "revealing the room keeps the editor mounted and only visits existing places", %{
    conn: conn
  } do
    before("one", "Early Notebooks/Lists 3", "A:Place:", "old words")
    before("two", "Early Notebooks/Lists 3", "Another:Place:", "other old words")
    {:ok, now} = Writing.save_entry(nil, "The page in the room")
    {:ok, view, _html} = live(conn, ~p"/w/#{now.id}")

    refute has_element?(view, "#room-landscape")
    view |> element("#landscape-toggle") |> render_click()

    assert has_element?(view, "#room-content[inert][aria-hidden='true'] #writing-form textarea")

    assert has_element?(
             view,
             "#room-landscape a[href='/notebooks?notebook=Early+Notebooks%2FLists+3']",
             "Lists 3"
           )

    assert has_element?(view, "#landscape-index[href='/notebooks']", "All notebooks")
    assert has_element?(view, "#landscape-now[href='/w/#{now.id}']", "Now")
    refute render(view) =~ "Lists 8"
    refute render(view) =~ "Early Notebooks/Lists 3"
    assert Writing.get_entry!(now.id).body == "The page in the room"

    view |> element("#room-close") |> render_click()
    refute has_element?(view, "#room-landscape")
    refute has_element?(view, "#room-content[inert]")
    assert has_element?(view, "#writing-form textarea")
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
    {:ok, _beside_view, _html} = live(conn, ~p"/?beside=#{parent.id}")

    assert Writing.current_writing() == nil
    assert Writing.current_beside().id == parent.id

    {:ok, found, _html} = live(conn, ~p"/pages")
    assert has_element?(found, "#return-to-writing[href='/?beside=#{parent.id}']")
    found |> element("#landscape-toggle") |> render_click()
    assert has_element?(found, "#landscape-now[href='/?beside=#{parent.id}']")

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
