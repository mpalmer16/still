defmodule Still.PoemReferencesTest do
  use Still.DataCase, async: false

  alias Still.Storage
  alias Still.Writing.{Files, PoemReferences}

  setup do
    root = Path.join(System.tmp_dir!(), "still-poem-references-#{Ecto.UUID.generate()}")
    folder = Path.join(root, "collection")
    File.mkdir_p!(folder)
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    assert {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:still, :storage_state_directory, previous),
        else: Application.delete_env(:still, :storage_state_directory)

      File.rm_rf!(root)
    end)

    %{folder: folder, location: Storage.collection_location()}
  end

  test "parses own-line references and preserves literal text, CRLF and UTF-16 offsets" do
    id = Ecto.UUID.generate()
    marker = "[[poem: folder/caf%C3%A9%7Cname | #{id}]]"
    body = "🪶 start\r\n" <> marker <> "\r\nend\n"

    assert [before, ref, after_ref] = PoemReferences.parse(body)
    assert before == %{kind: :text, raw: "🪶 start\r\n", start_utf16: 0, end_utf16: 10}
    assert ref.kind == :reference
    assert ref.raw == marker
    assert ref.path == "folder/café|name"
    assert ref.id == String.downcase(id)
    assert ref.start_utf16 == 10
    assert ref.end_utf16 == 10 + String.length(marker)
    assert after_ref.raw == "\r\nend\n"

    assert Enum.map(PoemReferences.parse("plain\n[[poem: ../outside | bad]]\n"), & &1.kind) == [
             :text
           ]

    assert Enum.map(PoemReferences.parse("inline [[poem: file | #{id}]]"), & &1.kind) == [:text]
  end

  test "identified markers follow the indexed poem after a move and read its current words", %{
    folder: folder,
    location: location
  } do
    source_path = Path.join(folder, "old name.txt")
    File.write!(source_path, "Original words\n")
    assert {:ok, [source]} = Files.list(location)
    marker = PoemReferences.marker(source)
    assert marker == "[[poem: old name.txt | #{source.id}]]"

    File.rename!(source_path, Path.join(folder, "new name.txt"))
    moved_marker = String.replace(marker, "old name.txt", "new name.txt")
    moved_path = Path.join(folder, "new name.txt")
    File.write!(moved_path, "Updated words 🪶\r\nkept exactly\n")

    assert [leading, ref, trailing] =
             PoemReferences.resolve(location, "Host\r\n" <> moved_marker <> "\r\nEnd",
               current_id: Ecto.UUID.generate()
             )

    assert leading.raw == "Host\r\n"
    assert ref.status == :available
    assert ref.source.id == source.id
    assert ref.source.relative_path == "new name.txt"
    assert ref.source.body == "Updated words 🪶\r\nkept exactly\n"
    assert ref.message == nil
    assert trailing.raw == "\r\nEnd"
  end

  test "expansion inserts current source bytes once and keeps unavailable marker readable", %{
    folder: folder,
    location: location
  } do
    File.write!(Path.join(folder, "source"), "Source\r\nline\n")
    assert {:ok, [source]} = Files.list(location)
    marker = PoemReferences.marker(source)
    missing_id = Ecto.UUID.generate()
    missing_marker = "[[poem: missing | #{missing_id}]]"
    body = "Opening\r\n" <> marker <> "\r\nClosing\n" <> missing_marker

    assert PoemReferences.expand(location, body) ==
             "Opening\r\nSource\r\nline\n\r\nClosing\n" <> missing_marker
  end

  test "path-only markers work, but an ID never falls back to a reused path", %{
    folder: folder,
    location: location
  } do
    File.write!(Path.join(folder, "poem"), "Right words")
    assert {:ok, [source]} = Files.list(location)
    old_id = Ecto.UUID.generate()
    old_id_marker = "[[poem: poem | #{old_id}]]"

    assert [_, path_ref, _] =
             PoemReferences.resolve(location, "[[poem: poem]]", current_id: Ecto.UUID.generate())

    assert path_ref.status == :available
    assert path_ref.source.id == source.id

    File.rm!(Path.join(folder, "poem"))
    assert {:ok, _} = Files.list(location)
    File.write!(Path.join(folder, "poem"), "Different poem")
    assert {:ok, _} = Files.list(location)

    assert [_, stale, _] = PoemReferences.resolve(location, old_id_marker)
    assert stale.status == :unavailable
    assert stale.source == nil
    assert stale.message
  end

  test "symbolic links, traversal, malformed IDs and self links remain unavailable or literal", %{
    folder: folder,
    location: location
  } do
    File.write!(Path.join(folder, "target"), "Outside words")
    assert {:ok, [target]} = Files.list(location)
    File.ln_s!(Path.join(folder, "target"), Path.join(folder, "alias"))

    traversal = "[[poem: ../target | #{target.id}]]"
    bad_id = "[[poem: target | not-a-uuid]]"
    symlink = "[[poem: alias]]"
    self_link = PoemReferences.marker(target)

    assert Enum.all?(PoemReferences.parse(traversal), &(&1.kind == :text))
    assert Enum.all?(PoemReferences.parse(bad_id), &(&1.kind == :text))
    assert Enum.all?(PoemReferences.parse("[[poem: %FF]]"), &(&1.kind == :text))
    assert Enum.all?(PoemReferences.parse("[[poem: a%00b]]"), &(&1.kind == :text))
    assert [_, symlink_ref, _] = PoemReferences.resolve(location, symlink)
    assert symlink_ref.status == :unavailable

    assert [_, self_ref, _] =
             PoemReferences.resolve(location, self_link, current_id: target.id)

    assert self_ref.status == :unavailable
    assert self_ref.message =~ "current poem"
  end

  test "cross-linked poems expand one level without following a backlink", %{
    folder: folder,
    location: location
  } do
    File.write!(Path.join(folder, "first"), "First poem")
    File.write!(Path.join(folder, "second"), "Second poem")
    assert {:ok, pieces} = Files.list(location)
    first = Enum.find(pieces, &(&1.relative_path == "first"))
    second = Enum.find(pieces, &(&1.relative_path == "second"))
    File.write!(second.path, PoemReferences.marker(first))

    assert [_, ref, _] =
             PoemReferences.resolve(location, PoemReferences.marker(second), current_id: first.id)

    assert ref.status == :available
    assert ref.source.body == PoemReferences.marker(first)

    assert PoemReferences.expand(location, PoemReferences.marker(second), current_id: first.id) ==
             PoemReferences.marker(first)
  end

  test "candidate search is bounded, supports cached search and excludes the current poem", %{
    folder: folder,
    location: location
  } do
    File.write!(Path.join(folder, "one"), "blue river")
    File.write!(Path.join(folder, "two"), "blue mountain")
    File.write!(Path.join(folder, "three"), "green field")
    assert {:ok, pieces} = Files.list_read_only(location)
    current = Enum.find(pieces, &(&1.relative_path == "one"))

    assert [%{path: "two", preview: "blue mountain"}] =
             PoemReferences.search(pieces, "blue", current_id: current.id)

    assert length(PoemReferences.candidates(location, "", limit: 1)) == 1
  end

  test "proposed filenames use surrounding words instead of a linked file's marker" do
    marker = "[[poem: Rain.txt | 00000000-0000-4000-8000-000000000001]]"
    destination = %{number: nil, folder: "."}
    assert Files.proposed_path(destination, marker <> "\n\nAn essay") == "An_essay.txt"
    assert Files.proposed_path(destination, marker) == "Untitled.txt"
  end
end
