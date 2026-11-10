defmodule Still.Writing.ExportsTest do
  use Still.DataCase, async: false

  alias Still.{LocalRecord, Poems, Repo, Storage}
  alias Still.Writing.{Exports, PoemReferences}

  setup do
    root =
      Path.join(System.tmp_dir!(), "still-exports-test-#{System.unique_integer([:positive])}")

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

  test "prepares ordered expanded segments and writes Markdown outside the collection", %{
    folder: folder,
    location: location
  } do
    source_body = "A `small` poem\r\n  kept exact\r\n````\r\n"
    assert {:ok, source} = Poems.save(location, Poems.new(location), %{body: source_body})
    host_body = "A thought *as written*\n\n" <> PoemReferences.marker(source) <> "\nThen home.\n"
    assert {:ok, host} = Poems.save(location, Poems.new(location), %{body: host_body})

    assert {:ok, prepared} = Exports.prepare(location, host, :markdown)
    assert prepared.relative_path == Path.rootname(host.relative_path) <> ".md"
    assert prepared.source_token == prepared.digest
    refute prepared.source_token == host.token
    assert Enum.map(prepared.segments, & &1.kind) == [:text, :poem, :text]
    assert Enum.at(prepared.segments, 1).body == source_body
    assert prepared.digest =~ ~r/\A[0-9a-f]{64}\z/

    assert prepared.path ==
             Path.join([
               Path.dirname(Path.dirname(host.path)),
               "collection Exports",
               prepared.relative_path
             ])

    assert {:ok, output} = Exports.markdown(location, host)

    assert output == prepared.path
    assert File.read!(output) =~ "A thought \\*as written\\*  \n  \n"
    assert File.read!(output) =~ "`````text\r\n" <> source_body
    assert File.read!(output) =~ "`````\r\n  \nThen home\\.  \n"
    assert File.read!(host.path) == host_body
    assert File.read!(source.path) == source_body
    refute String.starts_with?(output, folder <> "/")
  end

  test "rejects stale hosts, unavailable links, and unowned or symbolic destinations", %{
    folder: folder,
    location: location
  } do
    assert {:ok, host} = Poems.save(location, Poems.new(location), %{body: "saved words"})
    output_root = Path.join(folder, "..") |> Path.join("collection Exports")
    collision = Path.join(output_root, Path.rootname(host.relative_path) <> ".md")
    File.mkdir_p!(Path.dirname(collision))
    File.write!(collision, "writer's own file")
    assert {:ok, %{segments: _}} = Exports.prepare(location, host, :markdown)
    assert {:error, _} = Exports.markdown(location, host)
    assert File.read!(collision) == "writer's own file"

    File.rm!(collision)
    File.write!(host.path, "changed behind Still")
    assert {:error, _} = Exports.prepare(location, host, :markdown)

    assert {:ok, source} = Poems.save(location, Poems.new(location), %{body: "source words"})

    assert {:ok, linked} =
             Poems.save(location, Poems.new(location), %{body: PoemReferences.marker(source)})

    File.rm!(source.path)
    assert {:error, _} = Exports.prepare(location, linked, :markdown)

    assert {:ok, symlink_host} = Poems.save(location, Poems.new(location), %{body: "symbolic"})
    File.rm!(symlink_host.path)
    File.write!(Path.join(folder, "other-file"), "target")
    File.ln!(Path.join(folder, "other-file"), symlink_host.path)
    assert {:error, _} = Exports.prepare(location, symlink_host, :markdown)
  end

  test "PDF publishing requires the same host and linked source snapshot and owns its output", %{
    location: location
  } do
    assert {:ok, source} = Poems.save(location, Poems.new(location), %{body: "first source\n"})

    assert {:ok, host} =
             Poems.save(location, Poems.new(location), %{
               body: PoemReferences.marker(source) <> "\n"
             })

    assert {:ok, prepared} = Exports.prepare(location, host, :pdf)

    assert prepared.segments == [
             %{kind: :text, body: ""},
             %{kind: :poem, body: "first source\n"},
             %{kind: :text, body: "\n"}
           ]

    assert {:ok, changed_source} = Poems.save(location, source, %{body: "revised source\n"})
    assert changed_source.id == source.id

    assert {:error, _} =
             Exports.publish_pdf(location, host, "%PDF-1.4\nfirst\n%%EOF", prepared.source_token)

    assert {:ok, revised} = Exports.prepare(location, host, :pdf)
    assert revised.segments |> Enum.map(& &1.body) |> Enum.join() =~ "revised source"
    pdf_current = "%PDF-1.4\ncurrent\n%%EOF"
    pdf_updated = "%PDF-1.4\nupdated\n%%EOF"
    assert {:ok, path} = Exports.publish_pdf(location, host, pdf_current, revised.source_token)
    assert File.read!(path) == pdf_current
    assert {:ok, ^path} = Exports.publish_pdf(location, host, pdf_updated, revised.source_token)
    assert File.read!(path) == pdf_updated

    File.write!(path, "external change")
    assert {:error, _} = Exports.publish_pdf(location, host, "%PDF-replacement", revised.digest)
    assert File.read!(path) == "external change"

    export_record = Repo.get_by!(LocalRecord, scope: location.scope, kind: "writing_export")
    assert export_record.data["relative_path"] == Path.basename(path)
    assert export_record.data["sha256"] == digest(pdf_updated)
  end

  test "a renamed source gets a new export path and removes its unchanged old export", %{
    location: location
  } do
    assert {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "Rename me"})
    assert {:ok, old_path} = Exports.markdown(location, saved)
    assert File.exists?(old_path)

    assert {:ok, renamed} = Poems.rename(location, saved, "A new title.txt")
    assert {:ok, new_path} = Exports.markdown(location, renamed)

    refute File.exists?(old_path)
    assert File.exists?(new_path)
    refute old_path == new_path
  end

  test "a renamed source leaves an externally edited prior export untouched", %{
    location: location
  } do
    assert {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "Rename me safely"})
    assert {:ok, old_path} = Exports.markdown(location, saved)
    File.write!(old_path, "writer changed this export")
    assert {:ok, renamed} = Poems.rename(location, saved, "Renamed safely.txt")

    assert {:error, message} = Exports.markdown(location, renamed)
    assert message =~ "existing export changed"
    assert File.read!(old_path) == "writer changed this export"
    refute File.exists?(Path.join(Path.dirname(old_path), "Renamed safely.md"))
  end

  test "saved ordinary text without a txt extension can be exported", %{
    folder: folder,
    location: location
  } do
    body = "  Exact ordinary text\n\tindented\n"
    File.write!(Path.join(folder, "writer-chosen-name"), body)
    assert {:ok, saved} = Poems.adopt(location, "writer-chosen-name")
    assert {:ok, prepared} = Exports.prepare(location, saved, :markdown)
    assert prepared.relative_path == "writer-chosen-name.md"
    assert {:ok, path} = Exports.markdown(location, saved)
    assert File.read!(path) =~ "Exact ordinary text  \n"
    assert File.read!(path) =~ "&nbsp;&nbsp;Exact ordinary text"
    assert File.read!(path) =~ String.duplicate("&nbsp;", 8) <> "indented"
    assert File.read!(saved.path) == body
  end

  test "a missing owned export can be regenerated", %{location: location} do
    assert {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "Regenerate this"})
    assert {:ok, path} = Exports.markdown(location, saved)
    assert File.exists?(path)

    record = Repo.get_by!(LocalRecord, scope: location.scope, kind: "writing_export")
    File.rm!(path)

    assert {:ok, ^path} = Exports.markdown(location, saved)
    assert File.read!(path) =~ "Regenerate this"
    assert Repo.get!(LocalRecord, record.id).data["sha256"] == digest(File.read!(path))
  end

  test "does not create exports through a symbolic ancestor", %{
    root: root,
    location: location
  } do
    assert {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "Keep path local"})
    moved_root = root <> "-moved"
    File.rename!(root, moved_root)
    File.ln_s!(moved_root, root)

    try do
      assert {:error, message} = Exports.markdown(location, saved)
      assert message =~ "ordinary directory"
      refute File.exists?(Path.join([moved_root, "collection Exports", "Keep_path_local.md"]))
    after
      File.rm_rf!(root)
      File.rename!(moved_root, root)
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
