defmodule Still.NotebookNumberingTest do
  use Still.DataCase, async: false

  alias Still.Storage
  alias Still.Writing.Files

  setup do
    root = Path.join(System.tmp_dir!(), "still-notebook-numbering-#{Ecto.UUID.generate()}")
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

  test "new Lists follow the greatest leading number and retain zero padding", %{
    folder: root,
    location: location
  } do
    notebook = notebook!(location, "Notebook 1")

    for {name, body} <- [{"0003b.txt", "three b"}, {"0003.txt", "three"}, {"0001.txt", "one"}] do
      File.write!(Path.join(root, "Notebook 1/" <> name), body)
    end

    assert {:ok, _} = Files.list(location)

    assert {:ok, saved} =
             Files.save(location, Files.new(location), %{
               body: "Next thought",
               notebook_id: notebook.id
             })

    assert saved.list_label == "0004"
    assert saved.source_order == 4
    assert saved.relative_path == "Notebook 1/0004_Next_thought.txt"
  end

  test "an empty notebook starts at one and consecutive unsaved drafts get distinct labels", %{
    location: location
  } do
    notebook = notebook!(location, "Empty Notebook")
    first_draft = Files.new(location)
    second_draft = Files.new(location)

    assert {:ok, first} =
             Files.save(location, %{first_draft | notebook_id: notebook.id}, %{body: "First"})

    assert {:ok, second} =
             Files.save(location, %{second_draft | notebook_id: notebook.id}, %{body: "Second"})

    assert {first.list_label, second.list_label} == {"1", "2"}
    assert {first.source_order, second.source_order} == {1, 2}
  end

  test "explicit labels override numbering and provide the source order", %{location: location} do
    notebook = notebook!(location, "Notebook 2")

    assert {:ok, saved} =
             Files.save(location, Files.new(location), %{
               body: "Named List",
               notebook_id: notebook.id,
               list_label: "07c"
             })

    assert saved.list_label == "07c"
    assert saved.source_order == 7
    assert saved.relative_path == "Notebook 2/07c_Named_List.txt"
  end

  test "numbering is independent per notebook, including files in sections and the current notebook",
       %{
         folder: root,
         location: location
       } do
    first = notebook!(location, "Year/Notebook 1")
    second = notebook!(location, "Year/Notebook 2")
    File.mkdir_p!(Path.join(root, "Year/Notebook 1/Jan - Mar"))
    File.write!(Path.join(root, "Year/Notebook 1/Jan - Mar/12c.txt"), "section List")
    File.write!(Path.join(root, "Year/Notebook 2/2.txt"), "other notebook")
    assert {:ok, _} = Files.list(location)

    assert {:ok, _} = Still.Writing.Notebooks.choose_current(first.id)

    assert {:ok, saved_current} = Files.save(location, Files.new(location), %{body: "Current"})
    assert saved_current.notebook_id == first.id
    assert saved_current.list_label == "13"

    assert {:ok, saved_other} =
             Files.save(location, Files.new(location), %{
               body: "Independent",
               notebook_id: second.id
             })

    assert saved_other.list_label == "3"
  end

  test "external files count toward the next number and editing a saved List keeps its label", %{
    folder: root,
    location: location
  } do
    notebook = notebook!(location, "Notebook 3")
    File.write!(Path.join(root, "Notebook 3/8a.txt"), "external List")
    assert {:ok, [external]} = Files.list(location)
    assert external.list_label == "8a"

    assert {:ok, new} =
             Files.save(location, Files.new(location), %{
               body: "New words",
               notebook_id: notebook.id
             })

    assert new.list_label == "9"

    assert {:ok, edited} = Files.save(location, new, %{body: "New words, revised"})
    assert edited.list_label == "9"
    assert edited.source_order == 9
    assert edited.relative_path == new.relative_path
  end

  test "a custom relative filename is kept as entered", %{location: location} do
    notebook = notebook!(location, "Notebook 4")

    assert {:ok, saved} =
             Files.save(location, Files.new(location), %{
               body: "Custom location",
               notebook_id: notebook.id,
               relative_path: "Notebook 4/field-notes.txt"
             })

    assert saved.relative_path == "Notebook 4/field-notes.txt"
  end

  test "changing a saved List number updates its filename and notebook order", %{
    location: location
  } do
    notebook = notebook!(location, "Renumbering")

    {:ok, first} =
      Files.save(location, Files.new(location), %{
        body: "Title:\n\nWords",
        notebook_id: notebook.id
      })

    assert {:ok, changed} =
             Files.save(location, first, %{
               body: first.body,
               list_label: "0042b",
               source_order: first.source_order
             })

    assert changed.list_label == "0042b"
    assert changed.source_order == 42
    assert changed.relative_path == "Renumbering/0042b_Title_.txt"
    assert changed.id == first.id
    refute File.exists?(first.path)
    assert File.read!(changed.path) == first.body
    assert {:error, _} = Files.save(location, first, %{body: "Stale words"})

    assert {:ok, next} =
             Files.save(location, Files.new(location), %{body: "Next", notebook_id: notebook.id})

    assert next.list_label == "0043"
  end

  test "an interrupted save and renumber keeps the words and completes its filename", %{
    location: location
  } do
    notebook = notebook!(location, "Recovery")

    for stage <- [:prepared, :published] do
      {:ok, saved} =
        Files.save(location, Files.new(location), %{
          body: "Original #{stage}",
          notebook_id: notebook.id
        })

      entry = Still.Repo.get!(Still.Writing.Entry, saved.entry_id)
      target = "Recovery/42_#{stage}.txt"

      metadata =
        entry
        |> Map.take([:notebook_id, :notebook, :source_order, :list_label])
        |> Map.merge(%{list_label: "42", source_order: 42, rename_target: target})
        |> Map.new(fn {key, value} -> {to_string(key), value} end)

      pending = %{
        "kind" => "save",
        "old_token" => entry.file_token,
        "body" => "Revised #{stage}",
        "prefix" => Base.encode64(entry.file_prefix || ""),
        "stage" => ".still-#{Ecto.UUID.generate()}.partial",
        "metadata" => metadata,
        "title_line" => nil,
        "title_anchor" => nil
      }

      entry |> Ecto.Changeset.change(pending: pending) |> Still.Repo.update!()
      if stage == :published, do: File.write!(saved.path, pending["body"])
      assert {:ok, _} = Files.synchronize(location)
      assert {:ok, recovered} = Files.get(location, saved.id)
      assert recovered.relative_path == target
      assert recovered.list_label == "42"
      assert recovered.body == pending["body"]
      assert File.read!(recovered.path) == pending["body"]
      refute File.exists?(saved.path)
    end
  end

  test "a conflicting correction preserves both files and saved words", %{
    location: location,
    folder: folder
  } do
    notebook = notebook!(location, "Conflict")

    {:ok, first} =
      Files.save(location, Files.new(location), %{body: "Title", notebook_id: notebook.id})

    occupied = Path.join(folder, "Conflict/2_Title.txt")
    File.write!(occupied, "Other words")
    assert {:error, _} = Files.save(location, first, %{body: "Proposed words", list_label: "2"})
    assert File.read!(first.path) == "Title"
    assert File.read!(occupied) == "Other words"
  end

  test "no-notebook writing remains valid without a number", %{location: location} do
    assert {:ok, saved} =
             Files.save(location, Files.new(location), %{body: "A free page", notebook_id: nil})

    assert saved.list_label == nil
    assert saved.relative_path == "A_free_page.txt"
  end

  test "an unnumbered collection preserves filenames and never infers numbers", %{
    location: location,
    folder: folder
  } do
    notebook = notebook!(location, "Poems")
    {:ok, notebook} = Still.Writing.Notebooks.update(notebook, %{numbered: false})
    physical = notebook!(location, "Physical notebook")
    {:ok, _} = Still.Writing.Notebooks.choose_current(physical.id)
    File.write!(Path.join(folder, "Poems/2024 and the rain.txt"), "The rain\n\n  stays\n")
    assert {:ok, [imported]} = Files.synchronize(location)
    assert imported.relative_path == "Poems/2024 and the rain.txt"
    assert imported.list_label == nil
    assert imported.source_order == nil

    assert {:ok, first} =
             Files.save(location, Files.new(location), %{
               body: "Zebra sky",
               notebook_id: notebook.id
             })

    assert {:ok, second} =
             Files.save(location, Files.new(location), %{
               body: "An opening",
               notebook_id: notebook.id
             })

    assert first.relative_path == "Poems/Zebra_sky.txt"
    assert second.relative_path == "Poems/An_opening.txt"
    assert first.list_label == nil
    assert second.source_order == nil
    assert Still.Writing.Notebooks.current().id == physical.id
    detail = Still.Writing.Notebooks.get(notebook.key)
    assert detail.numbered == false

    assert Enum.map(detail.entries, & &1.relative_path) == [
             imported.relative_path,
             second.relative_path,
             first.relative_path
           ]

    {:ok, _} = Still.Writing.Notebooks.choose_current(notebook.id)
    assert {:ok, current} = Files.save(location, Files.new(location), %{body: "Still first"})
    assert current.notebook_id == notebook.id
    assert current.list_label == nil
    assert current.relative_path == "Poems/Still_first.txt"
  end

  defp notebook!(location, relative) do
    File.mkdir_p!(Path.join(location.folder, relative))
    {:ok, notebook} = Files.register_folder(location, relative, %{label: Path.basename(relative)})
    notebook
  end
end
