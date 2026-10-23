defmodule StillWeb.NotebookLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Repo, Writing}
  alias Still.Writing.Entry

  test "the catalog leads to every List in its original order without taking Now", %{conn: conn} do
    second = before("second", "Early Notebooks/Lists 1", "Second:List:", 2)
    first = before("first", "Early Notebooks/Lists 1", "First:List:", 1)
    {:ok, _changed} = Writing.save_entry(first, "Words changed today", title: "Changed:Title:")
    {:ok, now} = Writing.save_entry(nil, "The writing I will return to")
    Writing.remember_writing(now)

    {:ok, catalog, _html} = live(conn, ~p"/notebooks")
    assert has_element?(catalog, "#notebook-catalog", "Lists 1")
    assert has_element?(catalog, ".notebook-count", "2 Lists")

    catalog
    |> element(".notebook-name")
    |> render_click()

    html = render(catalog)

    assert html
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(".notebook-list li")
           |> LazyHTML.attribute("id") ==
             ["list-#{first.id}", "list-#{second.id}"]

    assert has_element?(catalog, "#list-#{first.id} a[href='/w/#{first.id}?read=1']", "Changed:")
    assert has_element?(catalog, "a[href='#section-0-end']", "End")
    assert has_element?(catalog, "#section-0-end", "End")
    assert Writing.current_writing().id == now.id
    assert Writing.get_entry!(second.id).returned_at == nil
    assert Writing.list_versions(second) == []

    {:ok, read, _html} = live(conn, ~p"/w/#{second.id}?read=1")
    assert has_element?(read, ".reading-room")

    assert has_element?(
             read,
             "#notebook-return[href*='at=#{second.id}'][href$='#list-#{second.id}']",
             "Lists 1"
           )

    assert Writing.current_writing().id == now.id

    {:ok, index, _html} =
      live(conn, ~p"/notebooks?notebook=Early%20Notebooks%2FLists%201&at=#{second.id}")

    assert has_element?(index, "#list-#{second.id}.notebook-current a[aria-current='location']")
    assert Writing.current_writing().id == now.id
  end

  test "physical notebook sections retain their own boundaries", %{conn: conn} do
    root = before("root", "Current Notebooks/2026/Notebook 1", "Root:", 0)
    corner = before("corner", "Current Notebooks/2026/Notebook 1/Jan - Mar", "Corner:", 0)

    {:ok, view, _html} =
      live(conn, ~p"/notebooks?notebook=Current%20Notebooks%2F2026%2FNotebook%201")

    assert has_element?(view, "#notebook-section-0 #list-#{root.id}")
    assert has_element?(view, "#notebook-section-1 #list-#{corner.id}")
    assert has_element?(view, "#notebook-section-1 h2", "Jan - Mar")
    assert has_element?(view, "a[href='#section-1-end']")
    assert render(view) =~ "Each source section keeps its own order."
  end

  test "empty and unknown notebook views preserve pending List writing", %{conn: conn} do
    Writing.begin_writing(nil, writing_form: "list")
    {:ok, empty, _html} = live(conn, ~p"/notebooks")
    assert has_element?(empty, ".notebook-empty", "Your notebooks will appear here.")
    assert has_element?(empty, "#return-to-writing[href='/list?resume=1']")

    {:ok, missing, _html} = live(conn, ~p"/notebooks?notebook=missing&at=not-an-id")
    assert has_element?(missing, ".notebook-empty", "That notebook isn't here.")
    refute has_element?(missing, ".notebook-list")
    assert Writing.current_list_draft?()
    assert Writing.list_entries() == []
  end

  test "Find exposes the index and authored titles remain escaped", %{conn: conn} do
    old = before("literal", "Early Notebooks/Lists 1", "<script>: & words", 0)
    {:ok, found, _html} = live(conn, ~p"/pages")
    assert has_element?(found, "a[href='/notebooks']", "Browse notebooks")

    {:ok, index, html} = live(conn, ~p"/notebooks?notebook=Early%20Notebooks%2FLists%201")
    assert has_element?(index, "#list-#{old.id}", "<script>:")
    refute has_element?(index, "#list-#{old.id} script")
    assert html =~ "&lt;script&gt;"
  end

  defp before(key, notebook, title, order) do
    %Entry{}
    |> Entry.changeset(%{
      source_key: key,
      source_group: key,
      notebook: notebook,
      source_order: order,
      origin: "before",
      title: title,
      body: "A page kept in its source place"
    })
    |> Repo.insert!()
  end
end
