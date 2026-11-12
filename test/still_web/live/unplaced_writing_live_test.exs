defmodule StillWeb.UnplacedWritingLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Poems, Storage}
  alias Still.Writing.Files

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "writing")
    File.mkdir_p!(folder)
    assert {:ok, _} = Storage.set_folder(folder)
    location = Storage.collection_location()
    {:ok, notebook} = Files.create_folder(location, "Notebook 1", %{label: "Notebook 1"})

    on_exit(fn -> Application.put_env(:still, :storage_state_directory, previous) end)
    %{folder: folder, location: Storage.collection_location(), notebook: notebook}
  end

  test "the unplaced route defaults Save to the selected notebook and preserves submitted latest words",
       %{conn: conn, folder: folder, location: location, notebook: notebook} do
    {:ok, view, _} = live(conn, "/?notebook=#{notebook.id}&unplaced=true")
    assert has_element?(view, "#next-list-destination", "Unplaced · Not yet numbered")
    assert has_element?(view, "#save-unplaced", "Save to Unplaced")

    render_submit(view, "save_file", %{
      "writing" => %{
        "body" => "Latest words before the debounce",
        "notebook_id" => to_string(notebook.id)
      }
    })

    {:ok, pieces} = Files.list(location)
    [saved] = Enum.filter(pieces, & &1.unplaced)
    assert saved.body == "Latest words before the debounce"
    assert saved.notebook_id == notebook.id
    assert saved.list_label == nil
    assert File.read!(Path.join(folder, saved.relative_path)) == saved.body
  end

  test "restoring an Unplaced draft preserves its destination on ordinary Save", %{
    conn: conn,
    location: location,
    notebook: notebook
  } do
    {:ok, view, _} = live(conn, "/?new=1")

    attrs = %{
      "body" => "Recovered transcription",
      "notebook_id" => to_string(notebook.id),
      "unplaced" => "true"
    }

    render_change(view, "writing_changed", %{"writing" => attrs})
    assert has_element?(view, "#next-list-destination", "Unplaced")
    render_submit(view, "save_file", %{"writing" => attrs})
    assert {:ok, [saved]} = Files.list(location)
    assert saved.unplaced
    assert saved.list_label == nil
  end

  test "choosing Unplaced updates the filename before ordinary Save", %{
    conn: conn,
    location: location,
    notebook: notebook
  } do
    {:ok, _} = Still.Writing.Notebooks.choose_current(notebook.id)
    {:ok, view, _} = live(conn, "/?new=1")
    assert has_element?(view, "#rename-menu-name[value='1_Untitled.txt']")

    view |> form("#file-writing-form", writing: %{body: "", unplaced: "true"}) |> render_change()
    assert has_element?(view, "#new-writing-destination option[value='true'][selected]")
    assert has_element?(view, "#rename-menu-name[value='Untitled.txt']")
    assert has_element?(view, "#unplaced-save-destination", "Not yet numbered")
    refute has_element?(view, "#unplaced-save-destination", "Next List")

    render_submit(view, "save_file", %{
      "writing" => %{
        "body" => "A transcription",
        "unplaced" => "true",
        "notebook_id" => to_string(notebook.id)
      }
    })

    assert {:ok, [saved]} = Files.list(location)
    assert saved.relative_path == "Notebook 1/Unplaced/A_transcription.txt"
    assert is_nil(saved.list_label)
    assert has_element?(view, "#rename-menu-name[value='A_transcription.txt']")
  end

  test "switching back to the numbered destination does not retain Unplaced", %{
    conn: conn,
    location: location,
    notebook: notebook
  } do
    {:ok, view, _} = live(conn, "/?notebook=#{notebook.id}&unplaced=true")
    view |> form("#file-writing-form", writing: %{body: "", unplaced: ""}) |> render_change()
    assert has_element?(view, "#rename-menu-name[value='1_Untitled.txt']")
    assert has_element?(view, "#unplaced-save-destination", "Next List 1")

    render_submit(view, "save_file", %{
      "writing" => %{
        "body" => "A numbered piece",
        "unplaced" => "",
        "notebook_id" => to_string(notebook.id)
      }
    })

    assert {:ok, [saved]} = Files.list(location)
    refute saved.unplaced
    assert saved.list_label == "1"
  end

  test "placement previews duplicate numbers and saves the latest editor words before requiring confirmation",
       %{conn: conn, location: location, notebook: notebook} do
    {:ok, first} =
      Files.save_to_unplaced(location, Files.new(location), %{
        body: "Repeated title\nfirst words",
        notebook_id: notebook.id
      })

    {:ok, second} =
      Files.save_to_unplaced(location, Files.new(location), %{
        body: "Repeated title\nsecond words",
        notebook_id: notebook.id
      })

    {:ok, placed_first} =
      Files.place(location, first, %{section: notebook.key, list_label: "1"})

    {:ok, view, _} = live(conn, ~p"/writing/#{second.id}/edit")
    assert has_element?(view, "#place-piece-details summary", "Place in notebook…")
    assert has_element?(view, "#placement-section option[value='#{notebook.key}']")

    view
    |> form("#placement-form", placement: %{section: notebook.key, list_label: "1"})
    |> render_change()

    assert has_element?(view, "#placement-duplicates", "already used")
    assert has_element?(view, "#placement-duplicates", placed_first.relative_path)

    render_submit(view, "save_file", %{
      "file_action" => "place",
      "placement" => %{"section" => notebook.key, "list_label" => "1"},
      "writing" => %{"body" => "Latest revised words"}
    })

    assert has_element?(view, "#file-save-status", "Saved on this Mac")
    assert render(view) =~ "already in use"
    {:ok, after_save} = Poems.get(location, second.id)
    assert after_save.body == "Latest revised words"
    assert after_save.unplaced

    render_submit(view, "save_file", %{
      "file_action" => "place",
      "placement" => %{
        "section" => notebook.key,
        "list_label" => "1",
        "allow_duplicate" => "true"
      },
      "writing" => %{"body" => "Latest revised words"}
    })

    {:ok, placed_second} = Poems.get(location, second.id)
    assert placed_second.body == "Latest revised words"
    assert placed_second.unplaced == false
    assert placed_second.list_label == "1"
    assert placed_second.id == second.id
  end

  test "a malformed notebook query opens a safe new page", %{conn: conn} do
    {:ok, view, _} = live(conn, "/?notebook=not-a-number&unplaced=true")
    assert has_element?(view, "#file-writing-form")
    assert has_element?(view, "#file-writing-body")
  end
end
