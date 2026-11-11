defmodule StillWeb.FocusedReadingTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Correspondence, Poems, Repo, Storage, Writing}
  alias Still.Writing.{Entry, ReadingPlace}
  alias StillWeb.ReadingLinks

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    collection = Path.join(root, "collection")
    File.mkdir_p!(collection)
    {:ok, _} = Storage.set_folder(collection)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:still, :storage_state_directory, previous),
        else: Application.delete_env(:still, :storage_state_directory)
    end)

    %{collection: collection}
  end

  test "Wander keeps a saved file for Correspondence without leaving the page or changing its words",
       %{conn: conn} do
    location = Storage.collection_location()
    {:ok, piece} = Poems.save(location, Poems.new(location), %{title: "Moss", body: "Soft rain"})
    entry = Writing.get_entry!(piece.entry_id)

    original_cursor =
      {Writing.current_writing(), Writing.current_beside(), Writing.current_list_draft?()}

    {:ok, wander, _} = live(conn, ReadingLinks.wander(entry))

    assert has_element?(
             wander,
             "#keep-for-correspondence[aria-pressed=false]",
             "Keep for Correspondence"
           )

    assert has_element?(wander, ".drift-room")

    render_click(element(wander, "#keep-for-correspondence"))

    assert has_element?(
             wander,
             "#keep-for-correspondence[aria-pressed=true]",
             "Kept for Correspondence"
           )

    assert has_element?(wander, ".drift-room")
    assert Map.get(Correspondence.writing_status(location).focused, piece.id)
    assert {:ok, unchanged} = Poems.get(location, piece.id)

    assert {unchanged.path, unchanged.token, unchanged.body} ==
             {piece.path, piece.token, piece.body}

    assert {Writing.current_writing(), Writing.current_beside(), Writing.current_list_draft?()} ==
             original_cursor

    render_click(element(wander, "#keep-for-correspondence"))

    assert has_element?(
             wander,
             "#keep-for-correspondence[aria-pressed=false]",
             "Keep for Correspondence"
           )

    refute Map.get(Correspondence.writing_status(location).focused, piece.id, false)
  end

  test "Wander can keep a historical List through its stable saved-copy identity", %{conn: conn} do
    source = historical("Older poem", "The original words")
    entry = Repo.update!(Entry.changeset(source, %{source_key: Ecto.UUID.generate()}))
    location = Storage.collection_location()
    {:ok, wander, _} = live(conn, ReadingLinks.wander(entry))

    assert has_element?(wander, "#keep-for-correspondence[aria-pressed=false]")
    assert has_element?(wander, "#keep-for-correspondence-help", "the original stays here")

    render_click(element(wander, "#keep-for-correspondence"))
    assert has_element?(wander, "#keep-for-correspondence[aria-pressed=true]")

    {:ok, [saved]} = Poems.list(location)
    assert saved.historical_source["source_key"] == entry.source_key
    assert saved.body == "Older poem\n\nThe original words"
    assert Map.get(Correspondence.writing_status(location).focused, saved.id)
    original = Repo.get!(Entry, entry.id)
    assert original.file_id == nil
    assert original.body == source.body

    render_click(element(wander, "#keep-for-correspondence"))
    render_click(element(wander, "#keep-for-correspondence"))
    assert has_element?(wander, "#keep-for-correspondence[aria-pressed=true]")
    assert {:ok, [same_saved]} = Poems.list(location)
    assert same_saved.id == saved.id
  end

  test "changing the collection prevents a historical Wander mark from promoting into the new one",
       %{conn: conn, tmp_dir: root} do
    source = historical("Older poem", "The original words")
    entry = Repo.update!(Entry.changeset(source, %{source_key: Ecto.UUID.generate()}))
    {:ok, wander, _} = live(conn, ReadingLinks.wander(entry))
    other_folder = Path.join(root, "other-collection")
    File.mkdir_p!(other_folder)
    {:ok, _} = Storage.set_folder(other_folder)

    render_click(element(wander, "#keep-for-correspondence"))

    assert has_element?(wander, ".flash-error", "collection changed")
    assert has_element?(wander, "#keep-for-correspondence[aria-pressed=false]")
    assert {:ok, []} = Poems.list(Storage.collection_location())
    assert Repo.get!(Entry, entry.id).file_id == nil
  end

  test "an earlier file revision cannot be marked as the current piece", %{conn: conn} do
    location = Storage.collection_location()
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "Earlier exact words"})
    {:ok, current} = Poems.save(location, saved, %{body: "Current exact words"})
    {:ok, [earlier]} = Poems.revisions(location, saved.id)
    entry = Writing.get_entry!(current.entry_id)

    {:ok, wander, _} =
      live(conn, "/w/#{entry.id}?read=1&version=#{earlier.id}")

    assert has_element?(wander, ".historical-reading", "Earlier words")
    refute has_element?(wander, "#keep-for-correspondence")
    assert Poems.get(location, saved.id) |> elem(1) |> Map.fetch!(:body) == "Current exact words"
  end

  test "notebook reading stays in order and retains its place through wandering", %{conn: conn} do
    first = piece("First", 1)
    second = piece("Second", 2)
    elsewhere = piece("Elsewhere", 1, "Early Notebooks/Lists 3")
    Writing.begin_writing(nil, writing_form: "list")
    context = %{"from" => "notebook", "notebook" => first.notebook}
    {:ok, reader, _} = live(conn, ReadingLinks.reader(first, context))

    assert has_element?(reader, "a[aria-current='page']", "Notebooks")

    assert has_element?(
             reader,
             "#reading-origin[href*='at=#{first.id}'][href$='#list-#{first.id}']",
             "Contents"
           )

    assert has_element?(
             reader,
             "#notebook-next[href^='/notebooks/read/#{second.id}?'][href*='from=notebook']"
           )

    refute has_element?(reader, ".gravity-presence, .drift-room, .passage-listen")
    assert has_element?(reader, "#wander-with-this[href^='/w/#{first.id}?']", "Wander with this")

    {:ok, second_reader, _} = live(conn, ReadingLinks.reader(second, context))
    assert has_element?(second_reader, "#notebook-previous[href^='/notebooks/read/#{first.id}?']")
    assert ReadingPlace.last().entry.id == second.id

    {:ok, wander, _} = live(conn, ~p"/w/#{elsewhere.id}?read=1")
    assert has_element?(wander, ".drift-room")
    assert has_element?(wander, "#return-to-reading[href^='/notebooks/read/#{second.id}?']")
    assert ReadingPlace.last().entry.id == second.id

    {:ok, returned, _} = live(conn, ReadingLinks.resume(ReadingPlace.last()))

    assert has_element?(
             returned,
             "#reading-origin[href*='at=#{second.id}'][href$='#list-#{second.id}']"
           )

    {:ok, index, _} = live(conn, ReadingLinks.origin(ReadingPlace.last()))
    assert has_element?(index, "#list-#{second.id}.notebook-current a[aria-current='location']")
    assert has_element?(index, "#continue-reading[href^='/notebooks/read/#{second.id}?']")
    assert Writing.current_writing() == nil
    assert Writing.current_list_draft?()
    assert Writing.get_entry!(first.id).body == first.body
    assert Writing.list_versions(first) == []
  end

  test "Find returns to a selected result beyond the first page, including a partial last page",
       %{conn: conn} do
    entries = for number <- 1..145, do: piece("Cobalt #{number}", number)
    selected = Enum.at(entries, 140)
    {:ok, found, _} = live(conn, ~p"/pages?q=cobalt")
    for _ <- 1..3, do: found |> element("button", "Keep looking") |> render_click()
    assert has_element?(found, ".entry-row[href^='/read/#{hd(entries).id}?'][href*='shown=160']")
    assert has_element?(found, ".entry-row[href^='/read/#{selected.id}?'][href*='shown=160']")

    context = %{
      "from" => "find",
      "q" => "cobalt",
      "shown" => 145,
      "at" => "current-#{selected.id}"
    }

    {:ok, reader, _} = live(conn, ReadingLinks.reader(selected, context))

    assert has_element?(
             reader,
             "#reading-origin[href*='q=cobalt'][href*='shown=160'][href$='#results-current-#{selected.id}']",
             "Back to results"
           )

    {:ok, wander, _} = live(conn, ReadingLinks.wander(selected, context))
    assert has_element?(wander, "#return-to-reading[href*='q=cobalt']")
    {:ok, results, _} = live(conn, ReadingLinks.origin(ReadingPlace.last()))
    assert has_element?(results, "#results-current-#{selected.id}[aria-current='location']")

    assert results
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(".entry-row")
           |> LazyHTML.to_tree()
           |> length() == 145
  end

  test "an earlier Find match stays read only when moving into Wander and returning", %{
    conn: conn
  } do
    original = piece("Earlier heron", 1)

    {:ok, current} =
      Writing.save_entry(original, "Current fox", title: "Current title", checkpoint: true)

    [version] = Writing.list_versions(current)

    context = %{
      "from" => "find",
      "q" => "heron",
      "earlier" => true,
      "version" => version.id,
      "at" => "version-#{version.id}"
    }

    {:ok, reader, _} = live(conn, ReadingLinks.reader(current, context))
    refute has_element?(reader, ".historical-reading mark")
    refute has_element?(reader, "textarea, button[phx-click='restore_version']")
    assert has_element?(reader, "#wander-with-this[href*='version=#{version.id}']")
    {:ok, wander, _} = live(conn, ReadingLinks.wander(current, context))
    assert has_element?(wander, "#return-to-reading[href*='version=#{version.id}']")
    {:ok, back, _} = live(conn, ReadingLinks.resume(ReadingPlace.last()))
    refute has_element?(back, ".historical-reading mark")
    assert has_element?(back, "a[href*='q=heron']", "Back to results")
    back |> element("#open-piece-find") |> render_click()
    render_submit(element(back, "#piece-find-form"), %{"piece_find" => %{"query" => "heron"}})
    assert has_element?(back, ".historical-reading mark", "heron")

    assert has_element?(
             back,
             "#reading-origin[href*='earlier=1'][href$='#results-version-#{version.id}']"
           )

    assert Writing.get_entry!(current.id).body == "Current fox"
    assert Writing.list_versions(current) == [version]
  end

  defp historical(title, body) do
    %Entry{}
    |> Entry.changeset(%{
      origin: "before",
      title: title,
      body: body,
      notebook: "Early Notebooks/Lists 1",
      source_order: System.unique_integer([:positive])
    })
    |> Repo.insert!()
  end

  defp piece(title, order, notebook \\ "Early Notebooks/Lists 1") do
    %Entry{}
    |> Entry.changeset(%{
      origin: "before",
      title: title,
      body: "#{title}\n\n\tWords kept exactly.",
      notebook: notebook,
      source_order: order,
      list_label: to_string(order)
    })
    |> Repo.insert!()
  end
end
