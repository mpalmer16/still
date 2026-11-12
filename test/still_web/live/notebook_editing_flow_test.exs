defmodule StillWeb.NotebookEditingFlowLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Poems, Storage, Writing}
  alias Still.Writing.Files
  alias StillWeb.ReadingLinks

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    old_state = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "collection")
    File.mkdir_p!(folder)
    assert {:ok, _} = Storage.set_folder(folder)
    on_exit(fn -> Application.put_env(:still, :storage_state_directory, old_state) end)
    %{folder: folder, location: Storage.collection_location()}
  end

  test "a file-backed notebook piece edits in its reader frame and returns with Find context intact",
       %{conn: conn, location: location} do
    {notebook, piece, entry} = notebook_piece(location, "Field book Roundtrip")

    context = %{
      "from" => "find",
      "notebook" => notebook.key,
      "q" => "river words",
      "earlier" => "1",
      "shown" => "80",
      "at" => "current-#{entry.id}",
      "written" => "1"
    }

    reader_path = ReadingLinks.reader(entry, context)
    edit_path = ReadingLinks.edit(entry, context)
    {:ok, reader, _} = live(conn, reader_path)
    assert has_element?(reader, "#notebook-sidebar")

    [edit_href] =
      reader
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#notebook-content a[href^='/writing/#{piece.id}/edit']")
      |> LazyHTML.attribute("href")

    assert edit_href == edit_path
    assert edit_href =~ "from=find"
    assert edit_href =~ "q=river+words"
    assert edit_href =~ "earlier=true"
    assert edit_href =~ "shown=80"
    assert edit_href =~ "at=current-#{entry.id}"
    assert edit_href =~ "written=true"
    refute edit_href =~ "version="

    {:ok, editor, _} = live(conn, edit_href)

    assert has_element?(
             editor,
             "#writing-editor[data-surface='notebook'].notebook-reader.notebook-editing"
           )

    assert has_element?(editor, "#notebook-sidebar a[aria-current='page']", "Roundtrip title")
    assert has_element?(editor, "#open-notebooks[aria-current='page']", "Notebooks")
    assert has_element?(editor, "#back-to-notebook[href^='/notebooks/read/#{entry.id}?']")

    assert has_element?(
             editor,
             "#save-return-notebook[form='file-writing-form'][name='read'][value='true']"
           )

    assert has_element?(editor, "#file-writing-body[phx-hook='FileRecovery']")

    assert has_element?(
             editor,
             "#file-writing-body[data-draft-key='still:poem-draft:#{location.scope}:#{piece.id}'][data-base-token='#{piece.token}']"
           )

    first_edit = "Roundtrip title\nFirst revised words\n"

    render_submit(element(editor, "#file-writing-form"), %{
      "writing" => %{"body" => first_edit}
    })

    assert_patch(editor, edit_path)
    assert has_element?(editor, "#writing-editor[data-surface='notebook']")

    assert has_element?(
             editor,
             "#back-to-notebook[href*='q=river+words'][href*='earlier=true'][href*='shown=80'][href*='at=current-#{entry.id}'][href*='written=true']"
           )

    assert {:ok, saved_once} = Poems.get(location, piece.id)
    assert saved_once.body == first_edit

    second_edit = first_edit <> "A second edit.\n"

    render_submit(element(editor, "#file-writing-form"), %{
      "writing" => %{"body" => second_edit}
    })

    assert_patch(editor, edit_path)
    assert has_element?(editor, "#writing-editor[data-surface='notebook']")
    assert {:ok, saved_twice} = Poems.get(location, piece.id)
    assert saved_twice.body == second_edit
    assert {:ok, before_return} = Poems.revisions(location, piece.id)
    assert Enum.any?(before_return, &(&1.body == first_edit))

    expected_reader = ReadingLinks.reader(entry, context)

    render_submit(element(editor, "#file-writing-form"), %{
      "writing" => %{"body" => second_edit},
      "read" => "true"
    })

    assert_redirect(editor, expected_reader)
    refute expected_reader =~ "version="
    assert {:ok, after_return} = Poems.revisions(location, piece.id)
    assert length(after_return) == length(before_return)
  end

  test "direct notebook editing ignores arbitrary return targets and saved reading redirects to its notebook",
       %{conn: conn, location: location} do
    {_notebook, piece, entry} = notebook_piece(location, "Field book Safe")

    path =
      "/writing/#{piece.id}/edit?from=notebook&notebook=#{URI.encode(entry.notebook)}&q=field&return_to=https%3A%2F%2Fevil.example%2F&path=%2Ftmp%2Foutside"

    {:ok, editor, _} = live(conn, path)
    assert has_element?(editor, "#writing-editor[data-surface='notebook']")
    assert has_element?(editor, "#back-to-notebook[href^='/notebooks/read/#{entry.id}']")
    refute render(editor) =~ "evil.example"
    refute render(editor) =~ "/tmp/outside"

    [return_href] =
      editor
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#back-to-notebook")
      |> LazyHTML.attribute("href")

    refute return_href =~ "return_to"
    refute return_href =~ "path="

    assert {:error, {:live_redirect, %{to: redirect_path}}} = live(conn, ~p"/writing/#{piece.id}")

    assert redirect_path ==
             ReadingLinks.reader(entry, %{"from" => "notebook", "notebook" => entry.notebook})
  end

  test "standalone files keep the ordinary Write and Read path", %{conn: conn, location: location} do
    {:ok, piece} =
      Poems.save(location, Poems.new(location), %{
        body: "Standalone title\nOriginal words",
        relative_path: "Standalone.txt"
      })

    {:ok, reader, _} = live(conn, ~p"/writing/#{piece.id}")
    assert has_element?(reader, "#edit-file[href='/writing/#{piece.id}/edit']", "Edit")
    refute has_element?(reader, "#writing-editor[data-surface='notebook']")

    {:ok, editor, _} = live(conn, ~p"/writing/#{piece.id}/edit")
    assert has_element?(editor, "#writing-editor[data-surface='writing']")
    refute has_element?(editor, "#notebook-sidebar")
    refute has_element?(editor, "#save-return-notebook")
    assert has_element?(editor, "#file-relative-path[value='Standalone.txt']")

    render_submit(element(editor, "#file-writing-form"), %{
      "writing" => %{"body" => "Standalone title\nRevised words"}
    })

    assert_patch(editor, ~p"/writing/#{piece.id}/edit")
    assert {:ok, saved} = Poems.get(location, piece.id)
    assert saved.relative_path == "Standalone.txt"
    assert saved.body == "Standalone title\nRevised words"
  end

  test "a stale notebook file leaves external bytes untouched and keeps the proposed editor words",
       %{
         conn: conn,
         location: location
       } do
    {_notebook, piece, entry} = notebook_piece(location, "Field book Stale")
    context = %{"from" => "notebook", "notebook" => entry.notebook, "q" => "river"}
    {:ok, editor, _} = live(conn, ReadingLinks.edit(entry, context))
    File.write!(piece.path, "Changed outside Still")
    proposed = "Roundtrip title\nLatest local words\n"

    render_submit(element(editor, "#file-writing-form"), %{
      "writing" => %{"body" => proposed}
    })

    assert has_element?(editor, "#writing-editor[data-surface='notebook']")
    assert has_element?(editor, "#file-problem", "changed on disk")

    assert has_element?(
             editor,
             "#file-writing-form[data-save-blocked='true'][data-unsaved='true']"
           )

    assert has_element?(editor, "#file-writing-body[phx-hook='FileRecovery']")
    assert File.read!(piece.path) == "Changed outside Still"
    assert has_element?(editor, "#back-to-notebook[href*='q=river']")
  end

  test "Save & return to the notebook takes priority over a Wander return", %{
    conn: conn,
    location: location
  } do
    {_notebook, piece, entry} = notebook_piece(location, "Field book Return priority")
    edit_path = ~p"/writing/#{piece.id}/edit?from=wander"
    {:ok, editor, _} = live(conn, edit_path)
    assert has_element?(editor, "#back-to-wander[href='/w/#{entry.id}?read=1']")
    assert has_element?(editor, "#save-return-notebook")

    render_submit(element(editor, "#file-writing-form"), %{
      "writing" => %{"body" => piece.body <> "Returned from notebook"},
      "read" => "true",
      "return_notebook" => "true"
    })

    assert_redirect(
      editor,
      ReadingLinks.reader(entry, %{"from" => "notebook", "notebook" => entry.notebook})
    )
  end

  defp notebook_piece(location, notebook_name) do
    {:ok, notebook} =
      Files.create_folder(location, notebook_name, %{label: notebook_name})

    {:ok, piece} =
      Poems.save(location, Poems.new(location), %{
        body: "Roundtrip title\nOriginal river words\n",
        title_line: 1,
        notebook_id: notebook.id,
        list_label: "7",
        source_order: 7
      })

    entry = Writing.get_entry(piece.entry_id)
    {notebook, piece, entry}
  end
end
