defmodule StillWeb.FocusedReadingTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Repo, Writing}
  alias Still.Writing.{Entry, ReadingPlace}
  alias StillWeb.ReadingLinks

  test "notebook reading stays in order and retains its place through wandering", %{conn: conn} do
    first = piece("First", 1)
    second = piece("Second", 2)
    elsewhere = piece("Elsewhere", 1, "Early Notebooks/Lists 3")
    Writing.begin_writing(nil, writing_form: "list")
    context = %{"from" => "notebook", "notebook" => first.notebook}
    {:ok, reader, _} = live(conn, ReadingLinks.reader(first, context))

    assert has_element?(reader, "a[aria-current='page']", "Notebooks")

    assert has_element?(
             reader,
             "#reading-origin[href*='at=#{first.id}'][href$='#list-#{first.id}']",
             "Contents"
           )

    assert has_element?(
             reader,
             "#notebook-next[href^='/notebooks/read/#{second.id}?'][href*='from=notebook']"
           )

    refute has_element?(reader, ".gravity-presence, .drift-room, .passage-listen")
    assert has_element?(reader, "#wander-with-this[href^='/w/#{first.id}?']", "Wander with this")

    {:ok, second_reader, _} = live(conn, ReadingLinks.reader(second, context))
    assert has_element?(second_reader, "#notebook-previous[href^='/notebooks/read/#{first.id}?']")
    assert ReadingPlace.last().entry.id == second.id

    {:ok, wander, _} = live(conn, ~p"/w/#{elsewhere.id}?read=1")
    assert has_element?(wander, ".drift-room")
    assert has_element?(wander, "#return-to-reading[href^='/notebooks/read/#{second.id}?']")
    assert ReadingPlace.last().entry.id == second.id

    {:ok, returned, _} = live(conn, ReadingLinks.resume(ReadingPlace.last()))

    assert has_element?(
             returned,
             "#reading-origin[href*='at=#{second.id}'][href$='#list-#{second.id}']"
           )

    {:ok, index, _} = live(conn, ReadingLinks.origin(ReadingPlace.last()))
    assert has_element?(index, "#list-#{second.id}.notebook-current a[aria-current='location']")
    assert has_element?(index, "#continue-reading[href^='/notebooks/read/#{second.id}?']")
    assert Writing.current_writing() == nil
    assert Writing.current_list_draft?()
    assert Writing.get_entry!(first.id).body == first.body
    assert Writing.list_versions(first) == []
  end

  test "Find returns to a selected result beyond the first page, including a partial last page",
       %{conn: conn} do
    entries = for number <- 1..145, do: piece("Cobalt #{number}", number)
    selected = Enum.at(entries, 140)
    {:ok, found, _} = live(conn, ~p"/pages?q=cobalt")
    for _ <- 1..3, do: found |> element("button", "Keep looking") |> render_click()
    assert has_element?(found, ".entry-row[href^='/read/#{hd(entries).id}?'][href*='shown=160']")
    assert has_element?(found, ".entry-row[href^='/read/#{selected.id}?'][href*='shown=160']")

    context = %{
      "from" => "find",
      "q" => "cobalt",
      "shown" => 145,
      "at" => "current-#{selected.id}"
    }

    {:ok, reader, _} = live(conn, ReadingLinks.reader(selected, context))

    assert has_element?(
             reader,
             "#reading-origin[href*='q=cobalt'][href*='shown=160'][href$='#results-current-#{selected.id}']",
             "Back to results"
           )

    {:ok, wander, _} = live(conn, ReadingLinks.wander(selected, context))
    assert has_element?(wander, "#return-to-reading[href*='q=cobalt']")
    {:ok, results, _} = live(conn, ReadingLinks.origin(ReadingPlace.last()))
    assert has_element?(results, "#results-current-#{selected.id}[aria-current='location']")

    assert results
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(".entry-row")
           |> LazyHTML.to_tree()
           |> length() == 145
  end

  test "an earlier Find match stays read only when moving into Wander and returning", %{
    conn: conn
  } do
    original = piece("Earlier heron", 1)

    {:ok, current} =
      Writing.save_entry(original, "Current fox", title: "Current title", checkpoint: true)

    [version] = Writing.list_versions(current)

    context = %{
      "from" => "find",
      "q" => "heron",
      "earlier" => true,
      "version" => version.id,
      "at" => "version-#{version.id}"
    }

    {:ok, reader, _} = live(conn, ReadingLinks.reader(current, context))
    assert has_element?(reader, ".historical-reading mark", "heron")
    refute has_element?(reader, "textarea, button[phx-click='restore_version']")
    assert has_element?(reader, "#wander-with-this[href*='version=#{version.id}']")
    {:ok, wander, _} = live(conn, ReadingLinks.wander(current, context))
    assert has_element?(wander, "#return-to-reading[href*='version=#{version.id}']")
    {:ok, back, _} = live(conn, ReadingLinks.resume(ReadingPlace.last()))
    assert has_element?(back, ".historical-reading mark", "heron")

    assert has_element?(
             back,
             "#reading-origin[href*='earlier=1'][href$='#results-version-#{version.id}']"
           )

    assert Writing.get_entry!(current.id).body == "Current fox"
    assert Writing.list_versions(current) == [version]
  end

  defp piece(title, order, notebook \\ "Early Notebooks/Lists 1") do
    %Entry{}
    |> Entry.changeset(%{
      origin: "before",
      title: title,
      body: "#{title}\n\n\tWords kept exactly.",
      notebook: notebook,
      source_order: order,
      list_label: to_string(order)
    })
    |> Repo.insert!()
  end
end
