defmodule Still.PoemsTest do
  use Still.DataCase, async: false

  import Ecto.Query
  alias Ecto.Changeset
  alias Still.{Poems, Repo, Storage}
  alias Still.Writing.{Entry, Version}

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

    %{folder: folder, root: root, location: Storage.collection_location()}
  end

  test "new names use the title or opening without changing the words", %{location: location} do
    body = "\n  rain / snow: café  \r\n\twords\n"
    assert {:ok, first} = Poems.save(location, Poems.new(location), %{body: body})
    assert first.relative_path == "rain_snow_café.txt"
    assert File.read!(first.path) == body
    assert {:ok, duplicate} = Poems.save(location, Poems.new(location), %{body: body})
    assert duplicate.relative_path == "rain_snow_café_2.txt"
    assert duplicate.id != first.id

    assert {:ok, titled} =
             Poems.save(location, Poems.new(location), %{
               body: "Opening\nChosen title\n",
               title_line: 2
             })

    assert titled.relative_path == "Chosen_title.txt"
    assert {:ok, blank} = Poems.save(location, Poems.new(location), %{body: "\n"})
    assert blank.relative_path == "Untitled.txt"
  end

  test "generated names use underscores for words and every colon", %{location: location} do
    for {opening, filename} <- [
          {"this is the title", "this_is_the_title.txt"},
          {"this:is:the:title:", "this_is_the_title_.txt"},
          {"This: Is: Another: Title:", "This_Is_Another_Title_.txt"},
          {"this::title:", "this__title_.txt"},
          {"  words\twith  spaces  ", "words_with_spaces.txt"}
        ] do
      body = opening <> "\r\n\r\n  Exact words\n"
      assert {:ok, saved} = Poems.save(location, Poems.new(location), %{body: body})
      assert saved.relative_path == filename
      assert File.read!(saved.path) == body
      assert {:ok, edited} = Poems.save(location, saved, %{body: "A changed opening\n"})
      assert edited.relative_path == filename
    end
  end

  test "interrupted renames recover before, between, and after filesystem steps", %{
    location: location,
    folder: folder
  } do
    for stage <- [:prepared, :linked, :removed] do
      assert {:ok, saved} =
               Poems.save(location, Poems.new(location), %{body: "Recovery #{stage}"})

      entry = Repo.get!(Entry, saved.entry_id)
      {:ok, stat} = File.stat(saved.path)
      identity = "#{stat.major_device}:#{stat.minor_device}:#{stat.inode}"
      target = "Recovered #{stage}.txt"

      entry
      |> Changeset.change(
        pending: %{"kind" => "rename", "target" => target, "identity" => identity}
      )
      |> Repo.update!()

      if stage in [:linked, :removed], do: File.ln!(saved.path, Path.join(folder, target))
      if stage == :removed, do: File.rm!(saved.path)
      assert {:ok, _} = Still.Writing.Files.synchronize(location)
      assert {:ok, recovered} = Poems.get(location, saved.id)
      assert recovered.relative_path == target
      assert File.read!(recovered.path) == saved.body
      refute File.exists?(saved.path)
      assert Repo.get!(Entry, saved.entry_id).pending == nil
    end
  end

  test "renaming retains identity, history and bytes and rejects collisions and stale edits", %{
    location: location,
    folder: folder
  } do
    assert {:ok, first} = Poems.save(location, Poems.new(location), %{body: "Earlier words"})
    assert {:ok, saved} = Poems.save(location, first, %{body: "Current words"})
    assert {:ok, renamed} = Poems.rename(location, saved, "Corrected name")
    assert renamed.id == saved.id
    assert renamed.entry_id == saved.entry_id
    assert renamed.relative_path == "Corrected name"
    refute File.exists?(saved.path)
    assert File.read!(renamed.path) == "Current words"
    assert {:ok, [%{body: "Earlier words"}]} = Poems.revisions(location, renamed.id)
    assert {:error, _} = Poems.save(location, saved, %{body: "stale"})
    File.write!(Path.join(folder, "occupied"), "Other writing")
    assert {:error, _} = Poems.rename(location, renamed, "occupied")
    assert File.read!(Path.join(folder, "occupied")) == "Other writing"
    assert {:error, _} = Poems.rename(location, renamed, "../escape")
    File.write!(renamed.path, "External edit")
    assert {:error, _} = Poems.rename(location, renamed, "Another")
    assert File.read!(renamed.path) == "External edit"
  end

  test "indexes ordinary UTF-8 files with arbitrary names and retains their exact text", %{
    folder: folder,
    location: location
  } do
    first_bytes = <<239, 187, 191>> <> "  First line stays here  \r\n\tSecond line — café\n\n"
    second_bytes = "Unrelated title-like filename\n\n  untouched\r"
    backup_named_text = "This is a writer's ordinary text, not a database backup.\n"
    File.write!(Path.join(folder, "écrit without extension"), first_bytes)
    File.mkdir_p!(Path.join(folder, "Drafts"))
    File.write!(Path.join([folder, "Drafts", "Winter (final?).md"]), second_bytes)
    File.write!(Path.join(folder, "still-backup.sqlite3"), backup_named_text)

    assert {:ok, pieces} = Poems.list(location)
    assert length(pieces) == 3
    first = Enum.find(pieces, &(&1.relative_path == "écrit without extension"))
    second = Enum.find(pieces, &(&1.relative_path == Path.join("Drafts", "Winter (final?).md")))
    assert first.body == String.replace_prefix(first_bytes, <<239, 187, 191>>, "")
    assert first.title == nil
    assert first.title_line == nil
    assert first.title_source == "first_line"
    assert Poems.display_title(first) == "écrit without extension"
    assert second.title == nil
    assert second.body == second_bytes
    reserved_name = Enum.find(pieces, &(&1.relative_path == "still-backup.sqlite3"))
    assert reserved_name.body == backup_named_text
    assert File.read!(reserved_name.path) == backup_named_text
    assert File.read!(first.path) == first_bytes
    assert File.read!(second.path) == second_bytes

    assert File.ls!(folder) |> Enum.sort() == [
             "Drafts",
             "still-backup.sqlite3",
             "écrit without extension"
           ]

    assert File.ls!(Path.join(folder, "Drafts")) == ["Winter (final?).md"]
  end

  test "a selected title line is metadata about the full body, never duplicated or removed", %{
    location: location
  } do
    body = "Opening\r\n  Explicit title  \r\n\tverse\n\nfinal line"
    assert {:ok, saved} = Poems.save(location, Poems.new(location), %{body: body, title_line: 2})
    assert saved.body == body
    assert saved.title == "  Explicit title  "
    assert saved.title_line == 2
    assert saved.title_source == "explicit"
    assert Poems.explicit_title(saved) == "  Explicit title  "
    assert Poems.display_title(saved) == "Explicit title"
    assert File.read!(saved.path) == body
    assert {:ok, reopened} = Poems.get(location, saved.id)
    assert reopened.body == body
    assert reopened.title_line == 2
  end

  test "editing a separate title convenience keeps the supplied first body line", %{
    location: location
  } do
    {:ok, original} =
      Poems.save(location, Poems.new(location), %{
        title: "Old title",
        body: "First supplied line\nsecond line"
      })

    assert original.body == "Old title\n\nFirst supplied line\nsecond line"

    {:ok, edited} =
      Poems.save(location, original, %{
        title: "New title",
        body: "First supplied line\nsecond line"
      })

    assert edited.title == "New title"
    assert edited.body == "New title\n\nFirst supplied line\nsecond line"
    assert File.read!(edited.path) == edited.body
  end

  test "revisions live in SQLite and stale snapshots cannot overwrite newer words", %{
    location: location
  } do
    body = "First\r\n\tsecond\n\n"
    assert {:ok, first} = Poems.save(location, Poems.new(location), %{body: body})
    assert {:ok, updated} = Poems.save(location, first, %{body: "Current words\n"})
    assert File.read!(updated.path) == "Current words\n"
    assert {:ok, [revision]} = Poems.revisions(location, first.id)
    assert revision.body == body
    assert revision.title_line == nil
    assert Repo.aggregate(Version, :count) == 1
    assert {:error, stale} = Poems.save(location, first, %{body: "stale proposal"})
    assert stale =~ "changed"
    assert File.read!(updated.path) == "Current words\n"
  end

  test "saving identical words and title role creates no redundant revision", %{
    location: location
  } do
    {:ok, saved} =
      Poems.save(location, Poems.new(location), %{body: "unchanged words\n", title_line: nil})

    before_bytes = File.read!(saved.path)

    assert {:ok, reopened} =
             Poems.save(location, saved, %{body: saved.body, title_line: saved.title_line})

    assert reopened.token == saved.token
    assert File.read!(reopened.path) == before_bytes
    assert {:ok, []} = Poems.revisions(location, saved.id)
    assert Repo.aggregate(Version, :count) == 0
  end

  test "an occupied new relative filename is never overwritten", %{
    folder: folder,
    location: location
  } do
    occupied = Path.join(folder, "writer-picked-name")
    original = "Keep the writer's existing words\r\n"
    File.write!(occupied, original)

    assert {:error, message} =
             Poems.save(location, Poems.new(location), %{
               relative_path: "writer-picked-name",
               body: "replacement"
             })

    assert message =~ "occupied"
    assert File.read!(occupied) == original
    assert {:ok, [piece]} = Poems.list(location)
    assert piece.relative_path == "writer-picked-name"
    assert piece.body == original
  end

  test "external edits become database revisions and require review for a prior title role", %{
    location: location
  } do
    original = "Opening\nChosen title\nOld verse\n"
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: original, title_line: 2})
    File.write!(saved.path, "New opening\nDifferent line\nNew verse\n")

    assert {:ok, refreshed} = Poems.get(location, saved.id)
    assert refreshed.body == "New opening\nDifferent line\nNew verse\n"
    assert refreshed.title_needs_review
    assert refreshed.title_line == 2
    assert Poems.explicit_title(refreshed) == nil
    assert {:ok, [revision]} = Poems.revisions(location, saved.id)
    assert revision.body == original

    assert {:error, _} = Poems.save(location, saved, %{body: "attempt from old view"})
  end

  test "a missing folder is unavailable, not evidence that its files were deleted", %{
    folder: folder,
    location: location
  } do
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "words remain in SQLite"})
    entry = Repo.get_by!(Entry, file_id: saved.id, collection_scope: location.scope)
    moved = folder <> "-offline"
    File.rename!(folder, moved)

    assert {:error, message} = Poems.list(location)
    assert message =~ "unavailable"
    reopened = Repo.get!(Entry, entry.id)
    assert reopened.file_missing == false
    assert reopened.body == "words remain in SQLite"
    assert File.read!(saved.path |> String.replace(folder, moved)) == "words remain in SQLite"
  end

  test "an inode-preserving rename retains the file identity and relationships", %{
    folder: folder,
    location: location
  } do
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "same exact words"})
    entry_id = saved.entry_id
    target = Path.join(folder, "writer chose this filename")
    File.rename!(saved.path, target)

    assert {:ok, reopened} = Poems.get(location, saved.id)
    assert reopened.id == saved.id
    assert reopened.entry_id == entry_id
    assert reopened.relative_path == "writer chose this filename"
    assert reopened.body == "same exact words"
    assert File.read!(target) == "same exact words"
  end

  test "equal text files remain separate writings", %{folder: folder, location: location} do
    File.write!(Path.join(folder, "first"), "identical\nwords")
    File.write!(Path.join(folder, "second.txt"), "identical\nwords")
    assert {:ok, [first, second]} = Poems.list(location)
    refute first.id == second.id
    refute first.entry_id == second.entry_id
    assert first.body == second.body
    assert first.relative_path != second.relative_path
  end

  test "copy-delete ambiguity requires explicit relink or adoption", %{
    folder: folder,
    location: location
  } do
    original_path = Path.join(folder, "original")
    copy_path = Path.join(folder, "copied")
    File.write!(original_path, "same words\n")
    {:ok, [original]} = Poems.list(location)
    File.cp!(original_path, copy_path)
    File.rm!(original_path)

    assert {:ok, plan} = Poems.reconciliation(location)
    assert [%{id: id, candidates: ["copied"]}] = plan.ambiguous
    assert id == original.id
    assert {:ok, relinked} = Poems.relink(location, original.id, "copied")
    assert relinked.id == original.id
    assert relinked.relative_path == "copied"

    another = Path.join(folder, "another-original")
    another_copy = Path.join(folder, "another-copy")
    File.write!(another, "distinct choice text")
    {:ok, indexed} = Poems.list(location)
    distinct = Enum.find(indexed, &(&1.relative_path == "another-original"))
    File.cp!(another, another_copy)
    File.rm!(another)
    assert {:ok, plan2} = Poems.reconciliation(location)
    assert Enum.any?(plan2.ambiguous, &(&1.id == distinct.id and "another-copy" in &1.candidates))
    assert {:ok, adopted} = Poems.adopt(location, "another-copy")
    refute adopted.id == distinct.id
    assert {:ok, still_missing} = Poems.reconciliation(location)
    assert Enum.any?(still_missing.missing, &(&1.id == distinct.id))
  end

  test "trash keeps recoverable words in SQLite and restore refuses an occupied original path", %{
    location: location
  } do
    body = "Full words\r\n  retained here\n"
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: body})
    relative = saved.relative_path
    assert {:ok, _trashed} = Poems.trash(location, saved)
    refute File.exists?(saved.path)
    assert {:ok, [in_trash]} = Poems.list_trash(location)
    assert in_trash.body == body
    assert in_trash.id == saved.id
    File.write!(Path.join(location.folder, relative), "a different writing")
    assert {:error, message} = Poems.restore(location, saved.id)
    assert message =~ "occupied"
    assert File.read!(Path.join(location.folder, relative)) == "a different writing"
    assert {:ok, [still_trashed]} = Poems.list_trash(location)
    assert still_trashed.body == body
    File.rm!(Path.join(location.folder, relative))
    assert {:ok, restored} = Poems.restore(location, saved.id)
    assert restored.id == saved.id
    assert File.read!(restored.path) == body
  end

  test "confirmed permanent deletion recovers across an interrupted unlink", %{location: location} do
    for stage <- [:before_unlink, :after_unlink] do
      {:ok, saved} =
        Poems.save(location, Poems.new(location), %{body: "Delete recovery #{stage}"})

      entry = Repo.get!(Entry, saved.entry_id)

      entry
      |> Changeset.change(
        pending: %{"kind" => "permanent_delete", "identity" => entry.source["file_identity"]}
      )
      |> Repo.update!()

      if stage == :after_unlink, do: File.rm!(saved.path)
      assert {:ok, _} = Still.Writing.Files.synchronize(location)
      refute File.exists?(saved.path)
      assert Repo.get(Entry, saved.entry_id) == nil
    end
  end

  test "permanent deletion refuses an externally changed file", %{location: location} do
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "Original"})
    File.write!(saved.path, "External words")
    assert {:error, _} = Poems.permanently_delete(location, saved, true)
    assert File.read!(saved.path) == "External words"
    assert Repo.get!(Entry, saved.entry_id).pending == nil
  end

  test "permanent deletion requires a current snapshot and removes file and saved history", %{
    location: location,
    folder: folder
  } do
    assert {:ok, original} = Poems.save(location, Poems.new(location), %{body: "Earlier words"})
    assert {:ok, saved} = Poems.save(location, original, %{body: "Current words"})
    assert {:ok, [_]} = Poems.revisions(location, saved.id)

    assert {:error, message} = Poems.permanently_delete(location, original, true)
    assert message =~ "changed"
    assert File.read!(saved.path) == "Current words"

    assert {:ok, fresh} = Poems.get(location, saved.id)
    assert {:error, _} = Poems.permanently_delete(location, fresh, false)
    assert File.exists?(fresh.path)

    assert :ok = Poems.permanently_delete(location, fresh, true)
    refute File.exists?(fresh.path)
    assert {:error, _} = Poems.get(location, saved.id)
    assert Repo.get(Entry, saved.entry_id) == nil
    assert Repo.all(from(v in Version, where: v.entry_id == ^saved.entry_id)) == []

    assert File.ls!(folder) == []
  end

  test "pending save recovery completes old-file and already-published cases", %{
    location: location
  } do
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "old words"})
    entry = Repo.get_by!(Entry, file_id: saved.id, collection_scope: location.scope)
    set_pending_save(entry, "new words")
    assert {:ok, [recovered]} = Poems.list(location)
    assert recovered.body == "new words"
    assert File.read!(recovered.path) == "new words"
    assert {:ok, [revision]} = Poems.revisions(location, saved.id)
    assert revision.body == "old words"

    current = Repo.get_by!(Entry, file_id: saved.id, collection_scope: location.scope)
    set_pending_save(current, "published already")
    File.write!(saved.path, "published already")
    assert {:ok, [finished]} = Poems.list(location)
    assert finished.body == "published already"
    assert File.read!(saved.path) == "published already"
  end

  test "recovery cleans a tracked partial stage before publishing its exact proposed text", %{
    folder: folder,
    location: location
  } do
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "earlier"})
    entry = Repo.get_by!(Entry, file_id: saved.id, collection_scope: location.scope)
    stage = ".still-#{Ecto.UUID.generate()}.partial"
    proposed = "complete proposal\r\nwith exact spacing"
    set_pending_save(entry, proposed, stage)
    File.write!(Path.join(folder, stage), binary_part(proposed, 0, 8))

    assert {:ok, [recovered]} = Poems.list(location)
    assert recovered.body == proposed
    assert File.read!(recovered.path) == proposed
    refute File.exists?(Path.join(folder, stage))
  end

  test "recovery refuses unfamiliar staging contents and leaves them untouched", %{
    folder: folder,
    location: location
  } do
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "earlier"})
    entry = Repo.get_by!(Entry, file_id: saved.id, collection_scope: location.scope)
    stage = ".still-#{Ecto.UUID.generate()}.partial"
    set_pending_save(entry, "proposed", stage)
    File.write!(Path.join(folder, stage), "unrecognized staging data")

    assert {:error, message} = Poems.list(location)
    assert message =~ "unfamiliar contents"
    assert File.read!(Path.join(folder, stage)) == "unrecognized staging data"
    assert File.read!(saved.path) == "earlier"
    pending = Repo.get_by!(Entry, file_id: saved.id, collection_scope: location.scope).pending
    assert pending["body"] == "proposed"
  end

  test "invalid staging names cannot remove files outside the selected folder", %{
    folder: _folder,
    root: root,
    location: location
  } do
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "earlier"})
    entry = Repo.get_by!(Entry, file_id: saved.id, collection_scope: location.scope)
    set_pending_save(entry, "proposed", "../valuable.txt")
    valuable = Path.join(root, "valuable.txt")
    File.write!(valuable, "preserve this file")

    assert {:error, _} = Poems.list(location)
    assert File.read!(valuable) == "preserve this file"
    assert File.read!(saved.path) == "earlier"
  end

  test "pending recovery preserves proposed and earlier words when a third-party edit conflicts",
       %{location: location} do
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "earlier words"})
    entry = Repo.get_by!(Entry, file_id: saved.id, collection_scope: location.scope)
    set_pending_save(entry, "proposed words")
    File.write!(saved.path, "third-party words")

    assert {:error, message} = Poems.list(location)
    assert message =~ "conflicts with an external change"
    row = Repo.get_by!(Entry, file_id: saved.id, collection_scope: location.scope)
    assert row.body == "earlier words"
    assert row.pending["body"] == "proposed words"
    assert Repo.get_by!(Version, entry_id: row.id).body == "earlier words"
    assert File.read!(saved.path) == "third-party words"
  end

  test "invalid encodings and binary formats are reported without indexing", %{
    folder: folder,
    location: location
  } do
    File.write!(Path.join(folder, "bad-encoding"), <<255, 254, 253>>)
    assert {:error, message} = Poems.list(location)
    assert message =~ "ordinary UTF-8 text"
    assert File.read!(Path.join(folder, "bad-encoding")) == <<255, 254, 253>>
    File.rm!(Path.join(folder, "bad-encoding"))
    File.write!(Path.join(folder, "archive.bin"), <<"PK", 3, 4, 0, 0>>)
    assert {:error, _} = Poems.list(location)
    assert File.read!(Path.join(folder, "archive.bin")) == <<"PK", 3, 4, 0, 0>>
  end

  test "concurrent saves from one snapshot accept one writer and reject the stale writer", %{
    location: location
  } do
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "start"})

    results =
      ["first", "second"]
      |> Enum.map(fn body -> Task.async(fn -> Poems.save(location, saved, %{body: body}) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    assert {:ok, current} = Poems.get(location, saved.id)
    assert current.body in ["first", "second"]
  end

  test "an unconfigured or switched collection refuses stale writes", %{
    root: root,
    location: location
  } do
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "words"})
    other = Path.join(root, "other")
    File.mkdir!(other)
    assert {:ok, _} = Storage.set_folder(other)
    assert {:error, message} = Poems.save(location, saved, %{body: "new words"})
    assert message =~ "collection changed"
    assert {:ok, _} = Storage.clear_folder()
    assert {:error, _} = Poems.list(nil)
  end

  defp set_pending_save(entry, proposed, stage \\ nil) do
    Repo.insert!(%Version{
      entry_id: entry.id,
      title: entry.title,
      body: entry.body,
      title_line: entry.title_line,
      title_anchor: entry.title_anchor,
      file_prefix: entry.file_prefix
    })

    pending = %{
      "kind" => "save",
      "stage" => stage,
      "old_token" => entry.file_token,
      "body" => proposed,
      "prefix" => Base.encode64(entry.file_prefix || ""),
      "title_line" => entry.title_line,
      "title_anchor" => entry.title_anchor,
      "metadata" => %{
        "notebook_id" => entry.notebook_id,
        "notebook" => entry.notebook,
        "source_order" => entry.source_order,
        "list_label" => entry.list_label
      }
    }

    Repo.update!(Changeset.change(entry, pending: pending, lock_version: entry.lock_version + 1))
    :ok
  end
end
