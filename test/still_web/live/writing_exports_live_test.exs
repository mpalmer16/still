defmodule StillWeb.WritingExportsLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Desk, Poems, Storage}
  alias Still.Writing.{Files, PoemReferences}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    previous_native = Application.get_env(:still, :native_controls)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    Application.put_env(:still, :native_controls, true)
    folder = Path.join(root, "writing")
    File.mkdir_p!(folder)
    {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      Application.put_env(:still, :storage_state_directory, previous)
      Application.put_env(:still, :native_controls, previous_native)
    end)

    %{folder: folder, location: Storage.collection_location()}
  end

  test "menu saves the latest words while renaming Untitled and retains identity and earlier words",
       %{conn: conn, location: location} do
    {:ok, piece} =
      Poems.save(location, Poems.new(location), %{
        body: "Earlier words",
        relative_path: "Untitled.txt"
      })

    {:ok, view, _} = live(conn, ~p"/writing/#{piece.id}/edit")
    assert has_element?(view, "#rename-menu-name[value='Untitled.txt']")
    latest = "Latest words\n  Still indented\n"

    render_submit(view, "save_file", %{
      writing: %{body: latest},
      file_action: "rename",
      name: "A chosen name"
    })

    {:ok, renamed} = Poems.get(location, piece.id)
    assert renamed.relative_path == "A chosen name.txt"
    assert File.read!(renamed.path) == latest
    refute File.exists?(piece.path)
    assert has_element?(view, "#rename-menu-name[value='A chosen name.txt']")
    assert {:ok, %{id: id, saved: true}} = Desk.current(location)
    assert id == piece.id
    assert {:ok, revisions} = Poems.revisions(location, piece.id)
    assert Enum.any?(revisions, &(&1.body == "Earlier words"))
  end

  test "rename collision leaves the other file intact and keeps the current words safely saved",
       %{conn: conn, location: location} do
    {:ok, piece} =
      Poems.save(location, Poems.new(location), %{body: "Earlier", relative_path: "Untitled.txt"})

    {:ok, other} =
      Poems.save(location, Poems.new(location), %{
        body: "Other writing",
        relative_path: "Occupied.txt"
      })

    {:ok, view, _} = live(conn, ~p"/writing/#{piece.id}/edit")

    render_submit(view, "save_file", %{
      writing: %{body: "Latest unsent words"},
      file_action: "rename",
      name: "Occupied.txt"
    })

    assert File.read!(piece.path) == "Latest unsent words"
    assert File.read!(other.path) == "Other writing"
    assert has_element?(view, "#writing-menu-problem", "occupied")
    assert {:ok, %{saved: true}} = Desk.current(location)
  end

  test "Markdown exports current writing and source words outside the collection without changing references",
       %{conn: conn, location: location, folder: folder} do
    {:ok, poem} =
      Poems.save(location, Poems.new(location), %{
        body: "Rain\n  River",
        relative_path: "Rain.txt"
      })

    body = "Before\n\n#{PoemReferences.marker(poem)}\n\nAfter"

    {:ok, piece} =
      Poems.save(location, Poems.new(location), %{body: body, relative_path: "Essay.txt"})

    {:ok, view, _} = live(conn, ~p"/writing/#{piece.id}/edit")
    latest = body <> "\nLatest thought"
    render_submit(view, "save_file", %{writing: %{body: latest}, file_action: "markdown"})
    exported = Path.join(Path.dirname(folder), "writing Exports/Essay.md")
    assert File.read!(exported) =~ "Rain\n  River"
    assert File.read!(exported) =~ "Latest thought"
    refute File.read!(exported) =~ "[[poem:"
    assert File.read!(piece.path) == latest
    assert File.read!(poem.path) == poem.body
    assert {:ok, visible} = Files.list(location)
    assert length(visible) == 2
    assert has_element?(view, "#writing-export-notice", "Markdown saved")
  end

  test "PDF preparation includes source passages and a signed snapshot without replacing the text file",
       %{conn: conn, location: location} do
    {:ok, poem} = Poems.save(location, Poems.new(location), %{body: "Rain\n  River"})
    body = "Before\n#{PoemReferences.marker(poem)}\nAfter"
    {:ok, piece} = Poems.save(location, Poems.new(location), %{body: body})
    {:ok, view, _} = live(conn, ~p"/writing/#{piece.id}/edit")
    assert has_element?(view, "#export-writing-pdf")
    render_submit(view, "save_file", %{writing: %{body: body}, file_action: "pdf"})
    assert_push_event(view, "writing-pdf-request", %{ticket: ticket, request_id: request_id})

    assert {:ok, %{id: id, scope: scope}} =
             Phoenix.Token.verify(StillWeb.Endpoint, "writing-pdf-export", ticket, max_age: 300)

    assert id == piece.id
    assert scope == location.scope
    assert File.read!(piece.path) == body

    render_click(view, "pdf_export_failed", %{
      message: "A synthetic renderer failure",
      request_id: request_id
    })

    refute has_element?(view, "#export-writing-pdf[disabled]")
    assert has_element?(view, "#writing-menu-problem", "synthetic renderer failure")
  end

  test "a PDF completing after switching writings does not attach its output to the new page", %{
    conn: conn,
    location: location
  } do
    {:ok, first} = Poems.save(location, Poems.new(location), %{body: "First writing"})
    {:ok, second} = Poems.save(location, Poems.new(location), %{body: "Second writing"})
    {:ok, view, _} = live(conn, ~p"/writing/#{first.id}/edit")
    render_submit(view, "save_file", %{writing: %{body: first.body}, file_action: "pdf"})
    assert_push_event(view, "writing-pdf-request", %{request_id: request_id})
    render_patch(view, ~p"/writing/#{second.id}/edit")

    render_click(view, "pdf_export_finished", %{
      request_id: request_id,
      path: "/synthetic/First.pdf"
    })

    refute has_element?(view, "#writing-export-notice")
    assert :sys.get_state(view.pid).socket.assigns.last_export == nil
    assert File.read!(second.path) == second.body
    refute has_element?(view, "#export-writing-pdf[disabled]")
  end
end
