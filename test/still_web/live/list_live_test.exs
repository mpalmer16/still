defmodule StillWeb.ListLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.Writing

  test "a new List begins in the same empty writing surface, with no empty saved object", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/list")
    assert has_element?(view, "#writing-title")
    assert has_element?(view, "#writing-body[data-draft-scope='list']")
    refute has_element?(view, ".threshold-room")
    assert Writing.list_entries() == []

    render_change(element(view, "#writing-form"), %{
      "entry" => %{"title" => "Quiet things", "body" => ""}
    })

    assert Writing.list_entries() == []

    render_change(element(view, "#writing-form"), %{
      "entry" => %{
        "title" => "Quiet things",
        "body" => "rain: furnace:\nexcept sometimes it isn't quiet"
      }
    })

    [entry] = Writing.list_entries()
    assert entry.title == "Quiet things"
    assert entry.body == "rain: furnace:\nexcept sometimes it isn't quiet"
    assert Writing.list_entry?(entry)

    {:ok, returned, _} = live(conn, ~p"/w/#{entry.id}")
    assert has_element?(returned, "#writing-title[value='Quiet things']")
  end

  test "accepting a pasted title submits the latest words and retains the complete paste", %{
    conn: conn
  } do
    raw =
      "When everything is quiet\n\nrain: furnace:\n\tdog upstairs:\nexcept sometimes it isn't quiet"

    {:ok, view, _} = live(conn, ~p"/list")
    render_change(element(view, "#writing-form"), %{"entry" => %{"title" => "", "body" => raw}})
    assert has_element?(view, "#list-interpretation button", "Use first line as title")
    [entry] = Writing.list_entries()

    latest = raw <> "\n<the house at 4am>"

    render_submit(element(view, "#writing-form"), %{
      "entry" => %{"title" => "", "body" => latest, "interpret" => "title"}
    })

    saved = Writing.get_entry!(entry.id)
    assert saved.title == "When everything is quiet"

    assert saved.body ==
             "rain: furnace:\n\tdog upstairs:\nexcept sometimes it isn't quiet\n<the house at 4am>"

    assert has_element?(view, "#writing-body")
    refute has_element?(view, "#list-interpretation")
    assert Enum.any?(Writing.list_versions(saved), &(&1.body == latest))

    saved_body = saved.body
    saved_title = saved.title

    assert_push_event(view, "replace-writing", %{
      body: ^saved_body,
      title: ^saved_title,
      only_if_current: true
    })
  end

  test "a first-submit interpretation saves the raw text before extracting a title", %{conn: conn} do
    raw = "Things in the morning\n\nwater: waiting:"
    {:ok, view, _} = live(conn, ~p"/list")

    render_submit(element(view, "#writing-form"), %{
      "entry" => %{"title" => "", "body" => raw, "interpret" => "title"}
    })

    [entry] = Writing.list_entries()
    assert entry.title == "Things in the morning"
    assert entry.body == "water: waiting:"
    assert [%{body: ^raw, title: nil}] = Writing.list_versions(entry)
    assert_patch(view, ~p"/w/#{entry.id}")
    assert has_element?(view, "#writing-body")
  end

  test "an unfinished List keeps its own return and browser recovery scope", %{conn: conn} do
    {:ok, _view, _} = live(conn, ~p"/list")
    assert Writing.current_list_draft?()
    {:ok, find, _} = live(conn, ~p"/pages")
    assert has_element?(find, "#return-to-writing[href='/list?resume=1']")
    {:ok, returned, _} = live(conn, ~p"/list?resume=1")
    assert has_element?(returned, "#writing-body[data-draft-scope='list']")
    assert Writing.list_entries() == []
  end

  test "a List beside another piece retains both intent and its separate recovery scope", %{
    conn: conn
  } do
    {:ok, parent} = Writing.save_entry(nil, "The words alongside")
    {:ok, draft, _} = live(conn, ~p"/list?beside=#{parent.id}")
    assert has_element?(draft, "#writing-body[data-draft-scope='list:beside:#{parent.id}']")
    {:ok, find, _} = live(conn, ~p"/pages")
    assert has_element?(find, "#return-to-writing[href='/list?beside=#{parent.id}&resume=1']")
  end

  test "the interpreted words are retained before later unsent words autosave", %{conn: conn} do
    raw = "Things in the morning\n\nwater: waiting:"
    {:ok, view, _} = live(conn, ~p"/list")

    render_submit(element(view, "#writing-form"), %{
      "entry" => %{"title" => "", "body" => raw, "interpret" => "title"}
    })

    [interpreted] = Writing.list_entries()

    render_change(element(view, "#writing-form"), %{
      "entry" => %{"title" => "", "body" => raw <> " more words"}
    })

    current = Writing.get_entry!(interpreted.id)
    assert current.body == raw <> " more words"

    assert Enum.any?(
             Writing.list_versions(current),
             &(&1.title == interpreted.title && &1.body == interpreted.body)
           )

    assert Enum.any?(Writing.list_versions(current), &(&1.body == raw))
  end

  test "a stale title acceptance keeps the new window and offers the complete older paste", %{
    conn: conn
  } do
    raw = "Quiet things\n\nrain: furnace:"
    {:ok, entry} = Writing.save_entry(nil, raw, writing_form: "list")
    {:ok, view, _} = live(conn, ~p"/w/#{entry.id}")
    {:ok, current} = Writing.save_entry(entry, "Someone else's current words", checkpoint: true)

    render_submit(element(view, "#writing-form"), %{
      "entry" => %{"title" => "", "body" => raw, "interpret" => "title"}
    })

    assert has_element?(view, "#stale-notice", "Your unsaved words are safe")
    assert Writing.get_entry!(entry.id).body == current.body
    element(view, "#stale-notice button") |> render_click()
    assert Enum.any?(Writing.list_entries(), &(&1.body == raw && Writing.list_entry?(&1)))
  end
end
