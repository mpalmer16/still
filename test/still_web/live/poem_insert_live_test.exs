defmodule StillWeb.PoemInsertLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Poems, Storage}
  alias Still.Writing.PoemReferences
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "writing")
    File.mkdir!(folder)
    {:ok, _} = Storage.set_folder(folder)
    on_exit(fn -> Application.put_env(:still, :storage_state_directory, previous) end)
    location = Storage.collection_location()

    {:ok, source} =
      Poems.save(location, Poems.new(location), %{
        body: "Rain\n\tRiver\n",
        relative_path: "Rain.txt"
      })

    %{location: location, source: source}
  end

  test "picker previews a poem and inserts only its reference without saving the source", %{
    conn: conn,
    location: location,
    source: source
  } do
    {:ok, view, _} = live(conn, ~p"/?new=1")
    assert has_element?(view, "#insert-poem[data-insert-poem]")
    render_click(view, "open_poem_picker")
    assert has_element?(view, "#poem-picker[role=dialog]")
    assert has_element?(view, "#room-content[inert]")
    view |> form("#poem-picker-search", poem: %{query: "river"}) |> render_change()
    view |> element("#poem-choice-#{source.id}") |> render_click()
    assert has_element?(view, ".poem-picker-preview", "River")
    view |> element("#confirm-insert-poem") |> render_click()
    marker = PoemReferences.marker(source)
    assert_push_event(view, "insert-poem-reference", %{marker: ^marker})
    refute has_element?(view, "#poem-picker")

    body = "Before\n\n#{marker}\n\nAfter"
    render_click(view, "poem_structure_changed", %{body: body})
    assert has_element?(view, "figure[data-reference-raw] .poem-insert-words", "River")
    render_submit(view, "save_file", %{writing: %{body: body, relative_path: "Surrounding.txt"}})
    assert {:ok, pieces} = Poems.list(location)
    host = Enum.find(pieces, &(&1.relative_path == "Surrounding.txt"))
    assert File.read!(host.path) == body
    assert File.read!(source.path) == source.body
    assert {:ok, []} = Poems.revisions(location, source.id)
  end

  test "source updates and missing files update the passage without overwriting unsaved surrounding words",
       %{conn: conn, location: location, source: source} do
    body = "Before\n#{PoemReferences.marker(source)}\nAfter"

    {:ok, host} =
      Poems.save(location, Poems.new(location), %{body: body, relative_path: "Essay.txt"})

    {:ok, view, _} = live(conn, ~p"/writing/#{host.id}/edit")
    changed = body <> "\nStill writing"
    render_change(view, "writing_changed", %{writing: %{body: changed}})
    File.write!(source.path, "New rain\n  Same river")
    send(view.pid, {:refresh_linked_poems, host.id})
    assert has_element?(view, ".poem-insert-words", "New rain")
    assert :sys.get_state(view.pid).socket.assigns.draft.body == changed
    assert File.read!(host.path) == body

    File.rm!(source.path)
    send(view.pid, {:refresh_linked_poems, host.id})
    assert has_element?(view, ".poem-insert-unavailable", "Source unavailable")
    assert :sys.get_state(view.pid).socket.assigns.draft.body == changed
    assert File.read!(host.path) == body
  end

  test "reading renders escaped source words and supplies expanded copy without changing references",
       %{conn: conn, location: location, source: source} do
    {:ok, source} =
      Poems.save(location, source, %{body: "<script>literal words</script>\n  rain"})

    body = "Before\n#{PoemReferences.marker(source)}\nAfter"
    {:ok, host} = Poems.save(location, Poems.new(location), %{body: body})
    {:ok, view, _} = live(conn, ~p"/writing/#{host.id}")
    assert has_element?(view, ".poem-insert-words", "<script>literal words</script>")
    refute has_element?(view, ".poem-insert script")
    assert has_element?(view, "#copy-file-reading[data-reference-sources]")
    assert has_element?(view, ".poem-insert a", "Open original")
    assert has_element?(view, "[data-echo-line='3']", "After")
    render_hook(view, "focus_passage", %{id: host.id, line: "3"})
    assert has_element?(view, "[data-echo-line='3'].passage-focused")
    assert view |> element("#whole-page-echoes") |> render_click()
    assert File.read!(host.path) == body
  end
end
