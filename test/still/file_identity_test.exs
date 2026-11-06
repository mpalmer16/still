defmodule Still.FileIdentityTest do
  use Still.DataCase, async: false

  alias Still.{Repo, Storage}
  alias Still.Writing.{Entry, Files}

  setup do
    root = Path.join(System.tmp_dir!(), "still-file-identity-#{Ecto.UUID.generate()}")
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

  test "swapped paths follow unique file identities without creating revisions", %{
    folder: folder,
    location: location
  } do
    File.mkdir_p!(Path.join(folder, "First"))
    File.mkdir_p!(Path.join(folder, "Second"))
    first_path = Path.join(folder, "First/1.txt")
    second_path = Path.join(folder, "Second/2.txt")
    File.write!(first_path, "First title\n\nFirst words")
    File.write!(second_path, "Second words")

    assert {:ok, pieces} = Files.list(location)
    first = Enum.find(pieces, &(&1.body == "First title\n\nFirst words"))
    second = Enum.find(pieces, &(&1.body == "Second words"))
    assert {:ok, titled} = Files.set_title_role(location, first, 1)
    assert {:ok, first_versions} = Files.revisions(location, titled.id)
    assert {:ok, second_versions} = Files.revisions(location, second.id)

    temp = Path.join(folder, "swap.tmp")
    File.rename!(first_path, temp)
    File.rename!(second_path, first_path)
    File.rename!(temp, second_path)

    assert {:ok, swapped} = Files.list(location)
    by_id = Map.new(swapped, &{&1.id, &1})
    assert by_id[titled.id].relative_path == "Second/2.txt"
    assert by_id[titled.id].body == titled.body
    assert by_id[titled.id].entry_id == titled.entry_id
    assert by_id[titled.id].title_line == 1
    assert by_id[titled.id].notebook_id == second.notebook_id
    assert by_id[second.id].relative_path == "First/1.txt"
    assert by_id[second.id].body == second.body
    assert by_id[second.id].entry_id == second.entry_id
    assert by_id[second.id].notebook_id == first.notebook_id
    assert {:ok, ^first_versions} = Files.revisions(location, titled.id)
    assert {:ok, ^second_versions} = Files.revisions(location, second.id)
  end

  test "a moved file keeps its identity when a distinct equal-text file takes its old path", %{
    folder: folder,
    location: location
  } do
    original_path = Path.join(folder, "one.txt")
    File.write!(original_path, "same words")
    assert {:ok, [original]} = Files.list(location)

    File.rename!(original_path, Path.join(folder, "moved.txt"))
    File.write!(original_path, "same words")

    assert {:ok, pieces} = Files.list(location)
    assert length(pieces) == 2
    moved = Enum.find(pieces, &(&1.relative_path == "moved.txt"))
    replacement = Enum.find(pieces, &(&1.relative_path == "one.txt"))
    assert moved.id == original.id
    assert moved.entry_id == original.entry_id
    assert replacement.id != original.id
    assert replacement.entry_id != original.entry_id
    assert moved.body == replacement.body
    assert {:ok, []} = Files.revisions(location, original.id)
  end

  test "an atomic edit at the same path retains identity and checkpoints earlier words", %{
    folder: folder,
    location: location
  } do
    path = Path.join(folder, "one.txt")
    File.write!(path, "Earlier words")
    assert {:ok, [original]} = Files.list(location)

    replacement = Path.join(folder, "replacement.tmp")
    File.write!(replacement, "Current words")
    File.rename!(replacement, path)

    assert {:ok, [updated]} = Files.list(location)
    assert updated.id == original.id
    assert updated.entry_id == original.entry_id
    assert updated.body == "Current words"
    assert {:ok, [%{body: "Earlier words"}]} = Files.revisions(location, original.id)
  end

  test "a moved file occupying a deleted writing's path requires explicit resolution", %{
    folder: folder,
    location: location
  } do
    first_path = Path.join(folder, "one.txt")
    second_path = Path.join(folder, "two.txt")
    File.write!(first_path, "First words")
    File.write!(second_path, "Second words")
    assert {:ok, pieces} = Files.list(location)
    first = Enum.find(pieces, &(&1.body == "First words"))
    second = Enum.find(pieces, &(&1.body == "Second words"))

    File.rm!(second_path)
    File.rename!(first_path, second_path)

    assert {:error, message} = Files.list(location)
    assert message =~ "indexed writing's path now holds a different file"
    assert File.read!(second_path) == "First words"
    assert Repo.get!(Entry, first.entry_id).relative_path == "one.txt"
    assert Repo.get!(Entry, second.entry_id).relative_path == "two.txt"

    File.rename!(second_path, Path.join(folder, "moved.txt"))
    assert {:ok, [moved]} = Files.list(location)
    assert moved.id == first.id
    assert moved.relative_path == "moved.txt"
    assert Repo.get!(Entry, second.entry_id).file_missing
  end

  test "a previously missing file at the same path waits for explicit confirmation", %{
    folder: folder,
    location: location
  } do
    for {name, equal?} <- [{"equal.txt", true}, {"different.txt", false}] do
      path = Path.join(folder, name)
      replacement = Path.join(Path.dirname(folder), "replacement-#{name}")
      original_words = "Original #{name} words"
      replacement_words = if equal?, do: original_words, else: "Different words"
      File.write!(path, original_words)
      File.write!(replacement, replacement_words)
      assert {:ok, pieces} = Files.list(location)
      original = Enum.find(pieces, &(&1.relative_path == name))

      File.rm!(path)
      assert {:ok, _} = Files.list(location)
      assert Repo.get!(Entry, original.entry_id).file_missing

      File.rename!(replacement, path)
      assert {:ok, pieces} = Files.list(location)
      refute Enum.any?(pieces, &(&1.id == original.id))
      assert File.read!(path) == replacement_words
      assert Repo.get!(Entry, original.entry_id).file_missing
      assert Repo.get!(Entry, original.entry_id).body == original_words

      assert {:ok, %{missing: missing, ambiguous: ambiguous}} = Files.reconciliation(location)
      assert Enum.any?(missing, &(&1.id == original.id))

      if equal?,
        do: assert(Enum.any?(ambiguous, &(&1.id == original.id and name in &1.candidates)))

      assert {:ok, confirmed} = Files.relink(location, original.id, name)
      assert confirmed.id == original.id
      assert confirmed.body == replacement_words

      if !equal? do
        assert {:ok, versions} = Files.revisions(location, original.id)
        assert Enum.any?(versions, &(&1.body == original_words))
      end

      File.rm!(path)
    end
  end

  test "a file returning with the same inode reconnects after a missing scan", %{
    folder: folder,
    location: location
  } do
    path = Path.join(folder, "one.txt")
    aside = Path.join(Path.dirname(folder), "aside.txt")
    File.write!(path, "Original words")
    assert {:ok, [original]} = Files.list(location)

    File.rename!(path, aside)
    assert {:ok, []} = Files.list(location)
    assert Repo.get!(Entry, original.entry_id).file_missing

    File.rename!(aside, path)
    assert {:ok, [returned]} = Files.list(location)
    assert returned.id == original.id
    assert returned.entry_id == original.entry_id
    assert returned.body == original.body
  end

  test "an exact copy elsewhere cannot assign a different replacement to the old identity", %{
    folder: folder,
    location: location
  } do
    original_path = Path.join(folder, "one.txt")
    copied_path = Path.join(folder, "copied.txt")
    replacement = Path.join(Path.dirname(folder), "replacement.txt")
    File.write!(original_path, "Original words")
    assert {:ok, [original]} = Files.list(location)

    File.cp!(original_path, copied_path)
    File.write!(replacement, "Different writing")
    File.rm!(original_path)
    File.rename!(replacement, original_path)

    assert {:ok, []} = Files.list(location)
    assert Repo.get!(Entry, original.entry_id).body == "Original words"
    assert Repo.get!(Entry, original.entry_id).file_missing
    assert File.read!(original_path) == "Different writing"
    assert File.read!(copied_path) == "Original words"

    assert {:ok, %{ambiguous: [%{id: id, candidates: ["copied.txt"]}]}} =
             Files.reconciliation(location)

    assert id == original.id
  end

  test "a copied file at another indexed path cannot take that writing's identity", %{
    folder: folder,
    location: location
  } do
    first_path = Path.join(folder, "one.txt")
    second_path = Path.join(folder, "two.txt")
    File.write!(first_path, "First words")
    File.write!(second_path, "Second words")
    assert {:ok, pieces} = Files.list(location)
    first = Enum.find(pieces, &(&1.body == "First words"))
    second = Enum.find(pieces, &(&1.body == "Second words"))

    File.rm!(second_path)
    File.cp!(first_path, second_path)
    File.rm!(first_path)

    assert {:ok, []} = Files.list(location)
    assert Repo.get!(Entry, first.entry_id).body == "First words"
    assert Repo.get!(Entry, second.entry_id).body == "Second words"
    assert Repo.get!(Entry, first.entry_id).file_missing
    assert Repo.get!(Entry, second.entry_id).file_missing

    assert {:ok, %{ambiguous: [%{id: id, candidates: ["two.txt"]}]}} =
             Files.reconciliation(location)

    assert id == first.id
  end
end
