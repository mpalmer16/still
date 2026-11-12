defmodule StillWeb.PacketWorkspaceTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Correspondence, Poems, Storage}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    old = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "words")
    File.mkdir_p!(folder)
    {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      if old,
        do: Application.put_env(:still, :storage_state_directory, old),
        else: Application.delete_env(:still, :storage_state_directory)
    end)

    location = Storage.collection_location()
    {:ok, one} = Poems.save(location, Poems.new(location), %{body: "First poem\nexact words\n"})
    {:ok, two} = Poems.save(location, Poems.new(location), %{body: "Second poem\nother words\n"})
    :ok = Correspondence.set_focus(location, one.id, true)
    :ok = Correspondence.set_focus(location, two.id, true)
    %{location: location, one: one, two: two}
  end

  test "a destination-free packet keeps its order, edits original files, and returns to the packet",
       %{conn: conn, location: loc, one: one, two: two} do
    {:ok, view, _} = live(conn, "/correspondence/packets/new")
    for piece <- [one, two], do: render_click(view, "toggle_piece", %{"id" => piece.id})

    render_submit(element(view, "#packet-form"), %{
      "packet" => %{"title" => "Working sequence", "journal_id" => ""}
    })

    {:ok, overview} = Correspondence.overview(loc)
    [packet] = overview.packets
    assert packet.journal_id == nil
    assert has_element?(view, "#packet-preview", "First poem")
    render_click(view, "move_piece", %{"id" => two.id, "direction" => "up"})
    # Editing saves the packet arrangement before opening the canonical file editor.
    render_click(view, "edit_packet_piece", %{"id" => one.id})
    assert_redirect(view, "/writing/#{one.id}/edit?packet=#{packet.id}")
    {:ok, arranged} = Correspondence.packet(loc, packet.id)
    assert arranged.piece_ids == [two.id, one.id]
    {:ok, editor, _} = live(conn, "/writing/#{one.id}/edit?packet=#{packet.id}")
    assert has_element?(editor, "#save-return-packet", "Save & return to packet")

    render_submit(element(editor, "#file-writing-form"), %{
      "writing" => %{"body" => "First poem\ncorrected words\n"},
      "read" => "true"
    })

    assert_redirect(editor, "/correspondence/packets/#{packet.id}")
    assert {:ok, changed} = Poems.get(loc, one.id)
    assert changed.body == "First poem\ncorrected words\n"
    assert {:ok, [_]} = Poems.revisions(loc, one.id)
    {:ok, returned, _} = live(conn, "/correspondence/packets/#{packet.id}")
    assert has_element?(returned, "#packet-preview", "corrected words")

    assert has_element?(
             returned,
             "#packet-form input[name='packet[title]'][value='Working sequence']"
           )

    assert {:ok, untouched} = Poems.get(loc, two.id)
    assert untouched.body == two.body
  end

  test "an unmarked scratch letter can be linked separately from the manuscript", %{
    conn: conn,
    location: loc,
    one: one
  } do
    {:ok, letter} =
      Still.Writing.Files.save_to_scratch(loc, Poems.new(loc), %{
        body: "Dear editors,\n\nPlease consider these poems.\n"
      })

    {:ok, packet} =
      Correspondence.save_packet(loc, %{
        title: "Without a place yet",
        piece_ids: [one.id],
        cover_letter: "Old inline draft"
      })

    {:ok, view, _} = live(conn, "/correspondence/packets/#{packet.id}")
    render_click(view, "choose_cover_letter", %{})
    assert has_element?(view, "#packet-cover-letter option[value='#{letter.id}']")

    render_change(element(view, "#packet-form"), %{
      "packet" => %{"cover_letter_piece_id" => letter.id}
    })

    assert has_element?(view, "#packet-letter-preview", "Please consider these poems.")

    render_submit(element(view, "#packet-form"), %{
      "packet" => %{
        "title" => packet.title,
        "journal_id" => "",
        "cover_letter_piece_id" => letter.id
      }
    })

    assert {:ok, saved} = Correspondence.packet(loc, packet.id)
    assert saved.cover_letter_piece_id == letter.id
    assert saved.cover_letter == nil
    assert saved.piece_ids == [one.id]
    refute Map.get(Correspondence.writing_status(loc).focused, letter.id, false)
    assert {:ok, export} = Correspondence.export_packet(loc, packet.id)
    assert Enum.map(export.pieces, & &1.id) == [one.id]
    assert export.journal == nil
    assert {:error, message} = Correspondence.submit(loc, packet.id, saved.token, "2026-11-12")
    assert message =~ "Choose a destination"
  end

  test "duplicate in the UI leaves a declined send and its exact words untouched", %{
    conn: conn,
    location: loc,
    one: one
  } do
    {:ok, journal} = Correspondence.save_journal(loc, %{name: "A journal"})

    {:ok, packet} =
      Correspondence.save_packet(loc, %{
        title: "An earlier send",
        journal_id: journal.id,
        piece_ids: [one.id]
      })

    {:ok, sent} = Correspondence.submit(loc, packet.id, packet.token, "2026-11-01")

    {:ok, declined} =
      Correspondence.respond(
        loc,
        sent.id,
        sent.token,
        "declined",
        "A kind reply",
        "2026-11-10",
        []
      )

    {:ok, view, _} = live(conn, "/correspondence/packets/#{declined.id}")
    view |> element("#duplicate-packet") |> render_click()
    {:ok, overview} = Correspondence.overview(loc)
    copy = Enum.find(overview.packets, &(&1.id != declined.id))
    assert_patch(view, "/correspondence/packets/#{copy.id}")
    assert copy.status == "preparing"
    assert copy.journal_id == nil
    assert copy.piece_ids == [one.id]
    assert copy.events == []
    assert {:ok, original} = Correspondence.packet(loc, declined.id)
    assert original == declined
  end

  test "Correspondence has one navigation and directory filters survive patching", %{
    conn: conn,
    one: one
  } do
    {:ok, view, _} = live(conn, "/correspondence/writing")
    refute has_element?(view, ".site-header")
    assert has_element?(view, "#back-to-still[href='/']")
    view |> element("#works-filters") |> render_submit(%{"works" => %{"q" => "First"}})
    assert has_element?(view, "#work-directory-row-#{one.id}")
    assert has_element?(view, "#works-filters input[value='First']")
    assert has_element?(view, "details.corr-directory-filters")
  end
end
