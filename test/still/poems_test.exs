defmodule Still.PoemsTest do
  use ExUnit.Case, async: false

  alias Still.{Poems, Storage}

  setup do
    root = Path.join(System.tmp_dir!(), "still-poems-test-#{System.unique_integer([:positive])}")
    folder = Path.join(root, "collection")
    state = Path.join(root, "state")
    File.mkdir_p!(folder)
    old_state = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, state)
    assert {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      if old_state,
        do: Application.put_env(:still, :storage_state_directory, old_state),
        else: Application.delete_env(:still, :storage_state_directory)

      File.rm_rf!(root)
    end)

    %{folder: folder, root: root}
  end

  test "creates, lists, reopens and preserves exact text", %{folder: folder} do
    poem = Poems.new(nil)
    text = "  First line\r\n\tSecond line\n\n"
    assert {:ok, saved} = Poems.save(nil, poem, %{title: nil, body: text})
    assert saved.body == text
    assert saved.title == nil
    assert saved.created_at
    assert saved.updated_at
    assert {:ok, [listed]} = Poems.list(nil)
    assert listed.id == poem.id
    assert {:ok, reopened} = Poems.get(nil, poem.id)
    assert reopened.body == text
    assert reopened.token == saved.token
    assert File.regular?(Path.join([folder, "poems", poem.id, "poem.txt"]))
  end

  test "empty poem can be saved and title changes keep its stable filename" do
    poem = Poems.new(nil)
    assert {:ok, saved} = Poems.save(nil, poem, %{title: "Untitled", body: ""})
    assert saved.path =~ "/poem.txt"
    assert {:ok, titled} = Poems.save(nil, saved, %{title: "A new title", body: ""})
    assert titled.path == saved.path
    assert titled.title == "A new title"
    assert {:ok, [revision]} = Poems.revisions(nil, poem.id)
    assert revision.title == "Untitled"
    assert revision.body == ""
  end

  test "external rename preserves identity and saving archives externally changed words" do
    poem = Poems.new(nil)
    assert {:ok, saved} = Poems.save(nil, poem, %{title: "First", body: "first words"})
    renamed = Path.join(Path.dirname(saved.path), "writer-chosen-name.txt")
    File.rename!(saved.path, renamed)
    assert {:ok, externally_renamed} = Poems.get(nil, poem.id)
    assert externally_renamed.path == renamed
    File.write!(renamed, "outside words\n")

    assert {:error, message} =
             Poems.save(nil, externally_renamed, %{title: "First", body: "later"})

    assert message =~ "changed on disk"
    assert {:ok, fresh} = Poems.get(nil, poem.id)
    assert fresh.body == "outside words\n"
    assert {:ok, saved_again} = Poems.save(nil, fresh, %{title: "First", body: "later"})
    assert {:ok, [revision]} = Poems.revisions(nil, poem.id)
    assert revision.body == "outside words\n"
    assert saved_again.body == "later"
  end

  test "invalid UTF-8 and null bytes are rejected" do
    poem = Poems.new(nil)
    assert {:error, _} = Poems.save(nil, poem, %{title: nil, body: <<255>>})
    assert {:error, _} = Poems.save(nil, poem, %{title: nil, body: "bad" <> <<0>>})
  end

  test "an interrupted two-file save finishes from a verified journal", %{folder: folder} do
    poem = Poems.new(nil)
    assert {:ok, saved} = Poems.save(nil, poem, %{title: "Before", body: "old"})
    dir = Path.dirname(saved.path)
    meta_path = Path.join(dir, "metadata.json")
    old_meta = File.read!(meta_path)

    new_meta =
      Jason.encode!(
        %{
          "id" => poem.id,
          "title" => "After",
          "created_at" => saved.created_at,
          "updated_at" => "2026-10-23T12:00:00Z",
          "filename" => "poem.txt"
        },
        pretty: true
      ) <> "\n"

    journal = %{
      "filename" => "poem.txt",
      "old_body" => Base.encode64("old"),
      "old_metadata" => Base.encode64(old_meta),
      "new_body" => Base.encode64("new"),
      "new_metadata" => Base.encode64(new_meta)
    }

    File.write!(Path.join(dir, ".save-journal.json"), Jason.encode!(journal))
    File.write!(saved.path, "new")

    assert {:ok, reopened} = Poems.get(nil, poem.id)
    assert reopened.body == "new"
    assert reopened.title == "After"
    refute File.exists?(Path.join(dir, ".save-journal.json"))
    assert File.dir?(Path.join(folder, "poems"))
  end

  test "unknown poems folders and symlinks are rejected without adoption", %{folder: folder} do
    poems = Path.join(folder, "poems")
    File.mkdir!(poems)
    File.write!(Path.join(poems, "unrelated.txt"), "keep")
    assert {:error, message} = Poems.list(nil)
    assert message =~ "format marker"
    assert File.read!(Path.join(poems, "unrelated.txt")) == "keep"

    File.rm_rf!(poems)
    outside = Path.join(folder, "outside")
    File.mkdir!(outside)
    File.write!(Path.join(outside, "keep.txt"), "safe")
    File.ln_s!(outside, poems)
    assert {:error, _} = Poems.list(nil)
    assert File.read!(Path.join(outside, "keep.txt")) == "safe"
  end

  test "symlinked metadata and malformed journals are rejected safely", %{folder: folder} do
    poem = Poems.new(nil)
    assert {:ok, saved} = Poems.save(nil, poem, %{title: "Words", body: "keep me"})
    dir = Path.dirname(saved.path)
    outside = Path.join(folder, "outside.json")
    File.write!(outside, "{}")
    metadata = Path.join(dir, "metadata.json")
    original_metadata = File.read!(metadata)
    File.rm!(metadata)
    File.ln_s!(outside, metadata)
    assert {:error, _} = Poems.get(nil, poem.id)
    assert File.read!(outside) == "{}"

    File.rm!(metadata)
    File.write!(metadata, original_metadata)
    File.write!(Path.join(dir, ".save-journal.json"), "{ malformed")
    assert {:error, _} = Poems.get(nil, poem.id)
    assert File.read!(saved.path) == "keep me"
  end

  test "an existing cross-process lock refuses operations and remains untouched", %{
    folder: folder
  } do
    poem = Poems.new(nil)
    assert {:ok, saved} = Poems.save(nil, poem, %{title: nil, body: "keep"})
    lock_dir = Path.join(folder, ".still-poems-lock")
    File.mkdir!(lock_dir)
    File.write!(Path.join(lock_dir, "owner"), "other-instance\n")

    assert {:error, message} = Poems.get(nil, poem.id)
    assert message =~ "Another Still instance"
    assert File.read!(saved.path) == "keep"
    assert File.read!(Path.join(lock_dir, "owner")) == "other-instance\n"
  end

  test "cross-process lock is released after successful and failed operations", %{folder: folder} do
    poem = Poems.new(nil)
    assert {:ok, saved} = Poems.save(nil, poem, %{title: nil, body: "keep"})
    lock_dir = Path.join(folder, ".still-poems-lock")
    refute File.exists?(lock_dir)

    File.rm!(Path.join(Path.dirname(saved.path), "metadata.json"))
    assert {:error, _} = Poems.list(nil)
    refute File.exists?(lock_dir)
  end

  test "an unconfigured collection cannot list or save poems" do
    assert {:ok, _} = Storage.clear_folder()
    assert {:error, _} = Poems.list(nil)
    assert {:error, _} = Poems.save(nil, Poems.new(nil), %{title: nil, body: "words"})
  end

  test "a missing poem metadata file is reported instead of hiding the poem", %{folder: folder} do
    poem = Poems.new(nil)
    assert {:ok, saved} = Poems.save(nil, poem, %{title: nil, body: "words"})
    File.rm!(Path.join(Path.dirname(saved.path), "metadata.json"))
    assert {:error, message} = Poems.list(nil)
    assert message =~ "incomplete"
    assert File.read!(saved.path) == "words"
    assert File.dir?(Path.join(folder, "poems"))
  end

  test "concurrent saves from one snapshot accept one and reject the stale writer" do
    poem = Poems.new(nil)
    assert {:ok, saved} = Poems.save(nil, poem, %{title: "Start", body: "start"})

    results =
      ["first", "second"]
      |> Enum.map(fn body ->
        Task.async(fn -> Poems.save(nil, saved, %{title: "Start", body: body}) end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, message} when is_binary(message), &1)) == 1
    assert {:ok, current} = Poems.get(nil, poem.id)
    assert current.body in ["first", "second"]
  end

  test "a poem snapshot is rejected after the active collection changes", %{root: root} do
    poem = Poems.new(nil)
    assert {:ok, saved} = Poems.save(nil, poem, %{title: nil, body: "words"})
    other = Path.join(root, "other")
    File.mkdir!(other)
    assert {:ok, _} = Storage.set_folder(other)
    assert {:error, message} = Poems.save(nil, saved, %{title: nil, body: "new words"})
    assert message =~ "collection changed"
  end

  test "unavailable or changed collection location refuses writes", %{folder: folder} do
    poem = Poems.new(nil)
    File.rename!(folder, folder <> "-moved")
    assert {:error, _} = Poems.save(nil, poem, %{title: nil, body: "words"})
    assert {:error, _} = Poems.list(nil)
    assert {:error, _} = Poems.list_trash(nil)
  end

  test "trash and restore preserve the complete writing directory and revisions", %{
    folder: folder
  } do
    poem = Poems.new(nil)
    assert {:ok, created} = Poems.save(nil, poem, %{title: "First", body: "original"})
    assert {:ok, saved} = Poems.save(nil, created, %{title: "Second", body: "revised"})
    original_dir = Path.dirname(saved.path)
    before_files = files_under(original_dir)
    assert {:ok, revisions_before} = Poems.revisions(nil, poem.id)
    assert length(revisions_before) == 1

    assert {:ok, trashed} = Poems.trash(nil, saved)
    trash_dir = Path.join([folder, "poems", ".trash", poem.id])
    refute File.exists?(original_dir)
    assert files_under(trash_dir) == before_files
    assert trashed.path == Path.join(trash_dir, "poem.txt")
    assert {:ok, [listed]} = Poems.list_trash(nil)
    assert listed.id == poem.id
    assert listed.token == saved.token

    assert {:ok, restored} = Poems.restore(nil, poem.id)
    assert restored.body == "revised"
    assert restored.path == Path.join(original_dir, "poem.txt")
    assert files_under(original_dir) == before_files
    assert {:ok, revisions_after} = Poems.revisions(nil, poem.id)
    assert revisions_after == revisions_before
    assert {:ok, []} = Poems.list_trash(nil)
  end

  test "restore preserves trash when the original identifier is occupied", %{folder: folder} do
    poem = Poems.new(nil)
    assert {:ok, saved} = Poems.save(nil, poem, %{title: nil, body: "safe words"})
    assert {:ok, trashed} = Poems.trash(nil, saved)
    poems = Path.join(folder, "poems")
    collision = Path.join(poems, poem.id)
    File.mkdir!(collision)
    File.write!(Path.join(collision, "foreign.txt"), "keep")

    assert {:error, message} = Poems.restore(nil, poem.id)
    assert message =~ "already exists"
    assert File.read!(Path.join([poems, ".trash", poem.id, "poem.txt"])) == "safe words"
    assert File.read!(Path.join(collision, "foreign.txt")) == "keep"
    refute is_nil(trashed.token)
  end

  test "trash rejects a stale open snapshot and leaves writing in place", %{folder: folder} do
    poem = Poems.new(nil)
    assert {:ok, saved} = Poems.save(nil, poem, %{title: nil, body: "before"})
    File.write!(saved.path, "changed outside")

    assert {:error, message} = Poems.trash(nil, saved)
    assert message =~ "changed on disk"
    assert File.read!(saved.path) == "changed outside"
    refute File.dir?(Path.join([folder, "poems", ".trash"]))
    assert {:ok, []} = Poems.list_trash(nil)
  end

  test "trash and purge tokens cover revision bytes", %{folder: folder} do
    poem = Poems.new(nil)
    assert {:ok, created} = Poems.save(nil, poem, %{title: "Before", body: "old words"})
    assert {:ok, saved} = Poems.save(nil, created, %{title: "After", body: "current words"})
    revisions_dir = Path.join([folder, "poems", poem.id, "revisions"])
    [revision_name] = File.ls!(revisions_dir)
    revision_body = Path.join([revisions_dir, revision_name, "poem.txt"])

    File.write!(revision_body, "external revision edit")
    assert {:error, stale_trash_message} = Poems.trash(nil, saved)
    assert stale_trash_message =~ "changed on disk"
    assert File.read!(revision_body) == "external revision edit"
    assert File.dir?(Path.join([folder, "poems", poem.id]))

    assert {:ok, refreshed} = Poems.get(nil, poem.id)
    assert {:ok, trashed} = Poems.trash(nil, refreshed)
    assert {:ok, [listed]} = Poems.list_trash(nil)

    trash_revision =
      Path.join([folder, "poems", ".trash", poem.id, "revisions", revision_name, "poem.txt"])

    assert listed.token == trashed.token

    File.write!(trash_revision, "changed after trash listing")
    assert {:error, stale_purge_message} = Poems.purge(nil, poem.id, listed.token, true)
    assert stale_purge_message =~ "changed on disk"
    assert File.read!(trash_revision) == "changed after trash listing"

    assert {:ok, [latest]} = Poems.list_trash(nil)
    refute latest.token == listed.token
    assert :ok = Poems.purge(nil, poem.id, latest.token, true)
  end

  test "permanent deletion requires confirmation and the current trash token", %{folder: folder} do
    poem = Poems.new(nil)
    assert {:ok, created} = Poems.save(nil, poem, %{title: "Keep", body: "words"})
    assert {:ok, saved} = Poems.save(nil, created, %{title: "Keep", body: "later words"})
    assert {:ok, trashed} = Poems.trash(nil, saved)

    assert {:error, message} = Poems.purge(nil, poem.id, trashed.token, false)
    assert message =~ "explicit confirmation"
    trash_path = Path.join([folder, "poems", ".trash", poem.id, "poem.txt"])
    assert File.read!(trash_path) == "later words"

    File.write!(trash_path, "external change")
    assert {:error, stale_message} = Poems.purge(nil, poem.id, trashed.token, true)
    assert stale_message =~ "changed on disk"
    assert File.read!(trash_path) == "external change"

    assert {:ok, [current]} = Poems.list_trash(nil)
    assert :ok = Poems.purge(nil, poem.id, current.token, true)
    refute File.exists?(Path.dirname(trash_path))
    refute File.exists?(Path.join(Path.dirname(trash_path), "revisions"))
    assert {:ok, []} = Poems.list_trash(nil)
  end

  test "missing trash is empty and restore does not create it", %{folder: folder} do
    poem = Poems.new(nil)
    assert {:ok, _saved} = Poems.save(nil, poem, %{title: nil, body: "words"})
    trash = Path.join([folder, "poems", ".trash"])
    File.rm_rf!(trash)

    assert {:ok, []} = Poems.list_trash(nil)
    assert {:error, _} = Poems.restore(nil, poem.id)
    refute File.exists?(trash)
    assert {:ok, [listed]} = Poems.list(nil)
    assert listed.id == poem.id
  end

  test "trash APIs reject invalid identifiers and a symlinked trash directory", %{folder: folder} do
    assert {:error, _} = Poems.restore(nil, "../outside")
    assert {:error, _} = Poems.purge(nil, "../outside", "token", true)
    assert {:error, _} = Poems.trash(nil, %{id: "../outside", token: "token"})
    assert {:ok, _} = Poems.save(nil, Poems.new(nil), %{title: nil, body: "safe"})

    poems = Path.join(folder, "poems")
    outside = Path.join(folder, "outside-trash")
    File.mkdir!(outside)
    File.write!(Path.join(outside, "keep.txt"), "untouched")
    File.ln_s!(outside, Path.join(poems, ".trash"))

    assert {:error, _} = Poems.list_trash(nil)
    assert File.read!(Path.join(outside, "keep.txt")) == "untouched"
  end

  defp files_under(root) do
    root
    |> File.ls!()
    |> Enum.sort()
    |> Enum.reduce(%{}, fn name, acc ->
      path = Path.join(root, name)

      case File.lstat!(path).type do
        :directory ->
          nested =
            files_under(path)
            |> Enum.map(fn {relative, contents} -> {Path.join(name, relative), contents} end)
            |> Map.new()

          Map.merge(acc, nested)

        :regular ->
          Map.put(acc, name, File.read!(path))

        type ->
          raise "unexpected file type in test fixture: #{inspect(type)}"
      end
    end)
  end
end
