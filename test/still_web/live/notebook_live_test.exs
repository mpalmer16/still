defmodule StillWeb.NotebookLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Repo, Writing}
  alias Still.Writing.Entry

  @tag :tmp_dir
  test "a collection can be created without automatic numbering", %{conn: conn, tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "writing"))
    assert {:ok, _} = Still.Storage.set_folder(Path.join(root, "writing"))
    {:ok, view, _} = live(conn, ~p"/notebooks")
    view |> form("#new-notebook", notebook: %{label: "Poems", numbered: false}) |> render_submit()
    assert Writing.notebook("Poems").numbered == false
    assert has_element?(view, ".notebook-order", "without notebook numbers")
    assert Writing.current_notebook() == nil
  end

  @tag :tmp_dir
  test "section names and the new-List destination can be changed in the notebook", %{
    conn: conn,
    tmp_dir: root
  } do
    folder = Path.join(root, "writing")
    File.mkdir_p!(Path.join(folder, "Notebook 1/Jan - Mar"))
    File.write!(Path.join(folder, "Notebook 1/Jan - Mar/10.txt"), "Early")
    File.write!(Path.join(folder, "Notebook 1/155.txt"), "Later")
    assert {:ok, _} = Still.Storage.set_folder(folder)

    assert {:ok, book} =
             Still.Writing.Files.register_folder(
               Still.Storage.collection_location(),
               "Notebook 1",
               %{label: "Notebook 1"}
             )

    {:ok, view, _} = live(conn, ~p"/notebooks?notebook=#{book.key}")
    view |> form("#rename-section-0", %{label: "Apr - Nov"}) |> render_submit()
    assert has_element?(view, "h2", "Apr - Nov")

    view
    |> element("button[phx-click=choose_section][phx-value-section='#{book.key}']")
    |> render_click()

    assert Writing.current_notebook().id == book.id
    assert has_element?(view, "#notebook-section-0", "New Lists go here")
    assert has_element?(view, "#notebook-lists-0[open]")
    refute has_element?(view, "#notebook-lists-1[open]")
    view |> form("#rename-section-0", %{label: ""}) |> render_submit()
    assert has_element?(view, "h2", "Apr - Nov")
    {:ok, reopened, _} = live(conn, ~p"/notebooks?notebook=#{book.key}")
    assert has_element?(reopened, "h2", "Apr - Nov")
    early = Writing.notebook(book.key).entries |> Enum.find(&(&1.list_label == "10"))
    {:ok, returned, _} = live(conn, ~p"/notebooks?notebook=#{book.key}&at=#{early.id}")
    assert has_element?(returned, "#notebook-lists-1[open]")
  end

  test "the notebook room can add an empty notebook and choose it as current", %{conn: conn} do
    folder =
      Path.join(System.tmp_dir!(), "still-notebook-room-#{System.unique_integer([:positive])}")

    File.mkdir_p!(folder)
    on_exit(fn -> File.rm_rf!(folder) end)
    assert {:ok, _} = Still.Storage.set_folder(folder)
    {:ok, view, _html} = live(conn, ~p"/notebooks")

    view
    |> form("#new-notebook",
      notebook: %{
        label: "Field book 07c",
        key: "Field books/07c",
        relative_path: "Field books/07c",
        series: "Field books",
        number_label: "07c",
        description: "Pocket notebook",
        pen: "Blue pencil"
      }
    )
    |> render_submit()

    notebook = Writing.notebook("Field books/07c")
    assert File.dir?(Path.join(folder, "Field books/07c"))
    assert notebook.entries == []
    assert Writing.notebooks() |> Enum.any?(&(&1.key == notebook.key))

    view |> element(".notebook-back") |> render_click()

    view
    |> element("form[phx-submit=choose_current]")
    |> render_submit(%{"id" => to_string(notebook.id)})

    assert Writing.current_notebook().id == notebook.id
  end

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

    assert has_element?(
             catalog,
             "#list-#{first.id} a[href^='/notebooks/read/#{first.id}?'][href*='from=notebook']",
             "Changed:"
           )

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
    assert has_element?(empty, "#return-to-writing[href='/']")

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
