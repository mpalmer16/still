defmodule StillWeb.ReaderPacketTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Correspondence, Poems, Repo, Storage, Writing}
  alias Still.Writing.{Entry, Notebooks, ReadingPlace}

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

  test "notebook reading appends once to an existing draft without disturbing reader context", %{
    conn: conn,
    folder: folder,
    location: location
  } do
    source =
      notebook_piece(
        folder,
        "Field book 4",
        "04a",
        "Source title:",
        "Source exact words\n\n  kept"
      )

    existing = saved_piece(location, "Existing title", "Existing packet words\n")
    draft = packet(location, [existing.id], "Letter draft")

    {:ok, view, _} =
      live(
        conn,
        ~p"/notebooks/read/#{source.entry_id}?from=find&q=heron&shown=80&at=current-#{source.entry_id}"
      )

    assert ReadingPlace.last().entry.id == source.entry_id
    assert ReadingPlace.last().context["q"] == "heron"
    assert ReadingPlace.last().context["at"] == "current-#{source.entry_id}"

    view |> element("#open-piece-find") |> render_click()

    render_change(element(view, "#piece-find-form"), %{
      "piece_find" => %{"query" => "kept"},
      "_target" => ["piece_find", "query"]
    })

    render_submit(element(view, "#piece-find-form"), %{
      "piece_find" => %{"query" => "kept"}
    })

    assert has_element?(view, "#passage-4[data-search-target='true'] mark", "kept")

    assert has_element?(
             view,
             "#reading-origin[href*='q=heron'][href*='current-#{source.entry_id}']"
           )

    view |> element("#add-to-packet-bottom") |> render_click()
    assert has_element?(view, "#reader-packet-dialog")

    form = element(view, "#reader-packet-form")
    render_submit(form, %{"packet" => %{"destination" => draft.id, "title" => "ignored"}})

    assert has_element?(view, "#reader-packet-notice")
    assert has_element?(view, "#notebook-content", "Source exact words")
    assert has_element?(view, "#piece-find-query[value='kept']")
    assert has_element?(view, "#passage-4[data-search-target='true'] mark", "kept")

    assert has_element?(
             view,
             "#reading-origin[href*='q=heron'][href*='current-#{source.entry_id}']"
           )

    assert ReadingPlace.last().entry.id == source.entry_id
    assert ReadingPlace.last().context["q"] == "heron"

    assert {:ok, updated} = Correspondence.packet(location, draft.id)
    assert updated.piece_ids == [existing.id, source.id]

    assert File.read!(Path.join(folder, existing.relative_path)) ==
             "Existing title\n\nExisting packet words\n"

    refute has_element?(view, "#reader-packet-form")
    view |> element("#reader-packet-close") |> render_click()
    refute has_element?(view, "#reader-packet-dialog")
    assert has_element?(view, "#notebook-content", "Source exact words")
    assert has_element?(view, "#piece-find-query[value='kept']")
    assert has_element?(view, "#passage-4[data-search-target='true'] mark", "kept")
  end

  test "earlier versions do not offer packet creation", %{
    conn: conn,
    folder: folder,
    location: location
  } do
    source =
      notebook_piece(folder, "Field book 9", "09b", "Earlier title:", "Earlier exact words\n")

    {:ok, current} = Poems.get(location, source.id)
    {:ok, _} = Poems.save(location, current, %{title: "Current title:", body: "Current words\n"})
    {:ok, _} = Writing.with_collection_snapshot(fn -> {:ok, :refreshed} end)
    entry = Writing.get_entry!(source.entry_id)
    [version | _] = Writing.list_versions(entry)

    {:ok, view, _} = live(conn, ~p"/notebooks/read/#{entry.id}?version=#{version.id}")
    assert has_element?(view, ".historical-notice", "Earlier words")
    refute has_element?(view, "#notebook-content a", "Edit")
    refute has_element?(view, "#add-to-packet")
    assert {:ok, []} = Correspondence.draft_packets(location)
    assert {:ok, loaded} = Poems.get(location, source.id)
    assert loaded.body == "Current title:\n\nCurrent words\n"
  end

  test "Wander and saved scratch reading remain on their readers after adding", %{
    conn: conn,
    folder: folder,
    location: location
  } do
    source = notebook_piece(folder, "Field book 2", "2", "Wander title", "Wander words\n")
    {:error, {:live_redirect, %{to: wander_path}}} = live(conn, ~p"/wander")
    {:ok, wander, _} = live(conn, wander_path)
    wander |> element("#add-to-packet") |> render_click()

    render_submit(element(wander, "#reader-packet-form"), %{
      "packet" => %{"destination" => "new", "title" => "From Wander"}
    })

    assert has_element?(wander, "#reading-title", "Wander title")
    assert has_element?(wander, ".drift-room")
    assert {:ok, [wander_packet]} = Correspondence.draft_packets(location)
    assert wander_packet.title == "From Wander"
    assert wander_packet.piece_ids == [source.id]

    scratch = saved_piece(location, "Scratch", "Scratch words\n")
    {:ok, writing, _} = live(conn, ~p"/writing/#{scratch.id}")
    writing |> element("#add-to-packet") |> render_click()

    render_submit(element(writing, "#reader-packet-form"), %{
      "packet" => %{"destination" => "new", "title" => "From scratch"}
    })

    assert render(writing) =~ "Scratch words"
    assert {:ok, packets} = Correspondence.draft_packets(location)

    assert MapSet.new(Enum.map(packets, & &1.title)) ==
             MapSet.new(["From Wander", "From scratch"])

    assert Enum.any?(packets, &(&1.piece_ids == [scratch.id]))
  end

  test "stale and sent destinations are rejected while preserving the notebook reader", %{
    conn: conn,
    folder: folder,
    location: location
  } do
    source = notebook_piece(folder, "Field book 5", "5", "Reader", "Reader words")
    first = saved_piece(location, "First", "First words")
    draft = packet(location, [first.id], "Draft")
    {:ok, journal} = Correspondence.save_journal(location, %{name: "A journal"})
    {:ok, view, _} = live(conn, ~p"/notebooks/read/#{source.entry_id}")
    view |> element("#add-to-packet") |> render_click()

    assert {:ok, changed} =
             Correspondence.save_packet(
               location,
               %{title: "Changed elsewhere", piece_ids: [first.id], journal_id: journal.id},
               draft.id,
               draft.token
             )

    assert {:ok, _sent} = Correspondence.submit(location, changed.id, changed.token, "2026-11-13")

    render_submit(element(view, "#reader-packet-form"), %{
      "packet" => %{"destination" => draft.id, "title" => "ignored"}
    })

    assert has_element?(view, "#reader-packet-problem")
    assert has_element?(view, "#notebook-content", "Reader words")
    assert {:ok, []} = Correspondence.draft_packets(location)
  end

  test "refreshing a stale draft preserves its newer order and notes before appending", %{
    conn: conn,
    folder: folder,
    location: location
  } do
    source = notebook_piece(folder, "Field book 7", "7", "Reader", "Reader words")
    first = saved_piece(location, "First", "First words")
    middle = saved_piece(location, "Middle", "Middle words")
    draft = packet(location, [first.id], "Draft")
    {:ok, view, _} = live(conn, ~p"/notebooks/read/#{source.entry_id}")
    view |> element("#add-to-packet") |> render_click()

    assert {:ok, updated} =
             Correspondence.save_packet(
               location,
               %{
                 title: "Draft after refresh",
                 piece_ids: [first.id, middle.id],
                 preparation_notes: "\tKeep these notes\n"
               },
               draft.id,
               draft.token
             )

    render_submit(element(view, "#reader-packet-form"), %{
      "packet" => %{"destination" => draft.id, "title" => "ignored"}
    })

    assert has_element?(view, "#reader-packet-problem", "Refresh drafts")
    assert has_element?(view, "#notebook-content", "Reader words")
    view |> element("#reader-packet-refresh") |> render_click()

    render_submit(element(view, "#reader-packet-form"), %{
      "packet" => %{"destination" => draft.id, "title" => "ignored"}
    })

    assert has_element?(view, "#reader-packet-notice")
    assert {:ok, appended} = Correspondence.packet(location, updated.id)
    assert appended.piece_ids == [first.id, middle.id, source.id]
    assert appended.title == "Draft after refresh"
    assert appended.preparation_notes == "\tKeep these notes\n"
  end

  test "switching the selected collection while the chooser is open does not create elsewhere", %{
    conn: conn,
    folder: folder,
    location: location,
    tmp_dir: root
  } do
    source = notebook_piece(folder, "Field book 6", "6", "Reader", "Reader words")
    {:ok, view, _} = live(conn, ~p"/notebooks/read/#{source.entry_id}")
    view |> element("#add-to-packet") |> render_click()

    other_folder = Path.join(root, "other-collection")
    File.mkdir_p!(other_folder)
    assert {:ok, _} = Storage.set_folder(other_folder)

    render_submit(element(view, "#reader-packet-form"), %{
      "packet" => %{"destination" => "new", "title" => "Must not appear elsewhere"}
    })

    assert has_element?(view, "#reader-packet-problem")
    assert has_element?(view, "#notebook-content", "Reader words")
    assert {:ok, []} = Correspondence.draft_packets(Storage.collection_location())
    assert {:error, _} = Correspondence.draft_packets(location)
  end

  defp notebook_piece(folder, notebook_key, filename, title, body) do
    {:ok, notebook} = Writing.create_notebook(%{key: notebook_key, label: notebook_key})
    path = Path.join([folder, notebook_key, filename])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, title <> "\n" <> body)
    assert {:ok, [piece]} = Poems.list(Storage.collection_location())

    assert {:ok, piece} =
             Poems.save(Storage.collection_location(), piece, %{
               body: title <> "\n" <> body,
               title_line: 1
             })

    {:ok, entry} =
      Writing.with_collection_snapshot(fn ->
        entry = Repo.get_by!(Entry, file_id: piece.id)
        Notebooks.assign_entry(entry, notebook, %{source_order: 1, list_label: filename})
      end)

    Map.put(piece, :entry_id, entry.id)
  end

  defp saved_piece(location, title, body) do
    poem = Poems.new(location)
    {:ok, piece} = Poems.save(location, poem, %{title: title, body: body})
    piece
  end

  defp packet(location, ids, title) do
    {:ok, packet} = Correspondence.save_packet(location, %{title: title, piece_ids: ids})
    packet
  end
end
