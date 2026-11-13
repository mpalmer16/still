defmodule StillWeb.PacketSearchTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Correspondence, Poems, Storage}
  alias Still.Correspondence.PacketNotes

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

    %{location: Storage.collection_location()}
  end

  test "packet search uses the latest independently saved notes and drops cleared legacy terms",
       %{
         conn: conn,
         location: location
       } do
    journal = save_journal(location, "Notes Review")
    packet = save_packet(location, journal, [], "Notes packet", "legacy preparation phrase")

    assert {:ok, legacy} = Correspondence.packet(location, packet.id)
    assert legacy.preparation_notes == "legacy preparation phrase"

    assert {:ok, notes} = PacketNotes.get(location, packet.id)
    assert notes.body == "legacy preparation phrase"

    assert {:ok, saved} =
             PacketNotes.save(location, packet.id, "latest independent note phrase", notes.token)

    {:ok, view, _} = live(conn, "/correspondence/packets")
    search(view, "latest independent note phrase")
    assert has_element?(view, "#packet-directory-row-#{packet.id}")
    search(view, "legacy preparation phrase")
    refute has_element?(view, "#packet-directory-row-#{packet.id}")

    assert {:ok, _cleared} = PacketNotes.save(location, packet.id, "", saved.token)
    {:ok, refreshed, _} = live(conn, "/correspondence/packets")
    search(refreshed, "latest independent note phrase")
    refute has_element?(refreshed, "#packet-directory-row-#{packet.id}")
  end

  test "inline draft letters and linked draft letters use their current words", %{
    conn: conn,
    location: location
  } do
    journal = save_journal(location, "Draft Review")
    inline = save_packet(location, journal, [], "Inline draft", "", "inline letter phrase")
    linked_letter = save_piece(location, "Linked letter", "first linked letter phrase")

    {:ok, linked} =
      Correspondence.save_packet(location, %{
        title: "Linked draft",
        journal_id: journal.id,
        piece_ids: [save_piece(location, "Linked packet work", "Packet work text.").id],
        cover_letter_piece_id: linked_letter.id
      })

    {:ok, view, _} = live(conn, "/correspondence/packets")
    search(view, "inline letter phrase")
    assert has_element?(view, "#packet-directory-row-#{inline.id}")
    search(view, "first linked letter phrase")
    assert has_element?(view, "#packet-directory-row-#{linked.id}")

    {:ok, current_letter} = Poems.get(location, linked_letter.id)

    {:ok, _} =
      Poems.save(location, current_letter, %{
        title: "Linked letter",
        body: "revised external letter phrase"
      })

    {:ok, reopened, _} = live(conn, "/correspondence/packets")
    search(reopened, "revised external letter phrase")
    assert has_element?(reopened, "#packet-directory-row-#{linked.id}")
    search(reopened, "first linked letter phrase")
    refute has_element?(reopened, "#packet-directory-row-#{linked.id}")
  end

  test "submitted linked letters stay searchable by the frozen words after source removal", %{
    conn: conn,
    location: location
  } do
    journal = save_journal(location, "Snapshot Review")
    letter = save_piece(location, "Sent letter", "frozen submitted letter phrase")

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Submitted linked letter",
        journal_id: journal.id,
        piece_ids: [save_piece(location, "Submitted work", "Submitted manuscript.").id],
        cover_letter_piece_id: letter.id
      })

    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-11-02")
    {:ok, current_letter} = Poems.get(location, letter.id)

    {:ok, _} =
      Poems.save(location, current_letter, %{title: "Sent letter", body: "new source-only phrase"})

    {:ok, changed_letter} = Poems.get(location, letter.id)
    {:ok, _} = Poems.trash(location, changed_letter)

    {:ok, view, _} = live(conn, "/correspondence/packets")
    search(view, "frozen submitted letter phrase")
    assert has_element?(view, "#packet-directory-row-#{sent.id}")
    search(view, "new source-only phrase")
    refute has_element?(view, "#packet-directory-row-#{sent.id}")
  end

  test "recorded response notes combine with destination and status filters", %{
    conn: conn,
    location: location
  } do
    journal = save_journal(location, "Quiet Harbor Press")
    packet = save_packet(location, journal, [], "Response packet")
    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-11-03")

    {:ok, declined} =
      Correspondence.respond(
        location,
        sent.id,
        sent.token,
        "declined",
        "distinctive response note phrase",
        "2026-11-05"
      )

    {:ok, view, _} = live(conn, "/correspondence/packets")
    search(view, "distinctive Quiet Harbor Press declined")
    assert has_element?(view, "#packet-directory-row-#{declined.id}")

    view
    |> element("#packets-filters")
    |> render_change(%{
      "packets" => %{"q" => "distinctive response note phrase", "status" => "declined"}
    })

    assert_patch(
      view,
      "/correspondence/packets?destination=all&direction=desc&page=1&q=distinctive+response+note+phrase&sort=recent&status=declined"
    )

    assert has_element?(view, "#packet-directory-row-#{declined.id}")
  end

  defp search(view, query) do
    view
    |> element("#packets-filters")
    |> render_change(%{"packets" => %{"q" => query}})
  end

  defp save_piece(location, title, body) do
    {:ok, piece} = Poems.save(location, Poems.new(location), %{title: title, body: body})
    piece
  end

  defp save_journal(location, name) do
    {:ok, journal} = Correspondence.save_journal(location, %{name: name})
    journal
  end

  defp save_packet(location, journal, pieces, title, notes \\ "", cover_letter \\ nil) do
    pieces =
      if pieces == [],
        do: [save_piece(location, "#{title} work", "Packet manuscript.")],
        else: pieces

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: title,
        journal_id: journal.id,
        piece_ids: Enum.map(pieces, & &1.id),
        preparation_notes: notes,
        cover_letter: cover_letter
      })

    packet
  end
end
