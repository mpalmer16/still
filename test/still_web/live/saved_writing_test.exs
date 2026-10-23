defmodule StillWeb.SavedWritingTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Repo, Writing}
  alias Still.Writing.Entry

  test "Save keeps the latest complete writing in the editor and it can be reopened", %{
    conn: conn
  } do
    {:ok, write, html} = live(conn, ~p"/list")
    assert html =~ "Autosaves as you write"
    assert has_element?(write, "#save-writing[name='entry[action]'][value='save']")
    assert has_element?(write, "#open-saved-writing[href='/pages?written=1']")
    body = "A fresh thought\n\tand a branch\n  <words> & their spaces"

    write
    |> element("#writing-form")
    |> render_submit(%{"entry" => %{"action" => "save", "title" => "Notes:", "body" => body}})

    [entry] = Writing.list_entries(origin: "now")
    assert entry.body == body
    assert entry.title == "Notes:"
    assert_patch(write, ~p"/w/#{entry.id}")
    assert has_element?(write, "#writing-body")
    assert has_element?(write, ".saved-status", "Saved on this Mac")
    assert Writing.list_versions(entry) == []

    {:ok, saved, _} = live(conn, ~p"/pages?written=1")
    assert has_element?(saved, "h1", "Saved writing.")
    assert has_element?(saved, ".entry-row[href='/w/#{entry.id}?written=1']", "Notes:")
    {:ok, reopened, _} = live(conn, ~p"/w/#{entry.id}?written=1")

    assert reopened
           |> element("#writing-body")
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.text() == body

    assert Writing.get_entry!(entry.id) == entry
    assert has_element?(reopened, ".saved-status", "Saved on this Mac")
    assert Writing.current_writing().id == entry.id
    assert Writing.list_versions(entry) == []
  end

  test "Saved writing includes recent work and edited Lists while preserving notebook order", %{
    conn: conn
  } do
    untouched = before("An untouched source", 0)
    old = before("A changed source", 100)
    {:ok, now} = Writing.save_entry(nil, "A recent notebook about rain")
    {:ok, changed} = Writing.save_entry(old, "A revised notebook about rain", checkpoint: true)
    assert Enum.map(Writing.find_entries(scope: :saved), & &1.entry.id) == [changed.id, now.id]
    assert Writing.notebook_neighbors(changed).previous.id == untouched.id
    {:ok, saved, _} = live(conn, ~p"/pages?written=1")
    refute has_element?(saved, ".entry-row", "An untouched source")
    assert has_element?(saved, ".entry-row", "A changed source")

    saved
    |> element("#search-form")
    |> render_change(%{"search" => %{"query" => "rain notebook", "written" => "true"}})

    assert_patch(saved, ~p"/pages?#{[q: "rain notebook", written: "1"]}")
    assert has_element?(saved, ".entry-row[href*='written=1'] mark", "rain")
    assert has_element?(saved, "#saved-writing[aria-current='page']")
    assert Writing.get_entry!(untouched.id) == untouched
    assert length(Writing.list_versions(changed)) == 1
  end

  test "a stale explicit Save keeps the newer writing and offers to preserve both", %{conn: conn} do
    {:ok, original} = Writing.save_entry(nil, "Original")
    {:ok, stale, _} = live(conn, ~p"/w/#{original.id}")
    {:ok, newer} = Writing.save_entry(original, "Changed elsewhere", checkpoint: true)

    stale
    |> element("#writing-form")
    |> render_submit(%{"entry" => %{"action" => "save", "body" => "My unsent words"}})

    assert has_element?(stale, "#stale-notice", "Keep both pages")
    assert has_element?(stale, "#writing-form[data-save-blocked='true']")
    assert Writing.get_entry!(original.id) == newer
    assert Writing.list_entries() |> length() == 1
  end

  test "an empty saved collection offers writing without inventing pages or history", %{
    conn: conn
  } do
    {:ok, saved, _} = live(conn, ~p"/pages?written=1")
    assert has_element?(saved, ".archive-empty", "Your writing will be here")
    refute has_element?(saved, ".entry-row")
    refute has_element?(saved, ".room-grain")
    assert Writing.list_entries() == []
  end

  defp before(title, position) do
    %Entry{}
    |> Entry.changeset(%{
      origin: "before",
      title: title,
      body: "Original words of #{title}",
      notebook: "Early Notebooks/Lists 1",
      source_order: position
    })
    |> Repo.insert!()
  end
end
