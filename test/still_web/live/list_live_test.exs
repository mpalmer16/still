defmodule StillWeb.ListLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Poems, Storage, Writing}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "collection")
    File.mkdir_p!(folder)
    {:ok, _} = Storage.set_folder(folder)
    on_exit(fn -> Application.put_env(:still, :storage_state_directory, previous) end)
    %{folder: folder}
  end

  test "a blank page has no writing types and pasted text stays exact until explicit Save", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/writing/new")
    assert has_element?(view, "#file-writing-form")
    assert has_element?(view, "#file-writing-title[value='']")
    refute has_element?(view, "[data-writing-type]")
    refute has_element?(view, "#list-interpretation")

    pasted = "A possible title\n\nrain: furnace:\n  another line\n"

    render_change(element(view, "#file-writing-form"), %{
      "writing" => %{"title_line" => "", "body" => pasted}
    })

    assert Writing.list_entries() == []

    assert has_element?(view, "#file-writing-form[data-unsaved='true']")
    refute has_element?(view, "#list-interpretation")

    assert has_element?(view, "#file-save-status", "Local draft")

    render_submit(element(view, "#file-writing-form"), %{
      "writing" => %{"title_line" => "1", "body" => pasted}
    })

    assert {:ok, [saved]} = Poems.list(Storage.collection_location())
    assert saved.body == pasted
    assert saved.title_line == 1
    assert Poems.display_title(saved) == "A possible title"
    assert_patch(view, ~p"/writing/#{saved.id}/edit")
    assert has_element?(view, "#file-writing-body")
  end

  test "the Now desk resumes its saved file after visiting Find and its earlier words", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/writing/new")
    original = "First complete draft\n\twith the same spacing"

    render_submit(element(view, "#file-writing-form"), %{
      "writing" => %{"title_line" => "1", "body" => original}
    })

    assert {:ok, [saved]} = Poems.list(Storage.collection_location())

    revised = "Second complete draft\n\twith a new ending"

    render_submit(element(view, "#file-writing-form"), %{
      "writing" => %{"title_line" => "1", "body" => revised}
    })

    {:ok, versions} = Poems.revisions(Storage.collection_location(), saved.id)
    assert Enum.any?(versions, &(&1.body == original and &1.title_line == 1))

    {:ok, _find, _} = live(conn, ~p"/pages")
    {:ok, resumed, _} = live(conn, ~p"/")
    assert has_element?(resumed, "#file-writing-body")
    assert has_element?(resumed, "#file-writing-title[value='']")

    assert resumed
           |> element("#file-writing-body")
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.text() == revised

    assert Enum.any?(Writing.list_entries(), &(&1.file_id == saved.id and &1.body == revised))
  end
end
