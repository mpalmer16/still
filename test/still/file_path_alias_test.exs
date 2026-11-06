defmodule Still.FilePathAliasTest do
  use Still.DataCase, async: false

  alias Still.{Repo, Storage}
  alias Still.Writing.{Entry, Files}

  setup do
    root = Path.join(System.tmp_dir!(), "still-file-path-alias-#{Ecto.UUID.generate()}")
    folder = Path.join(root, "collection")
    File.mkdir_p!(Path.join(folder, "notes"))

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

  test "adding a file cannot index an already indexed file through a parent path", %{
    folder: folder,
    location: location
  } do
    path = Path.join(folder, "écho without extension")
    File.write!(path, "  Authored words\r\n\tremain intact\n")
    assert {:ok, [original]} = Files.list(location)

    assert {:error, _} = Files.adopt(location, "notes/../écho without extension")
    assert {:error, _} = Files.adopt(location, "notes//../écho without extension")
    assert {:ok, [only]} = Files.list(location)
    assert only.id == original.id
    assert File.read!(path) == "  Authored words\r\n\tremain intact\n"

    assert {:ok, nested} =
             Files.save(location, Files.new(location), %{
               relative_path: "notes/another écho",
               body: "Nested writing\n"
             })

    assert nested.relative_path == "notes/another écho"
    assert File.read!(nested.path) == "Nested writing\n"
  end

  test "reconnecting a missing file cannot claim another indexed file through an alias", %{
    folder: folder,
    location: location
  } do
    missing_path = Path.join(folder, "missing")
    kept_path = Path.join(folder, "kept")
    File.write!(missing_path, "Missing writing")
    File.write!(kept_path, "Keep this writing")
    assert {:ok, pieces} = Files.list(location)
    missing = Enum.find(pieces, &(&1.relative_path == "missing"))
    kept = Enum.find(pieces, &(&1.relative_path == "kept"))

    File.rm!(missing_path)
    assert {:ok, [^kept]} = Files.list(location)

    assert {:error, _} = Files.relink(location, missing.id, "notes/../kept")
    assert Repo.get!(Entry, missing.entry_id).file_missing
    assert Repo.get!(Entry, missing.entry_id).body == "Missing writing"
    assert {:ok, current} = Files.get(location, kept.id)
    assert current.id == kept.id
    assert current.body == "Keep this writing"
    assert File.read!(kept_path) == "Keep this writing"
  end

  test "case and Unicode aliases cannot add an indexed file a second time", %{
    folder: folder,
    location: location
  } do
    kept_path = Path.join(folder, "notes/Kept")
    accented_path = Path.join(folder, "notes/café")
    File.write!(kept_path, "Case-preserved words")
    File.write!(accented_path, "Unicode-preserved words")
    assert {:ok, indexed} = Files.list(location)
    assert length(indexed) == 2

    case_alias = "NOTES/kEpT"
    unicode_alias = "notes/" <> String.normalize("café", :nfd)

    assert {:error, _} = Files.adopt(location, case_alias)
    assert {:error, _} = Files.adopt(location, unicode_alias)
    assert {:ok, visible} = Files.list(location)
    assert MapSet.new(visible, & &1.id) == MapSet.new(indexed, & &1.id)
    assert File.read!(kept_path) == "Case-preserved words"
    assert File.read!(accented_path) == "Unicode-preserved words"
  end

  test "reconnecting a missing file cannot claim an indexed case alias", %{
    folder: folder,
    location: location
  } do
    kept_path = Path.join(folder, "notes/Kept")
    missing_path = Path.join(folder, "missing")
    File.write!(kept_path, "Keep this writing")
    File.write!(missing_path, "Earlier writing")
    assert {:ok, indexed} = Files.list(location)
    kept = Enum.find(indexed, &(&1.relative_path == "notes/Kept"))
    missing = Enum.find(indexed, &(&1.relative_path == "missing"))

    File.rm!(missing_path)
    assert {:ok, [^kept]} = Files.list(location)

    assert {:error, _} = Files.relink(location, missing.id, "NOTES/kEpT")
    assert Repo.get!(Entry, missing.entry_id).file_missing
    assert Repo.get!(Entry, missing.entry_id).body == "Earlier writing"
    assert File.read!(kept_path) == "Keep this writing"
  end

  test "an unindexed alias adopts the file's listed case and Unicode spelling", %{
    folder: folder,
    location: location
  } do
    kept_path = Path.join(folder, "notes/Kept")
    accented_path = Path.join(folder, "notes/café")
    File.write!(kept_path, "Case-preserved words")
    File.write!(accented_path, "Unicode-preserved words")

    case_alias = "NOTES/kEpT"
    unicode_alias = "notes/" <> String.normalize("café", :nfd)

    requested_case =
      if File.regular?(Path.join(folder, case_alias)), do: case_alias, else: "notes/Kept"

    requested_unicode =
      if File.regular?(Path.join(folder, unicode_alias)),
        do: unicode_alias,
        else: "notes/café"

    assert {:ok, kept} = Files.adopt(location, requested_case)
    assert {:ok, accented} = Files.adopt(location, requested_unicode)
    assert kept.relative_path == "notes/Kept"
    assert accented.relative_path == "notes/café"
    assert kept.id != accented.id
    assert File.read!(kept_path) == "Case-preserved words"
    assert File.read!(accented_path) == "Unicode-preserved words"
  end

  test "distinct hardlink names keep separate writing identities", %{
    folder: folder,
    location: location
  } do
    first_path = Path.join(folder, "first")
    second_path = Path.join(folder, "second")
    File.write!(first_path, "Shared bytes, separate names")
    File.ln!(first_path, second_path)

    assert {:ok, first} = Files.adopt(location, "first")
    assert {:ok, second} = Files.adopt(location, "second")
    assert first.id != second.id
    assert first.entry_id != second.entry_id
    assert File.stat!(first_path).inode == File.stat!(second_path).inode
    assert {:ok, pieces} = Files.list(location)
    assert MapSet.new(pieces, & &1.id) == MapSet.new([first.id, second.id])
    assert File.read!(first_path) == "Shared bytes, separate names"
    assert File.read!(second_path) == "Shared bytes, separate names"
  end
end
