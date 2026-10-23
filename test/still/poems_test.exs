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
  end
end
