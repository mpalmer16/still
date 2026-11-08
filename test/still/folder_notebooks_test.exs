defmodule Still.FolderNotebooksTest do
  use Still.DataCase, async: false

  alias Still.Storage
  alias Still.Writing.Files
  alias Still.Writing.Notebook
  alias Still.Repo

  setup do
    root = Path.join(System.tmp_dir!(), "still-folder-notebooks-#{Ecto.UUID.generate()}")
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

  test "discovers ordinary directories, skips sections under a notebook, and keeps numbered order",
       %{folder: root, location: location} do
    File.mkdir_p!(Path.join(root, "Year/Notebook 1/Jan - Mar"))
    File.write!(Path.join(root, "Year/Notebook 1/10b.txt"), "tenth")
    File.write!(Path.join(root, "Year/Notebook 1/10a.txt"), "ten alpha")
    File.write!(Path.join(root, "Year/Notebook 1/23.1.txt"), "twenty three one")
    File.write!(Path.join(root, "Year/Notebook 1/23.2.txt"), "twenty three two")
    File.write!(Path.join(root, "Year/Notebook 1/2.txt"), "second")
    File.write!(Path.join(root, ".DS_Store"), <<0, 1>>)

    assert {:ok, pieces} = Files.list(location)
    [notebook] = Repo.all(from n in Notebook, where: not is_nil(n.collection_scope))
    assert notebook.relative_path == "Year/Notebook 1"
    assert notebook.collection_scope == location.scope

    assert Enum.map(pieces, &{&1.relative_path, &1.notebook_id, &1.list_label, &1.source_order}) ==
             [
               {"Year/Notebook 1/2.txt", notebook.id, "2", 2},
               {"Year/Notebook 1/10a.txt", notebook.id, "10a", 10},
               {"Year/Notebook 1/10b.txt", notebook.id, "10b", 10},
               {"Year/Notebook 1/23.1.txt", notebook.id, "23.1", 23},
               {"Year/Notebook 1/23.2.txt", notebook.id, "23.2", 23}
             ]
  end

  test "registers existing and empty folders; new writing saves inside selected notebook", %{
    folder: root,
    location: location
  } do
    File.mkdir_p!(Path.join(root, "Current/Notebook 4"))

    assert {:ok, notebook} =
             Files.register_folder(location, "Current/Notebook 4", %{
               key: "Current/Notebook 4",
               label: "Notebook 4"
             })

    assert {:ok, _} =
             Files.create_folder(location, "New shelves/Empty", %{key: "Empty", label: "Empty"})

    draft = Files.new(location)

    assert {:ok, saved} =
             Files.save(location, %{draft | notebook_id: notebook.id}, %{body: "A first list"})

    assert saved.relative_path == "Current/Notebook 4/1_A_first_list.txt"
    assert File.read!(Path.join(root, saved.relative_path)) == "A first list"
  end

  test "directory inode rename preserves notebook and writing identity; changing an existing association is rejected",
       %{folder: root, location: location} do
    old_dir = Path.join(root, "Old")
    File.mkdir_p!(old_dir)
    File.write!(Path.join(old_dir, "3.txt"), "same words")
    assert {:ok, [piece]} = Files.list(location)
    notebook = Repo.get_by!(Notebook, collection_scope: location.scope, relative_path: "Old")
    File.rename!(old_dir, Path.join(root, "New"))

    assert {:ok, [moved]} = Files.list(location)
    assert moved.id == piece.id
    assert moved.notebook_id == notebook.id
    assert moved.relative_path == "New/3.txt"
    assert Repo.get!(Notebook, notebook.id).relative_path == "New"

    assert {:error, message} = Files.save(location, moved, %{body: moved.body, notebook_id: nil})
    assert message =~ "Move it into the chosen notebook folder"
  end

  test "an explicit no-notebook choice saves at the collection root", %{
    folder: root,
    location: location
  } do
    File.mkdir_p!(Path.join(root, "Bound"))

    assert {:ok, notebook} =
             Files.register_folder(location, "Bound", %{key: "Bound", label: "Bound"})

    draft = %{Files.new(location) | notebook_id: notebook.id}

    assert {:ok, saved} = Files.save(location, draft, %{body: "A root List", notebook_id: nil})
    assert saved.relative_path == "A_root_List.txt"
    assert is_nil(saved.notebook_id)
  end

  test "matching folder keys in separate roots remain distinct and scoped", %{
    folder: first_root,
    location: first_location
  } do
    File.mkdir_p!(Path.join(first_root, "Notebook 1"))

    assert {:ok, first} =
             Files.register_folder(first_location, "Notebook 1", %{
               key: "Notebook 1",
               label: "Notebook 1"
             })

    second_root = Path.join(Path.dirname(first_root), "second-collection")
    File.mkdir_p!(Path.join(second_root, "Notebook 1"))
    assert {:ok, _} = Storage.set_folder(second_root)
    second_location = Storage.collection_location()

    assert {:ok, second} =
             Files.register_folder(second_location, "Notebook 1", %{
               key: "Notebook 1",
               label: "Notebook 1"
             })

    assert first.id != second.id
    assert first.key != second.key
    assert Enum.any?(Still.Writing.Notebooks.all(), &(&1.key == second.key))
    refute Enum.any?(Still.Writing.Notebooks.all(), &(&1.key == first.key))

    assert {:ok, _} = Storage.set_folder(first_root)
    File.rm_rf!(second_root)
  end

  test "moving a file between notebooks retains its title role, earlier words and identity", %{
    folder: root,
    location: location
  } do
    assert {:ok, first} = Files.create_folder(location, "First", %{label: "First"})
    assert {:ok, second} = Files.create_folder(location, "Second", %{label: "Second"})

    assert {:ok, original} =
             Files.save(location, Files.new(location), %{
               body: "A title\n\nEarlier words",
               title_line: 1,
               notebook_id: first.id
             })

    assert {:ok, revised} =
             Files.save(location, original, %{
               body: "A title\n\nCurrent words",
               title_line: 1,
               list_label: "07c",
               source_order: 7
             })

    File.rename!(Path.join(root, revised.relative_path), Path.join(root, "Second/Untitled.txt"))

    assert {:ok, [moved]} = Files.list(location)
    assert moved.id == revised.id
    assert moved.entry_id == revised.entry_id
    assert moved.notebook_id == second.id
    assert moved.body == revised.body
    assert moved.title_line == 1
    assert moved.list_label == "07c"
    assert moved.source_order == 7
    assert {:ok, versions} = Files.revisions(location, moved.id)
    assert Enum.any?(versions, &(&1.body == original.body))
  end

  test "a registered physical notebook retains its sections and natural List order", %{
    folder: root,
    location: location
  } do
    relative = "Current Notebooks/2026/Notebook 1"
    File.mkdir_p!(Path.join(root, relative <> "/Jan - Mar"))
    assert {:ok, notebook} = Files.register_folder(location, relative, %{label: "Notebook 1"})

    for name <- ["23.2", "2", "23.1", "10"] do
      File.write!(Path.join(root, relative <> "/Jan - Mar/" <> name <> ".txt"), name)
    end

    File.write!(Path.join(root, relative <> "/1.txt"), "First root piece")
    assert {:ok, _} = Files.list(location)
    found = Still.Writing.Notebooks.get(notebook.key)
    assert Enum.map(found.sections, & &1.label) == ["Notebook 1", "Jan - Mar"]

    assert Enum.map(List.last(found.sections).entries, & &1.list_label) == [
             "2",
             "10",
             "23.1",
             "23.2"
           ]

    assert Enum.all?(found.entries, &(&1.notebook_id == notebook.id))
  end

  test "failed folder creation leaves no empty shells and refuses traversal", %{
    folder: root,
    location: location
  } do
    assert {:error, %Ecto.Changeset{}} =
             Files.create_folder(location, "New/Invalid", %{label: String.duplicate("x", 201)})

    refute File.exists?(Path.join(root, "New"))
    assert {:error, _} = Files.create_folder(location, "Inside/../Outside", %{label: "Invalid"})
    refute File.exists?(Path.join(root, "Inside"))
  end

  test "section names persist without altering files, identities or earlier words", %{
    folder: root,
    location: location
  } do
    relative = "Current Notebooks/2026/Notebook 1"
    File.mkdir_p!(Path.join(root, relative <> "/Jan - Mar"))
    File.mkdir_p!(Path.join(root, relative <> "/Apr - Nov"))
    {:ok, notebook} = Files.register_folder(location, relative, %{label: "Notebook 1"})
    File.write!(Path.join(root, relative <> "/Jan - Mar/10.txt"), "Early words")
    File.write!(Path.join(root, relative <> "/Apr - Nov/155.txt"), "Later words")
    {:ok, pieces} = Files.list(location)
    later = Enum.find(pieces, &(&1.list_label == "155"))
    {:ok, revised} = Files.save(location, later, %{body: "Later words revised"})

    section = notebook.key <> "/Apr - Nov"

    assert {:ok, _} =
             Still.Writing.NotebookSections.order(notebook.key, [
               notebook.key <> "/Jan - Mar",
               section
             ])

    assert {:ok, _} =
             Still.Writing.NotebookSections.rename(
               notebook.key,
               section,
               "April through November"
             )

    assert Enum.map(Still.Writing.Notebooks.get(notebook.key).sections, & &1.label) == [
             "Jan - Mar",
             "April through November"
           ]

    assert {:ok, same} = Files.get(location, later.id)
    assert same.relative_path == revised.relative_path
    assert same.body == revised.body
    assert {:ok, versions} = Files.revisions(location, later.id)
    assert Enum.any?(versions, &(&1.body == "Later words"))
    assert {:error, _} = Still.Writing.NotebookSections.rename(notebook.key, section, "  ")

    assert {:error, _} =
             Still.Writing.NotebookSections.choose(notebook.key, notebook.key <> "/../Other")
  end

  test "new Lists use the selected section, continue notebook numbering, and never redirect an edit",
       %{folder: root, location: location} do
    relative = "Current Notebooks/2026/Notebook 1"
    File.mkdir_p!(Path.join(root, relative <> "/Jan - Mar"))
    File.mkdir_p!(Path.join(root, relative <> "/Apr - Nov"))
    {:ok, notebook} = Files.register_folder(location, relative, %{label: "Notebook 1"})
    File.write!(Path.join(root, relative <> "/Jan - Mar/10.txt"), "Earlier")
    File.write!(Path.join(root, relative <> "/Apr - Nov/155.txt"), "Later")
    assert {:ok, _} = Files.list(location)

    assert {:ok, _} =
             Still.Writing.NotebookSections.choose(notebook.key, notebook.key <> "/Apr - Nov")

    assert Still.Writing.Notebooks.current().id == notebook.id
    assert {:ok, saved} = Files.save(location, Files.new(location), %{body: "Next words"})
    assert saved.list_label == "156"
    assert saved.relative_path == relative <> "/Apr - Nov/156_Next_words.txt"

    assert {:ok, _} =
             Still.Writing.NotebookSections.choose(notebook.key, notebook.key <> "/Jan - Mar")

    assert {:ok, edited} = Files.save(location, saved, %{body: "Next words revised"})
    assert edited.relative_path == saved.relative_path

    assert {:ok, explicit} =
             Files.save(location, Files.new(location), %{
               body: "Explicit",
               notebook_id: notebook.id,
               relative_path: relative <> "/Apr - Nov/160.txt"
             })

    assert explicit.relative_path == relative <> "/Apr - Nov/160.txt"
    File.rm_rf!(Path.join(root, relative <> "/Jan - Mar"))

    assert {:error, _} =
             Files.save(location, Files.new(location), %{body: "Must not land elsewhere"})
  end

  test "Scratch keeps exact words unnumbered and leaves the current notebook sequence alone", %{
    location: location,
    folder: root
  } do
    {:ok, book} = Files.create_folder(location, "Notebook 9", %{label: "Notebook 9"})
    {:ok, _} = Still.Writing.Notebooks.choose_current(book.id)
    {:ok, first} = Files.save(location, Files.new(location), %{body: "Notebook words"})
    assert first.list_label == "1"
    body = "A scratch thought\n\n\t  with its spaces  \n"

    assert {:ok, scratch} =
             Files.save_to_scratch(location, Files.new(location), %{
               body: body,
               notebook_id: book.id,
               list_label: "99",
               relative_path: "Wrong.txt"
             })

    assert scratch.relative_path == "Scratch/A_scratch_thought.txt"
    assert scratch.list_label == nil
    assert File.read!(scratch.path) == body
    assert Still.Writing.Notebooks.current().id == book.id
    assert {:ok, edited} = Files.save(location, scratch, %{body: body <> "more"})
    assert edited.relative_path == scratch.relative_path
    assert {:error, _} = Files.save_to_scratch(location, edited, %{body: "No relocation"})
    assert {:ok, next} = Files.save(location, Files.new(location), %{body: "Next notebook words"})
    assert next.list_label == "2"
    File.rm_rf!(Path.join(root, "Scratch"))

    assert {:error, _} =
             Files.save_to_scratch(location, Files.new(location), %{
               body: "Keep this recovery copy"
             })

    refute File.exists?(Path.join(root, "Scratch"))
  end
end
