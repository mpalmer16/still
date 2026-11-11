defmodule StillWeb.ReadingImprovementsTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Repo, Writing}
  alias Still.Writing.Entry

  test "search opens a deep matched passage, with literal escaped words", %{conn: conn} do
    body = "A plain opening\n\n\tCafé and <script>alert('heron')</script>\n  end"
    {:ok, entry} = Writing.save_entry(nil, body)
    {:ok, found, _} = live(conn, ~p"/pages?q=heron+cafe")
    assert has_element?(found, ".entry-excerpt mark", "Café")
    assert has_element?(found, ".entry-excerpt mark", "heron")
    refute has_element?(found, ".entry-excerpt script")
    assert has_element?(found, ".entry-row[href$='#passage-3']")
    {:ok, read, _} = live(conn, ~p"/w/#{entry.id}?q=heron+cafe&read=1")
    refute has_element?(read, ".reading-room mark")
    refute has_element?(read, "[data-search-target='true']")

    assert read
           |> element("#list-body")
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("[data-authored-line]")
           |> LazyHTML.to_tree()
           |> length() == 4

    refute has_element?(read, ".reading-room mark")
    refute has_element?(read, "[data-search-target='true']")
    assert has_element?(read, "a[href*='q=heron+cafe']", "Back to results")

    render_click(element(read, "#open-piece-find"))
    assert has_element?(read, "#piece-find-query")

    render_change(element(read, "#piece-find-form"), %{
      "piece_find" => %{"query" => "heron cafe"},
      "_target" => ["piece_find", "query"]
    })

    assert has_element?(read, ".reading-room mark", "Café")
    assert has_element?(read, ".reading-room mark", "heron")
    refute has_element?(read, "[data-search-target='true']")

    render_submit(element(read, "#piece-find-form"), %{"piece_find" => %{"query" => "heron cafe"}})

    assert has_element?(read, "#passage-3[data-search-target='true'][tabindex='-1'] mark", "Café")

    render_change(element(read, "#piece-find-form"), %{
      "piece_find" => %{"query" => "no-such-word"},
      "_target" => ["piece_find", "query"]
    })

    assert has_element?(read, "#piece-find-status", "No matches in this piece")
    render_click(element(read, "#close-piece-find"))
    refute has_element?(read, ".reading-room mark")
    assert has_element?(read, "a[href*='q=heron+cafe']", "Back to results")
    refute has_element?(read, "#close-piece-find")

    assert Writing.get_entry!(entry.id).body == body
    assert Writing.list_versions(entry) == []
  end

  test "historical search opens read only, never restoring or consuming recovery", %{conn: conn} do
    {:ok, entry} = Writing.save_entry(nil, "An earlier heron", title: "Old title")

    {:ok, current} =
      Writing.save_entry(entry, "The current fox", title: "New title", checkpoint: true)

    [version] = Writing.list_versions(current)
    Writing.remember_writing(current)
    {:ok, found, _} = live(conn, ~p"/pages?q=heron")
    refute has_element?(found, ".entry-row")

    render_change(element(found, "#search-form"), %{
      "search" => %{"query" => "heron", "earlier" => "true"}
    })

    assert_patch(found, ~p"/pages?earlier=1&q=heron")
    assert has_element?(found, ".earlier-label", "Earlier words")

    {:ok, read, html} =
      live(conn, ~p"/w/#{current.id}?read=1&q=heron&earlier=1&version=#{version.id}")

    refute has_element?(read, ".historical-reading mark")
    refute has_element?(read, "[data-search-target='true']")
    assert html =~ "current words are unchanged"

    refute has_element?(
             read,
             "textarea, [phx-hook='ReadRecovery'], button[phx-click='restore_version']"
           )

    render_click(element(read, "#open-piece-find"))
    render_submit(element(read, "#piece-find-form"), %{"piece_find" => %{"query" => "heron"}})
    assert has_element?(read, ".historical-reading mark", "heron")
    render_click(element(read, "#close-piece-find"))
    refute has_element?(read, ".historical-reading mark")
    assert has_element?(read, ".historical-reading", "earlier heron")
    assert has_element?(read, "a[href*='earlier=1'][href*='q=heron']", "Back to results")

    assert Writing.get_entry!(current.id) == current
    assert Writing.list_versions(current) == [version]
    assert Writing.current_writing().id == current.id
    {:ok, invalid, _} = live(conn, ~p"/w/#{current.id}?read=1&version=invalid")
    assert has_element?(invalid, "#list-body", "current fox")
    assert has_element?(invalid, ".recovery-note", "That earlier version isn't here")
  end

  test "source neighbors cross sections in index order and retracing preserves pending writing",
       %{conn: conn} do
    a = before("Root first", "Current Notebooks/2026/Notebook 1", 0)
    b = before("Root last", "Current Notebooks/2026/Notebook 1", 100)
    c = before("Corner first", "Current Notebooks/2026/Notebook 1/Jan - Mar", 0)
    Writing.begin_writing(a, writing_form: "list")
    {:ok, first, _} = live(conn, ~p"/w/#{a.id}?read=1")
    refute has_element?(first, "#notebook-previous")
    assert has_element?(first, "#notebook-next[href='/w/#{b.id}?read=1']")
    {:ok, middle, _} = live(conn, ~p"/w/#{b.id}?read=1")
    assert has_element?(middle, "#notebook-previous[href='/w/#{a.id}?read=1']")
    assert has_element?(middle, "#notebook-next[href='/w/#{c.id}?read=1']")
    {:ok, last, _} = live(conn, ~p"/w/#{c.id}?read=1")
    refute has_element?(last, "#notebook-next")
    last |> element("#reading-back") |> render_click()
    assert_redirect(last, ~p"/w/#{b.id}?read=1")
    {:ok, returned, _} = live(conn, ~p"/w/#{b.id}?read=1")
    returned |> element("#reading-back") |> render_click()
    assert_redirect(returned, ~p"/w/#{a.id}?read=1")
    assert Writing.current_writing() == nil
    assert Writing.current_beside().id == a.id
    assert Writing.current_list_draft?()
    assert Writing.list_versions(a) == []
    {:ok, edited} = Writing.save_entry(a, "Edited words", title: "Later title")
    assert Writing.notebook_neighbors(edited).next.id == b.id
  end

  test "retracing a search restores its matched passage", %{conn: conn} do
    {:ok, a} = Writing.save_entry(nil, "Opening\n\tA heron waits")
    {:ok, b} = Writing.save_entry(nil, "Another page")
    {:ok, _a, _} = live(conn, ~p"/w/#{a.id}?read=1&q=heron")
    {:ok, next, _} = live(conn, ~p"/w/#{b.id}?read=1")
    next |> element("#reading-back") |> render_click()
    assert_redirect(next, ~p"/w/#{a.id}?#{[q: "heron", read: "1"]}" <> "#passage-2")
  end

  test "keyboard and screen reader controls identify the page and restore their trigger", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, ".skip-link[href='#page-content']")
    assert has_element?(view, "main#page-content[tabindex='-1'] h1", "Write now")
    assert has_element?(view, "#file-writing-body[aria-describedby='file-keyboard-hint']")
    assert has_element?(view, "#file-keyboard-hint", "Escape leaves the editor")
    view |> element("#letters-toggle") |> render_click()
    render_change(element(view, "#room-letters-form"), %{"letters" => %{"size" => "100"}})
    assert has_element?(view, "#room-letters-size[aria-valuetext='33 pixels']")
    view |> element("#room-close") |> render_click()
    view |> element("#landscape-toggle") |> render_click()
    assert has_element?(view, "#room-landscape[role='dialog'][aria-modal='true']")
    assert has_element?(view, "#writing-menu[hidden] .writing-menu-room-controls[inert]")
    assert has_element?(view, "#room-content[inert]")
    assert Writing.list_entries() == []
  end

  defp before(title, notebook, order) do
    %Entry{}
    |> Entry.changeset(%{
      origin: "before",
      title: title,
      body: "Words of #{title}",
      notebook: notebook,
      source_order: order
    })
    |> Repo.insert!()
  end
end
