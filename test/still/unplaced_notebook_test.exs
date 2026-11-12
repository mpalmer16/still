defmodule Still.UnplacedNotebookTest do
  use Still.DataCase, async: false

  alias Still.Storage
  alias Still.Correspondence
  alias Still.Writing.Files
  alias Still.Writing.PoemReferences

  setup do
    root = Path.join(System.tmp_dir!(), "still-unplaced-#{Ecto.UUID.generate()}")
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

  test "saving to Unplaced preserves title and does not consume notebook numbering", %{
    location: location
  } do
    notebook = notebook!(location, "Notebook 12")

    assert {:ok, saved} =
             Files.save_to_unplaced(location, Files.new(location), %{
               body: "2030's field notes\n\n  first line\nsecond line\n",
               notebook_id: notebook.id
             })

    assert saved.unplaced
    assert saved.list_label == nil
    assert saved.source_order == nil
    assert saved.relative_path == "Notebook 12/Unplaced/2030's_field_notes.txt"

    assert {:ok, next} =
             Files.save(location, Files.new(location), %{body: "Next", notebook_id: notebook.id})

    assert next.list_label == "1"
    assert next.source_order == 1
  end

  test "ordinary numeric filenames inside Unplaced remain unnumbered", %{
    folder: folder,
    location: location
  } do
    notebook = notebook!(location, "Notebook 2")
    {:ok, _seed} = save_unplaced(location, notebook, "Seed")
    File.write!(Path.join(folder, "Notebook 2/Unplaced/0042_notes.txt"), "External words\n")

    assert {:ok, pieces} = Files.list(location)
    piece = Enum.find(pieces, &(&1.relative_path == "Notebook 2/Unplaced/0042_notes.txt"))
    assert piece.relative_path == "Notebook 2/Unplaced/0042_notes.txt"
    assert piece.list_label == nil
    assert piece.source_order == nil

    assert {:ok, next} =
             Files.save(location, Files.new(location), %{body: "Next", notebook_id: notebook.id})

    assert next.list_label == "1"
  end

  test "placing preserves the piece identity, entry, exact words, and earlier versions", %{
    location: location
  } do
    notebook = notebook!(location, "Notebook 3")

    {:ok, original} =
      Files.save_to_unplaced(location, Files.new(location), %{
        body: "A title\n\n  exact words\nwith a line break\n",
        notebook_id: notebook.id
      })

    {:ok, revised} = Files.save(location, original, %{body: "A title\n\nrevised words\n"})
    versions_before = versions(revised)
    preview = preview!(location, revised, notebook.key, "1")

    assert {:ok, placed} =
             Files.place(location, revised, placement_attrs(preview))

    assert placed.id == revised.id
    assert placed.entry_id == revised.entry_id
    assert placed.body == revised.body
    assert File.read!(placed.path) == revised.body
    assert placed.unplaced == false
    assert versions(placed) == versions_before
    assert placed.relative_path == preview.relative_path
  end

  test "placement preserves a UTF-8 BOM and authored CRLF bytes exactly", %{location: location} do
    notebook = notebook!(location, "Notebook 30")
    body = <<0xEF, 0xBB, 0xBF>> <> "2030 notes\r\n\r\n  indented\r\nlast line\r\n"
    {:ok, original} = save_unplaced(location, notebook, body)
    assert File.read!(original.path) == body

    preview = preview!(location, original, notebook.key, "0005")
    {:ok, placed} = Files.place(location, original, placement_attrs(preview))
    assert placed.id == original.id
    assert File.read!(placed.path) == body
    assert placed.body == original.body
  end

  test "an inserted poem reference and submitted history follow the placed file identity", %{
    location: location
  } do
    notebook = notebook!(location, "Notebook 30a")
    {:ok, source} = save_unplaced(location, notebook, "Source poem\n\nExact source words\r\n")
    marker = PoemReferences.marker(source)
    {:ok, reader} = save_unplaced(location, notebook, "Reader poem\n\nBefore\n#{marker}\nAfter")

    {:ok, journal} = Correspondence.save_journal(location, journal_attrs())

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Synthetic placement history",
        journal_id: journal.id,
        piece_ids: [source.id],
        preparation_notes: nil,
        cover_letter: nil
      })

    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-11-12")
    submitted_body = hd(sent.snapshot.pieces).body

    preview = preview!(location, source, notebook.key, "0006")
    {:ok, placed} = Files.place(location, source, placement_attrs(preview))

    [reference] =
      PoemReferences.resolve(location, reader.body)
      |> Enum.filter(&(&1.kind == :reference))

    assert reference.id == source.id
    assert reference.status == :available
    assert reference.source.relative_path == placed.relative_path

    assert {:ok, [history]} = Correspondence.history(location, source.id)
    assert history.snapshot.body == submitted_body
    assert history.snapshot.body =~ "Exact source words\r\n"
  end

  test "placement accepts suffix labels, gaps, and corrections while retaining identity", %{
    location: location
  } do
    notebook = notebook!(location, "Notebook 4")

    {:ok, first} = save_unplaced(location, notebook, "First title")
    first_preview = preview!(location, first, notebook.key, "0007b")
    {:ok, placed} = Files.place(location, first, placement_attrs(first_preview))
    assert placed.list_label == "0007b"
    assert placed.source_order == 7
    assert placed.relative_path == "Notebook 4/0007b_First_title.txt"

    corrected_preview = preview!(location, placed, notebook.key, "0009")
    {:ok, corrected} = Files.place(location, placed, placement_attrs(corrected_preview))
    assert corrected.id == first.id
    assert corrected.entry_id == first.entry_id
    assert corrected.list_label == "0009"
    assert corrected.source_order == 9
    assert corrected.relative_path == corrected_preview.relative_path
    refute File.exists?(placed.path)

    {:ok, next} =
      Files.save(location, Files.new(location), %{body: "Next", notebook_id: notebook.id})

    assert next.list_label == "0010"
  end

  test "a placed piece can return to Unplaced without consuming a number", %{location: location} do
    notebook = notebook!(location, "Notebook 5")
    {:ok, original} = save_unplaced(location, notebook, "Return trip")
    preview = preview!(location, original, notebook.key, "0003")
    {:ok, placed} = Files.place(location, original, placement_attrs(preview))
    {:ok, returned} = Files.place(location, placed, %{section: "unplaced"})

    assert returned.id == original.id
    assert returned.entry_id == original.entry_id
    assert returned.unplaced
    assert returned.list_label == nil
    assert returned.source_order == nil
    assert returned.relative_path == "Notebook 5/Unplaced/Return_trip.txt"

    {:ok, next} =
      Files.save(location, Files.new(location), %{body: "Next", notebook_id: notebook.id})

    assert next.list_label == "1"
  end

  test "moving a file into and out of Unplaced keeps its identity and associations", %{
    folder: root,
    location: location
  } do
    notebook = notebook!(location, "Notebook 31")
    {:ok, original} = save_unplaced(location, notebook, "Move me")
    placed_path = Path.join(root, "Notebook 31/0008_Move_me.txt")
    File.rename!(original.path, placed_path)

    assert {:ok, [placed]} = Files.list(location)
    assert placed.id == original.id
    assert placed.entry_id == original.entry_id
    assert placed.notebook_id == notebook.id
    assert placed.list_label == "0008"
    assert placed.relative_path == "Notebook 31/0008_Move_me.txt"

    unplaced_path = Path.join(root, "Notebook 31/Unplaced/0008_Move_me.txt")
    File.rename!(placed_path, unplaced_path)
    assert {:ok, [returned]} = Files.list(location)
    assert returned.id == original.id
    assert returned.entry_id == original.entry_id
    assert returned.notebook_id == notebook.id
    assert returned.unplaced
    assert returned.list_label == nil
    assert returned.source_order == nil
  end

  test "renaming the registered Unplaced folder preserves its identity", %{
    folder: root,
    location: location
  } do
    notebook = notebook!(location, "Notebook 32")
    {:ok, original} = save_unplaced(location, notebook, "Folder move")
    moved_folder = Path.join(root, "Notebook 32/Notes to place")
    File.rename!(Path.join(root, "Notebook 32/Unplaced"), moved_folder)

    assert {:ok, [moved]} = Files.list(location)
    assert moved.id == original.id
    assert moved.entry_id == original.entry_id
    assert moved.unplaced
    assert moved.relative_path == "Notebook 32/Notes to place/Folder_move.txt"

    assert {:ok, next} =
             Files.save_to_unplaced(location, Files.new(location), %{
               body: "Another note",
               notebook_id: notebook.id
             })

    assert next.relative_path == "Notebook 32/Notes to place/Another_note.txt"
  end

  test "a missing or replaced Unplaced folder is not silently recreated or adopted", %{
    folder: root,
    location: location
  } do
    notebook = notebook!(location, "Notebook 33")
    {:ok, original} = save_unplaced(location, notebook, "Keep destination")
    unplaced = Path.join(root, "Notebook 33/Unplaced")
    File.rm_rf!(unplaced)

    assert {:error, message} =
             Files.save_to_unplaced(location, Files.new(location), %{
               body: "Must not create a substitute",
               notebook_id: notebook.id
             })

    assert message =~ "unavailable"
    refute File.exists?(unplaced)
    assert original.unplaced

    File.mkdir_p!(unplaced)

    assert {:error, message} =
             Files.save_to_unplaced(location, Files.new(location), %{
               body: "Do not adopt a replacement",
               notebook_id: notebook.id
             })

    assert message =~ "unavailable"
    assert File.ls!(unplaced) == []
  end

  test "numbered notebooks require an explicit nonblank section label", %{location: location} do
    notebook = notebook!(location, "Notebook 6")
    {:ok, piece} = save_unplaced(location, notebook, "Unnumbered destination")

    assert {:error, _} =
             Files.placement_preview(location, piece, %{section: notebook.key, list_label: " "})

    assert {:error, _} = Files.place(location, piece, %{section: notebook.key, list_label: ""})
    assert {:ok, valid} = Files.placement_preview(location, piece, %{section: "unplaced"})
    assert valid.section == "Unplaced"
  end

  test "an existing numbered piece can be corrected before any Unplaced folder exists", %{
    location: location,
    folder: folder
  } do
    notebook = notebook!(location, "Notebook 6a")

    {:ok, saved} =
      Files.save(location, Files.new(location), %{
        body: "Existing piece",
        notebook_id: notebook.id
      })

    assert Still.Writing.NotebookSections.unplaced_section(notebook) == nil

    assert {:ok, preview} =
             Files.placement_preview(location, saved, %{
               section: notebook.key,
               list_label: "0012b"
             })

    assert {:ok, corrected} =
             Files.place(location, saved, %{section: notebook.key, list_label: "0012b"})

    assert corrected.id == saved.id
    assert corrected.relative_path == preview.relative_path
    assert corrected.list_label == "0012b"
    refute File.exists?(Path.join(folder, "Notebook 6a/Unplaced"))
  end

  test "duplicate content is disclosed and needs explicit approval; occupied paths never overwrite",
       %{
         folder: folder,
         location: location
       } do
    notebook = notebook!(location, "Notebook 7")
    {:ok, first} = save_unplaced(location, notebook, "Same words")
    {:ok, second} = save_unplaced(location, notebook, "Same words")
    first_preview = preview!(location, first, notebook.key, "1")
    {:ok, first} = Files.place(location, first, placement_attrs(first_preview))

    assert {:ok, %{duplicates: [%{id: id}]}} =
             Files.placement_preview(location, second, %{
               section: notebook.key,
               list_label: "1"
             })

    assert id == first.id

    assert {:error, _} =
             Files.place(location, second, %{section: notebook.key, list_label: "1"})

    assert {:ok, accepted_preview} =
             Files.placement_preview(location, second, %{
               section: notebook.key,
               list_label: "1",
               allow_duplicate: true
             })

    assert accepted_preview.duplicates != []

    assert {:ok, accepted} =
             Files.place(
               location,
               second,
               placement_attrs(accepted_preview) |> Map.put(:allow_duplicate, true)
             )

    refute accepted.relative_path == first.relative_path
    assert File.read!(first.path) == first.body

    occupied = Path.join(folder, "Notebook 7/2_Same_words.txt")
    File.write!(occupied, "Do not replace")

    assert {:error, _} =
             Files.place(location, second, %{
               section: notebook.key,
               list_label: "2",
               allow_duplicate: true
             })

    assert File.read!(occupied) == "Do not replace"
  end

  test "stale external edits prevent placement", %{location: location} do
    notebook = notebook!(location, "Notebook 8")
    {:ok, piece} = save_unplaced(location, notebook, "Saved words")
    File.write!(piece.path, "Changed outside Still")

    assert {:error, _} = Files.place(location, piece, %{section: notebook.key, list_label: "1"})
    assert File.read!(piece.path) == "Changed outside Still"
  end

  test "folder and placement options identify the notebook's Unplaced section", %{
    location: location
  } do
    notebook = notebook!(location, "Notebook 9")
    {:ok, piece} = save_unplaced(location, notebook, "Options")
    assert {:ok, options} = Files.placement_options(location, piece)
    assert options.notebook == notebook.label
    assert options.unplaced_section == Still.Writing.NotebookSections.unplaced_section(notebook)
    assert options.unplaced_section
    assert Enum.any?(options.sections, &(&1.key == notebook.key))
  end

  test "an interrupted placement recovers its same file and notebook metadata", %{
    folder: folder,
    location: location
  } do
    notebook = notebook!(location, "Notebook 10")

    for stage <- [:before_move, :after_move] do
      {:ok, piece} = save_unplaced(location, notebook, "Recovery #{stage}")
      entry = Still.Repo.get!(Still.Writing.Entry, piece.entry_id)
      target = "Notebook 10/0042_Recovery_#{stage}.txt"

      pending = %{
        "kind" => "rename",
        "target" => target,
        "identity" => entry.source["file_identity"],
        "metadata" => %{
          "notebook_id" => notebook.id,
          "notebook" => notebook.key,
          "list_label" => "0042",
          "source_order" => 42
        }
      }

      entry |> Ecto.Changeset.change(pending: pending) |> Still.Repo.update!()
      if stage == :after_move, do: File.rename!(piece.path, Path.join(folder, target))

      assert {:ok, _} = Files.synchronize(location)
      assert {:ok, recovered} = Files.get(location, piece.id)
      assert recovered.relative_path == target
      assert recovered.list_label == "0042"
      assert recovered.body == piece.body
      assert File.read!(Path.join(folder, target)) == piece.body
      refute File.exists?(piece.path)
    end
  end

  defp notebook!(location, relative) do
    File.mkdir_p!(Path.join(location.folder, relative))
    {:ok, notebook} = Files.register_folder(location, relative, %{label: Path.basename(relative)})
    notebook
  end

  defp save_unplaced(location, notebook, title) do
    Files.save_to_unplaced(location, Files.new(location), %{body: title, notebook_id: notebook.id})
  end

  defp preview!(location, piece, section, label) do
    attrs = %{section: section}
    attrs = if label, do: Map.put(attrs, :list_label, label), else: attrs
    {:ok, preview} = Files.placement_preview(location, piece, attrs)
    preview
  end

  defp placement_attrs(preview), do: %{section: preview.section, list_label: preview.list_label}

  defp journal_attrs do
    %{
      name: "Synthetic journal #{System.unique_integer([:positive])}",
      website: "https://example.invalid",
      submission_url: "https://example.invalid/submit",
      interests: "Synthetic",
      guidelines: "Synthetic only",
      windows: "Unknown",
      fee: "Unknown",
      simultaneous_policy: "unknown",
      response_expectation: nil,
      notes: nil,
      verified: false,
      shortlisted: false
    }
  end

  defp versions(piece) do
    {:ok, revisions} = Files.revisions(Storage.collection_location(), piece.id)
    revisions
  end
end
