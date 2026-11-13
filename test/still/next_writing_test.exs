defmodule Still.NextWritingTest do
  use Still.DataCase, async: false

  alias Still.Storage
  alias Still.Writing.Files

  setup do
    root = Path.join(System.tmp_dir!(), "still-next-writing-#{Ecto.UUID.generate()}")
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

  test "continuation follows saved section and computes sequence across sections", %{
    folder: root,
    location: location
  } do
    notebook = notebook!(location, "Notebook 7")
    File.mkdir_p!(Path.join(root, "Notebook 7/First"))
    File.mkdir_p!(Path.join(root, "Notebook 7/Second"))

    {:ok, seed} =
      Files.save(location, Files.new(location), %{
        body: "Earlier",
        notebook_id: notebook.id,
        relative_path: "Notebook 7/First/0012a_Earlier.txt",
        list_label: "0012a"
      })

    {:ok, _} = Still.Writing.NotebookSections.choose(notebook.key, notebook.key <> "/First")

    {:ok, saved} =
      Files.save(location, Files.new(location), %{
        body: "Saved page",
        notebook_id: notebook.id,
        relative_path: "Notebook 7/Second/0015_Saved_page.txt",
        list_label: "0015"
      })

    {:ok, draft} = Files.new_after(location, saved.id, saved.token)
    assert draft.body == ""
    assert draft.token == nil
    assert draft.notebook_id == notebook.id
    assert draft.destination_folder == "Notebook 7/Second"
    assert Files.continuation_location(location, draft.destination_folder).number == "0016"
    {:ok, _} = Still.Writing.NotebookSections.choose(notebook.key, notebook.key <> "/Second")
    {:ok, _} = Still.Writing.NotebookSections.choose(notebook.key, notebook.key <> "/First")

    {:ok, next} =
      Files.save(location, draft, %{
        body: "Next page",
        notebook_id: draft.notebook_id,
        destination_folder: draft.destination_folder
      })

    assert next.relative_path == "Notebook 7/Second/0016_Next_page.txt"
    assert next.list_label == "0016"
    assert File.read!(seed.path) == "Earlier"
  end

  test "an occupied requested path is preserved", %{folder: root, location: location} do
    notebook = notebook!(location, "Notebook 12")

    {:ok, saved} =
      Files.save(location, Files.new(location), %{body: "Saved", notebook_id: notebook.id})

    {:ok, draft} = Files.new_after(location, saved.id, saved.token)
    occupied = Path.join(root, "Notebook 12/Keep.txt")
    File.write!(occupied, "Existing bytes")

    assert {:error, _} =
             Files.save(location, draft, %{
               body: "New page",
               notebook_id: draft.notebook_id,
               destination_folder: draft.destination_folder,
               relative_path: "Notebook 12/Keep.txt"
             })

    assert File.read!(occupied) == "Existing bytes"
  end

  test "an explicit valid path takes precedence over an unavailable continuation folder", %{
    folder: root,
    location: location
  } do
    notebook = notebook!(location, "Notebook 13")
    File.mkdir_p!(Path.join(root, "Notebook 13/Old"))
    File.mkdir_p!(Path.join(root, "Notebook 13/Available"))

    {:ok, saved} =
      Files.save(location, Files.new(location), %{
        body: "Saved",
        notebook_id: notebook.id,
        relative_path: "Notebook 13/Old/Saved.txt"
      })

    {:ok, draft} = Files.new_after(location, saved.id, saved.token)
    File.rm_rf!(Path.join(root, "Notebook 13/Old"))

    assert {:ok, next} =
             Files.save(location, draft, %{
               body: "Explicit destination",
               notebook_id: notebook.id,
               destination_folder: draft.destination_folder,
               relative_path: "Notebook 13/Available/Explicit.txt"
             })

    assert next.relative_path == "Notebook 13/Available/Explicit.txt"
    assert File.read!(next.path) == "Explicit destination"
  end

  test "opening a continuation neither creates a file nor reserves a number", %{
    location: location
  } do
    notebook = notebook!(location, "Notebook 8")

    {:ok, saved} =
      Files.save(location, Files.new(location), %{body: "Saved", notebook_id: notebook.id})

    before = File.ls!(Path.join(location.folder, "Notebook 8"))

    assert {:ok, _draft} = Files.new_after(location, saved.id, saved.token)
    assert File.ls!(Path.join(location.folder, "Notebook 8")) == before

    {:ok, next} =
      Files.save(location, Files.new(location), %{body: "Next", notebook_id: notebook.id})

    assert next.list_label == "2"
  end

  test "continuation stays Unplaced and unnumbered", %{location: location} do
    notebook = notebook!(location, "Notebook 9")

    {:ok, saved} =
      Files.save_to_unplaced(location, Files.new(location), %{
        body: "Saved",
        notebook_id: notebook.id
      })

    {:ok, draft} = Files.new_after(location, saved.id, saved.token)
    assert draft.unplaced

    {:ok, next} =
      Files.save(location, draft, %{
        body: "Next unplaced",
        notebook_id: draft.notebook_id,
        destination_folder: draft.destination_folder
      })

    assert next.unplaced
    assert next.list_label == nil
    assert next.source_order == nil
    assert String.starts_with?(next.relative_path, "Notebook 9/Unplaced/")
  end

  test "continuation preserves Scratch and root destinations regardless of current notebook", %{
    location: location
  } do
    notebook = notebook!(location, "Notebook 10")
    {:ok, _} = Still.Writing.Notebooks.choose_current(notebook.id)

    {:ok, scratch} =
      Files.save_to_scratch(location, Files.new(location), %{
        body: "Scratch words",
        notebook_id: notebook.id
      })

    {:ok, scratch_draft} = Files.new_after(location, scratch.id, scratch.token)
    assert scratch_draft.notebook_id == scratch.notebook_id
    assert scratch_draft.destination_folder == "Scratch"

    {:ok, scratch_next} =
      Files.save(location, scratch_draft, %{
        body: "More scratch",
        notebook_id: scratch.notebook_id,
        destination_folder: "Scratch"
      })

    assert scratch_next.list_label == nil
    assert scratch_next.relative_path == "Scratch/More_scratch.txt"

    {:ok, root_piece} =
      Files.save(location, Files.new(location), %{body: "Root words", notebook_id: nil})

    {:ok, root_draft} = Files.new_after(location, root_piece.id, root_piece.token)
    assert Map.has_key?(root_draft, :notebook_id)
    assert root_draft.notebook_id == nil

    {:ok, root_next} =
      Files.save(location, root_draft, %{
        body: "More root",
        notebook_id: nil,
        destination_folder: "."
      })

    assert root_next.notebook_id == nil
    assert root_next.relative_path == "More_root.txt"
  end

  test "unavailable folder and stale token reject continuation without changing saved bytes", %{
    folder: root,
    location: location
  } do
    notebook = notebook!(location, "Notebook 11")
    File.mkdir_p!(Path.join(root, "Notebook 11/Section"))

    {:ok, saved} =
      Files.save(location, Files.new(location), %{
        body: "Saved exact words",
        notebook_id: notebook.id,
        relative_path: "Notebook 11/Section/Saved.txt"
      })

    assert {:error, _} = Files.new_after(location, saved.id, "stale-token")
    File.rename!(Path.join(root, "Notebook 11/Section"), Path.join(root, "Notebook 11/Moved"))
    assert {:error, _} = Files.new_after(location, saved.id, saved.token)
    assert File.read!(Path.join(root, "Notebook 11/Moved/Saved.txt")) == "Saved exact words"
  end

  defp notebook!(location, relative) do
    File.mkdir_p!(Path.join(location.folder, relative))
    {:ok, notebook} = Files.register_folder(location, relative, %{label: Path.basename(relative)})
    notebook
  end
end
