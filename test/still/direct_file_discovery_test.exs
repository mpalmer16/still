defmodule Still.DirectFileDiscoveryTest do
  use StillWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Still.{Poems, Repo, Storage, Writing}
  alias Still.Writing.{Entry, Notebooks}

  setup do
    root = Path.join(System.tmp_dir!(), "still-direct-discovery-#{Ecto.UUID.generate()}")
    folder = Path.join(root, "collection")
    File.mkdir_p!(folder)
    old_state = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    assert {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      if old_state,
        do: Application.put_env(:still, :storage_state_directory, old_state),
        else: Application.delete_env(:still, :storage_state_directory)

      File.rm_rf!(root)
    end)

    %{folder: folder, location: Storage.collection_location()}
  end

  test "an ordinary file joins echoes, notebooks, reading, and search then leaves after an unreadable edit",
       %{conn: conn, folder: folder, location: location} do
    {:ok, notebook} =
      Writing.create_notebook(%{key: "Field books/Notebook 7", label: "Field book 7"})

    assert {:ok, _} = Writing.choose_current_notebook(notebook.id)

    archive =
      Repo.insert!(
        Entry.changeset(%Entry{}, %{
          origin: "before",
          body: "saffron compass",
          notebook: "Earlier pages/3",
          source_group: "synthetic-archive-group",
          source_key: "synthetic-archive-source"
        })
      )

    relative = Path.join("Field books", "07b")
    body = "Saffron compass\nvelvet engine ember orbit\n"
    path = Path.join(folder, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)

    assert {:ok, [piece]} = Poems.list(location)
    projected = Repo.get_by!(Entry, file_id: piece.id)

    assert {:ok, _assigned} =
             Notebooks.assign_entry(projected, notebook, %{list_label: "07b", source_order: 7})

    assert {:ok, assigned_piece} = Poems.get(location, piece.id)
    assert {:ok, titled} = Poems.save(location, assigned_piece, %{body: body, title_line: 1})
    file_entry = Repo.get_by!(Entry, file_id: titled.id)

    echo = Writing.echo(archive)
    assert echo
    assert echo.entry.id == file_entry.id

    saved_field = Writing.saved_field(titled)
    refute Enum.any?(saved_field, &(&1.entry.id == file_entry.id))

    notebook_view = Writing.notebook(notebook.key)
    assert notebook_view.count == 1
    assert hd(notebook_view.entries).id == file_entry.id
    assert hd(notebook_view.entries).list_label == "07b"

    assert Enum.any?(Writing.list_entries(query: "velvet"), &(&1.file_id == titled.id))
    {:ok, reading, _html} = live(conn, ~p"/w/#{file_entry.id}?read=1")
    assert has_element?(reading, "[data-echo-line='1']")
    render_hook(reading, "focus_passage", %{"id" => to_string(file_entry.id), "line" => "1"})

    File.write!(path, <<0, 255, 0>>)

    assert Writing.gravity("velvet engine", historical_only: true) == nil
    refute Enum.any?(Writing.list_entries(query: "velvet"), &(&1.file_id == titled.id))
    assert Writing.notebook(notebook.key).entries == []
  end
end
