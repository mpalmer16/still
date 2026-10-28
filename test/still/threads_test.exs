defmodule Still.Writing.ThreadsTest do
  use Still.DataCase

  alias Still.{Poems, Storage}
  alias Still.Writing.{Entry, Threads}

  setup do
    dir = Path.join(System.tmp_dir!(), "still-threads-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    folder = Path.join(dir, "collection")
    state = Path.join(dir, "state")
    File.mkdir_p!(folder)
    old_state = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, state)
    assert {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      if old_state,
        do: Application.put_env(:still, :storage_state_directory, old_state),
        else: Application.delete_env(:still, :storage_state_directory)

      File.rm_rf!(dir)
    end)

    %{folder: folder}
  end

  test "load includes only Before and saved pages and does not create collection files", %{
    folder: folder
  } do
    before = historical("before:one", "A quiet blue room")
    {:ok, _now} = Repo.insert(Entry.changeset(%Entry{}, %{body: "living database draft"}))
    assert %{documents: [document], problem: nil} = Threads.load(Storage.collection_location())
    assert document.key == "before:#{before.id}"
    assert document.kind == :before
    assert document.family == "before:one"
    refute File.exists?(Path.join(folder, "poems"))

    {:ok, saved} =
      Poems.save(Storage.collection_location(), Poems.new(nil), %{
        title: "File",
        body: "A blue page"
      })

    assert %{documents: docs, problem: nil} = Threads.load(Storage.collection_location())
    assert Enum.map(docs, & &1.key) == ["before:#{before.id}", "file:#{saved.id}"]
    assert Enum.at(docs, 1).kind == :file
  end

  test "an unconfigured folder is normal and a missing configured folder reports a problem", %{
    folder: folder
  } do
    before = historical("survives", "A line from Before")
    assert {:ok, _} = Storage.clear_folder()
    assert %{documents: [doc], problem: nil} = Threads.load(Storage.collection_location())
    assert doc.id == before.id

    assert {:ok, _} = Storage.set_folder(folder)
    File.rm_rf!(folder)
    assert %{documents: [doc], problem: problem} = Threads.load(Storage.collection_location())
    assert doc.id == before.id
    assert is_binary(problem)
  end

  test "a malformed collection stays explicit while historical writing remains readable", %{
    folder: folder
  } do
    before = historical("still-readable", "A line held in Before")
    poems = Path.join(folder, "poems")
    File.mkdir_p!(poems)
    File.write!(Path.join(poems, ".still-poems.json"), "not json")

    assert %{documents: [doc], problem: problem} = Threads.load(Storage.collection_location())
    assert doc.id == before.id
    assert problem =~ "unknown format"
  end

  test "load preserves an interrupted save journal and every collection byte", %{folder: folder} do
    historical("journal-neighbor", "A saved page beside an earlier page")

    {:ok, saved} =
      Poems.save(Storage.collection_location(), Poems.new(nil), %{
        title: "Kept",
        body: "A saved page"
      })

    journal = Path.join(Path.dirname(saved.path), ".save-journal.json")
    metadata_path = Path.join(Path.dirname(saved.path), "metadata.json")
    old_metadata = File.read!(metadata_path)

    new_metadata =
      old_metadata |> Jason.decode!() |> Map.put("title", "After interruption") |> Jason.encode!()

    journal_bytes =
      Jason.encode!(%{
        "filename" => "poem.txt",
        "old_body" => Base.encode64(saved.body),
        "old_metadata" => Base.encode64(old_metadata),
        "new_body" => Base.encode64("A changed page"),
        "new_metadata" => Base.encode64(new_metadata)
      })

    File.write!(journal, journal_bytes)
    # This recoverable half-save would be completed by the ordinary shelf reader.
    File.write!(saved.path, "A changed page")
    before = snapshot(folder)

    assert %{documents: [_historical], problem: problem} =
             Threads.load(Storage.collection_location())

    assert problem =~ "interrupted save"
    assert snapshot(folder) == before
    assert File.read!(journal) == journal_bytes
    assert File.read!(metadata_path) == old_metadata
  end

  test "an unavailable storage-setting error remains visible when no folder is configured" do
    before = historical("setting-error", "Earlier words")
    error = "The local settings could not be read."

    assert %{documents: [doc], problem: ^error} =
             Threads.load(%{configured: false, error: error})

    assert doc.id == before.id
  end

  test "the same historical edition is not counted as independent recurrence", %{folder: _folder} do
    entry = historical("one-source", "The blue accordion waits")
    assert {:ok, _edition} = Poems.from_historical(Storage.collection_location(), entry)
    docs = Threads.load(Storage.collection_location()).documents
    refute "accordion" in Threads.words(docs)
  end

  test "words recur across distinct families and normalize accents", %{folder: _folder} do
    historical("notebook-one", "The café waits beside a blue accordion", notebook: "Notebook One")
    historical("notebook-two", "An accordion returns to the quiet room", notebook: "Notebook Two")
    docs = Threads.load(Storage.collection_location()).documents

    assert "accordion" in Threads.words(docs)
    assert Threads.words(docs, seed: "a") == Threads.words(docs, seed: "a")
    assert "café" == Threads.normalize_word("café")
    assert Threads.normalize_word("two words") == ""
    assert Threads.normalize_word(String.duplicate("a", 65)) == ""
    assert Threads.normalize_word("they’re") == "they’re"
  end

  test "following a page filters to its words and skips words in almost every document" do
    source =
      doc(
        "before:source",
        :before,
        "family:source",
        "Notebook A",
        "The amber accordion commonword"
      )

    other = doc("before:other", :before, "family:other", "Notebook B", "Amber arrives commonword")

    unrelated =
      for index <- 1..8 do
        doc(
          "before:#{index}",
          :before,
          "family:#{index}",
          "Notebook C",
          "Commonword appears here"
        )
      end

    assert "amber" in Threads.words([source, other], from: source.key)
    refute "accordion" in Threads.words([source, other], from: other.key)
    assert "amber" in Threads.words([source, other], from: other.key)
    refute "commonword" in Threads.words(unrelated ++ [source, other])
    assert Threads.words([source, other], from: "missing") == []
  end

  test "discovery omits tokens longer than the accepted input length" do
    long = String.duplicate("a", 65)

    docs = [
      doc("before:a", :before, "family:a", "Notebook A", long),
      doc("before:b", :before, "family:b", "Notebook B", long)
    ]

    refute long in Threads.words(docs)
  end

  test "passages match whole Unicode tokens and preserve exact stanza bytes" do
    first_body =
      "First line with café\r\n  accordion here  \r\n\r\nSecond stanza has accordions.\r\n"

    first = doc("before:1", :before, "notebook-a", "Notebook A", first_body)
    second = doc("file:2", :file, "file:2", "Saved writing", "The accordionist waits\n")
    third = doc("before:3", :before, "notebook-b", "Notebook B", "A café and accordion.\n")

    assert [passage] = Threads.passages([first, second], "accordion")
    assert passage.document == first
    assert passage.text == "First line with café\r\n  accordion here  \r\n"
    assert passage.line == 2

    assert Enum.map(Threads.passages([first, third], "café"), & &1.document.key) == [
             "before:1",
             "before:3"
           ]

    assert Threads.passages([second], "accordion") == []
  end

  test "pairs count unique family crossings with canonical Before and file orientation" do
    a = doc("before:a", :before, "same", "Notebook A", "A shared word")
    a_edition = doc("file:a", :file, "same", "Saved writing", "A shared word")
    b = doc("before:b", :before, "other", "Notebook B", "A shared word")
    c = doc("file:c", :file, "file:c", "Saved writing", "A shared word")
    passages = Enum.map([a, a_edition, b, c], &%{document: &1, text: &1.body, line: 1})

    assert Threads.crossing_count(passages) == 3
    pairs = for step <- 0..2, do: Threads.pair(passages, step)

    assert length(
             Enum.uniq_by(pairs, fn {left, right} -> {left.document.key, right.document.key} end)
           ) == 3

    assert Enum.all?(pairs, fn {left, right} ->
             left.document.kind == :before and right.document.kind == :file and
               left.document.family != right.document.family
           end)

    assert Threads.pair([hd(passages), Enum.at(passages, 1)]) == nil
  end

  test "counting and selecting remain linear for five thousand pages in one notebook" do
    passages =
      for index <- 1..5_000 do
        document =
          doc("before:#{index}", :before, "family:#{index}", "One notebook", "shared word")

        %{document: document, text: document.body, line: 1}
      end

    assert Threads.crossing_count(passages) == div(5_000 * 4_999, 2)
    assert {left, right} = Threads.pair(passages, 12_497_499)
    assert left.document.family != right.document.family
  end

  test "notebook-preferred pairs skip same-family editions and cycle without reversing" do
    first = doc("before:first", :before, "shared-family", "Notebook A", "the word")
    same_source = doc("before:edition", :before, "shared-family", "Notebook B", "the word")
    second = doc("before:second", :before, "other-family", "Notebook B", "the word")
    passages = Enum.map([first, same_source, second], &%{document: &1, text: &1.body, line: 1})

    assert Threads.crossing_count(passages) == 1
    assert {left, right} = Threads.pair(passages, 0)
    assert left.document.key == first.key
    assert right.document.key == second.key
    assert Threads.pair(passages, 1) == Threads.pair(passages, 0)
  end

  defp historical(key, body, opts \\ []) do
    attrs = %{
      origin: "before",
      source_key: key,
      source_group: Keyword.get(opts, :group, key),
      notebook: Keyword.get(opts, :notebook, "Notebook"),
      title: "A title",
      body: body
    }

    {:ok, entry} = Repo.insert(Entry.changeset(%Entry{}, attrs))
    entry
  end

  defp doc(key, kind, family, label, body) do
    %{key: key, kind: kind, id: key, family: family, label: label, title: key, body: body}
  end

  defp snapshot(root), do: snapshot(root, "") |> Map.new()

  defp snapshot(root, relative) do
    directory = if relative == "", do: root, else: Path.join(root, relative)

    Enum.flat_map(File.ls!(directory), fn name ->
      child = if relative == "", do: name, else: Path.join(relative, name)
      path = Path.join(root, child)

      if File.dir?(path) do
        [{child <> "/", :directory} | snapshot(root, child)]
      else
        [{child, File.read!(path)}]
      end
    end)
  end
end
