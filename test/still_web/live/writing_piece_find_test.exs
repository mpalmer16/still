defmodule StillWeb.WritingPieceFindTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Poems, Storage}
  alias Still.Writing.PoemReferences

  @moduletag :tmp_dir
  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "collection")
    File.mkdir_p!(folder)
    {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:still, :storage_state_directory, previous),
        else: Application.delete_env(:still, :storage_state_directory)
    end)

    %{location: Storage.collection_location()}
  end

  test "local Find reads linked poems without changing either file", %{
    conn: conn,
    location: location
  } do
    {:ok, source} =
      Poems.save(location, Poems.new(location), %{title: "Orchard", body: "  A heron waits.\n"})

    {:ok, host} =
      Poems.save(location, Poems.new(location), %{
        title: "Notes",
        body: "An introduction\n\n" <> PoemReferences.marker(source) <> "\n\nAfterward"
      })

    {:ok, view, _} = live(conn, ~p"/writing/#{host.id}")
    refute has_element?(view, "#file-text mark")
    render_click(element(view, "#open-piece-find"))
    assert_push_event(view, "room-focus", %{id: "piece-find-query", scroll: true})

    render_change(element(view, "#piece-find-form"), %{
      "piece_find" => %{"query" => "heron"},
      "_target" => ["piece_find", "query"]
    })

    assert has_element?(view, ".poem-insert-words mark", "heron")
    assert has_element?(view, "#piece-find-status", "1 matching word")
    render_submit(element(view, "#piece-find-form"), %{"piece_find" => %{"query" => "heron"}})
    assert_push_event(view, "room-focus", %{id: "linked-poem-1", scroll: true})
    render_click(element(view, "#close-piece-find"))
    refute has_element?(view, "#file-text mark")
    assert File.read!(host.path) == host.body
    assert File.read!(source.path) == source.body
  end

  test "a saved plain piece jumps only when local Find is submitted", %{
    conn: conn,
    location: location
  } do
    {:ok, piece} = Poems.save(location, Poems.new(location), %{body: "First line\n\nA heron"})
    {:ok, view, _} = live(conn, ~p"/writing/#{piece.id}")
    render_click(element(view, "#open-piece-find"))

    render_change(element(view, "#piece-find-form"), %{
      "piece_find" => %{"query" => "heron"},
      "_target" => ["piece_find", "query"]
    })

    refute has_element?(view, "[data-search-target]")
    render_submit(element(view, "#piece-find-form"), %{"piece_find" => %{"query" => "heron"}})
    assert_push_event(view, "room-focus", %{id: "file-passage-3", scroll: true})
    assert has_element?(view, "#file-passage-3[data-search-target='true']")
  end
end
