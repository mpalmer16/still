defmodule StillWeb.NotebookReadingLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Poems, Repo, Storage, Writing}
  alias Still.Writing.Notebooks
  alias Still.Writing.Entry

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    state_dir = Path.join(root, "state")
    previous_state_dir = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, state_dir)
    folder = Path.join(root, "collection")
    File.mkdir_p!(folder)
    assert {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      if previous_state_dir,
        do: Application.put_env(:still, :storage_state_directory, previous_state_dir),
        else: Application.delete_env(:still, :storage_state_directory)
    end)

    %{folder: folder, location: Storage.collection_location()}
  end

  test "reading a List keeps its notebook index beside the words and navigates in source order",
       %{conn: conn} do
    first = entry("first", "Field book 4", "First title:", "First words\n\n  indented")
    second = entry("second", "Field book 4", "Second title:", "Second words")

    {:ok, view, _html} = live(conn, ~p"/notebooks/read/#{first.id}?notebook=Field%20book%204")

    assert has_element?(view, "#notebook-sidebar")
    assert has_element?(view, "#notebook-sidebar a[aria-current='page']", "First title:")
    assert has_element?(view, "#notebook-content", "First words")
    assert has_element?(view, "#notebook-content", "indented")
    refute has_element?(view, "#notebook-previous")
    assert has_element?(view, "#reader-list-#{second.id} a[href*='/notebooks/read/#{second.id}']")
    assert has_element?(view, "#wander-with-this")
    assert has_element?(view, "#open-piece-find.sr-only[tabindex='-1']")
    assert has_element?(view, "#notebook-content .piece-find")
    assert Writing.current_writing() == nil

    view |> element("#open-piece-find") |> render_click()
    assert has_element?(view, "#piece-find-query")

    render_change(element(view, "#piece-find-form"), %{
      "piece_find" => %{"query" => "indented"},
      "_target" => ["piece_find", "query"]
    })

    assert has_element?(view, "#list-body mark", "indented")
    refute has_element?(view, "[data-search-target='true']")
    render_submit(element(view, "#piece-find-form"), %{"piece_find" => %{"query" => "indented"}})
    assert has_element?(view, "#passage-3[data-search-target='true'] mark", "indented")
    view |> element("#close-piece-find") |> render_click()

    render_hook(view, "find_in_piece", %{
      "piece_find" => %{"query" => "heron"},
      "_target" => ["piece_find", "query"]
    })

    refute has_element?(view, "#piece-find-form")
    refute has_element?(view, "#list-body mark")

    view |> element("#reader-list-#{second.id} a") |> render_click()
    assert has_element?(view, "#notebook-sidebar a[aria-current='page']", "Second title:")
    assert has_element?(view, "#notebook-content", "Second words")
    assert has_element?(view, "#reader-list-#{first.id} a")
  end

  test "ordinary file copy keeps its authored title once and earlier words stay read-only", %{
    conn: conn,
    folder: folder,
    location: location
  } do
    notebook_key = "Field book 9"
    {:ok, notebook} = Writing.create_notebook(%{key: notebook_key, label: notebook_key})
    path = Path.join([folder, notebook_key, "09b"])
    File.mkdir_p!(Path.dirname(path))
    original = "A title, exactly once:\n\n  Body line\n"
    File.write!(path, original)

    assert {:ok, [piece]} = Poems.list(location)
    assert {:ok, titled_piece} = Poems.save(location, piece, %{body: original, title_line: 1})

    {:ok, projected} =
      Writing.with_collection_snapshot(fn ->
        entry = Repo.get_by!(Entry, file_id: titled_piece.id)
        Notebooks.assign_entry(entry, notebook, %{source_order: 9, list_label: "09b"})
      end)

    assert {:ok, titled_piece} = Poems.get(location, titled_piece.id)

    assert {:ok, latest_piece} =
             Poems.save(location, titled_piece, %{
               body: "A title, exactly once:\nCurrent words\n",
               title_line: 1
             })

    {:ok, _} = Writing.with_collection_snapshot(fn -> {:ok, :refreshed} end)
    entry = Writing.get_entry!(projected.id)
    version = Enum.find(Writing.list_versions(entry), &(&1.body == original))
    assert version

    {:ok, current, _html} = live(conn, ~p"/notebooks/read/#{entry.id}")
    assert has_element?(current, "#copy-notebook-reading")
    assert has_element?(current, "#wander-with-this[href^='/w/#{entry.id}?']")
    assert has_element?(current, "#notebook-content .reader-reference")

    assert has_element?(
             current,
             "#notebook-content a[href^='/writing/#{titled_piece.id}/edit?'][href*='from=notebook']",
             "Edit"
           )

    assert has_element?(
             current,
             "#echo-attention-passage-#{titled_piece.id} [data-echo-line='1']"
           )

    render_hook(current, "focus_passage", %{"id" => titled_piece.id, "line" => "1"})
    assert has_element?(current, "[data-echo-line='1'].passage-focused")
    assert has_element?(current, "#whole-page-echoes")
    current |> element("#whole-page-echoes") |> render_click()
    refute has_element?(current, "[data-echo-line='1'].passage-focused")

    [payload] =
      current
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#copy-notebook-reading")
      |> LazyHTML.attribute("data-persisted")

    assert %{
             "body" => "A title, exactly once:\nCurrent words\n",
             "title" => "A title, exactly once:",
             "title_in_body" => true
           } =
             Jason.decode!(payload)

    {:ok, earlier, _html} = live(conn, ~p"/notebooks/read/#{entry.id}?version=#{version.id}")
    assert has_element?(earlier, ".historical-notice", "Earlier words")
    refute has_element?(earlier, "#notebook-content a", "Edit")
    refute has_element?(earlier, "#notebook-previous, #notebook-next")

    assert earlier
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#wander-with-this")
           |> LazyHTML.to_tree()
           |> length() == 1

    assert has_element?(earlier, "#notebook-content", "Body line")
    refute has_element?(earlier, "#writing-form")
    refute has_element?(earlier, "#writing-body")
    assert Writing.get_entry!(entry.id).body == "A title, exactly once:\nCurrent words\n"

    assert {:ok, _} = Poems.get(location, latest_piece.id)
  end

  test "linked file passages open their source in notebook reading", %{
    conn: conn,
    folder: folder,
    location: location
  } do
    notebook_key = "Field book references"
    {:ok, notebook} = Writing.create_notebook(%{key: notebook_key, label: notebook_key})
    source_path = Path.join([folder, notebook_key, "source.txt"])
    reader_path = Path.join([folder, notebook_key, "reader.txt"])
    File.mkdir_p!(Path.dirname(source_path))
    File.write!(source_path, "Source title\nWords from a linked poem\n")

    File.write!(
      reader_path,
      "Before the link\n[[poem: #{notebook_key}/source.txt]]\nAfter the link\n"
    )

    assert {:ok, pieces} = Poems.list(location)
    source = Enum.find(pieces, &(&1.relative_path == "#{notebook_key}/source.txt"))
    reader = Enum.find(pieces, &(&1.relative_path == "#{notebook_key}/reader.txt"))
    assert source && reader

    {:ok, entry} =
      Writing.with_collection_snapshot(fn ->
        entry = Repo.get_by!(Entry, file_id: reader.id)
        Notebooks.assign_entry(entry, notebook, %{source_order: 2, list_label: "2"})
      end)

    {:ok, view, _html} = live(conn, ~p"/notebooks/read/#{entry.id}")
    assert has_element?(view, ".linked-reading .poem-insert", "Words from a linked poem")
    assert has_element?(view, ".linked-reading .poem-insert-caption a", "Open original")
    assert has_element?(view, ".linked-reading .poem-insert-caption a[href*='reference_return=']")

    assert has_element?(
             view,
             "#echo-attention-linked-passage-0-#{reader.id} [data-echo-line='1']"
           )

    [reference_payload] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#copy-notebook-reading")
      |> LazyHTML.attribute("data-reference-sources")

    assert Jason.decode!(reference_payload)["[[poem: #{notebook_key}/source.txt]]"] ==
             "Source title\nWords from a linked poem\n"

    view |> element("#open-piece-find") |> render_click()

    render_submit(element(view, "#piece-find-form"), %{
      "piece_find" => %{"query" => "linked"}
    })

    assert has_element?(view, "#piece-find-status", "1 matching word")
    assert has_element?(view, ".poem-insert mark", "linked")

    File.write!(source_path, "Source title\nA changed linked source\n")
    send(view.pid, {:refresh_notebook_references, reader.id, reader.body})
    assert has_element?(view, ".poem-insert", "A changed linked source")
  end

  test "colon titles add no spaces and keep authored spaces" do
    for title <- ["They:Should:Be:Like:This", "A title: With its own space:"] do
      text =
        render_component(&StillWeb.CoreComponents.list_title/1, text: title)
        |> LazyHTML.from_fragment()
        |> LazyHTML.text(separator: "")
        |> String.trim()

      assert text == title
    end
  end

  test "a saved List can be permanently deleted from its notebook index", %{
    conn: conn,
    folder: folder,
    location: location
  } do
    notebook_key = "Field book to delete"

    assert {:ok, notebook} =
             Writing.create_folder_notebook(%{
               "key" => notebook_key,
               "label" => notebook_key,
               "relative_path" => notebook_key
             })

    path = Path.join([folder, notebook_key, "1.txt"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "Words to remove\n")
    assert {:ok, [piece]} = Poems.list(location)

    {:ok, view, _html} = live(conn, ~p"/notebooks?notebook=#{notebook.key}")
    assert has_element?(view, "#notebook-index", "Words to remove")
    assert has_element?(view, "#list-#{piece.entry_id} a.notebook-list-link", "Words to remove")
    assert has_element?(view, "#list-#{piece.entry_id} .notebook-list-actions a", "Read")

    assert has_element?(
             view,
             "#list-#{piece.entry_id} .notebook-list-actions a[href^='/w/#{piece.entry_id}?']",
             "Wander"
           )

    assert has_element?(view, "#list-#{piece.entry_id} .notebook-list-number", "1")
    view |> element("button[aria-label='Delete Words to remove']") |> render_click()
    assert has_element?(view, "#delete-list-confirmation", "earlier words?")
    view |> element("#delete-list-confirmation button", "Permanently delete") |> render_click()

    refute File.exists?(path)
    assert {:error, _} = Poems.get(location, piece.id)
    assert Repo.get_by(Entry, file_id: piece.id) == nil
  end

  test "notebook list actions retain their reader links and omit missing numbers", %{
    conn: conn
  } do
    saved = entry("numbered", "Field book 11", "Numbered title:", "Words")
    unnumbered = entry("unnumbered", "Field book 11", "Unnumbered title:", "More words")
    Repo.update!(Entry.changeset(saved, %{list_label: "004b", source_order: 4}))

    {:ok, view, _html} = live(conn, ~p"/notebooks?notebook=Field%20book%2011")
    assert has_element?(view, "#list-#{saved.id} .notebook-list-number", "004b")
    assert has_element?(view, "#list-#{unnumbered.id} .notebook-list-number") == false

    assert has_element?(
             view,
             "#list-#{saved.id} .notebook-list-actions a[href^='/notebooks/read/#{saved.id}?']",
             "Read"
           )

    assert has_element?(
             view,
             "#list-#{saved.id} .notebook-list-actions a[href^='/w/#{saved.id}?']",
             "Wander"
           )
  end

  test "Edit opens a historical notebook piece directly without changing its words", %{conn: conn} do
    source = entry("edit-source", "Field book edit", "Original title", "  Words kept\nexactly.")
    {:ok, reader, _} = live(conn, ~p"/notebooks/read/#{source.id}")
    assert has_element?(reader, "a[href='/w/#{source.id}?edit=1']", "Edit")
    {:ok, editor, _} = live(conn, ~p"/w/#{source.id}?edit=1")
    assert has_element?(editor, "#writing-body", "Words kept")
    assert Repo.get!(Entry, source.id).body == source.body
    assert Writing.list_versions(source) == []
  end

  test "a historical literal poem marker remains text instead of a linked passage", %{conn: conn} do
    source =
      entry(
        "historical-literal-reference",
        "Field book literal marker",
        "Literal reference",
        "This marker is authored text: [[poem: missing.txt]]"
      )

    {:ok, reader, _} = live(conn, ~p"/notebooks/read/#{source.id}")
    assert has_element?(reader, "#notebook-content", "[[poem: missing.txt]]")
    refute has_element?(reader, ".poem-insert")
  end

  defp entry(key, notebook, title, body) do
    %Entry{}
    |> Entry.changeset(%{
      source_key: key,
      source_group: key,
      notebook: notebook,
      source_order: if(String.starts_with?(key, "first"), do: 1, else: 2),
      origin: "before",
      title: title,
      body: body
    })
    |> Repo.insert!()
  end
end
