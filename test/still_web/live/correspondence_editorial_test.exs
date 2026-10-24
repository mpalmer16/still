defmodule StillWeb.CorrespondenceEditorialTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Correspondence, Poems, Storage, Writing}

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

  test "empty editorial spaces offer honest first steps and usable navigation", %{conn: conn} do
    {:ok, home, _} = live(conn, "/correspondence")
    assert has_element?(home, "#correspondence-home")
    assert has_element?(home, "h1#desk-heading", "On the desk")
    refute has_element?(home, ".corr-hero")
    refute render(home) =~ "A wider world for the words."
    refute render(home) =~ "THE WORK, IN MOTION"
    assert has_element?(home, "#open-correspondence[aria-current='page']")
    assert has_element?(home, "a[href='/correspondence/writing']")
    refute has_element?(home, ".corr-journey")

    {:ok, places, _} = live(conn, "/correspondence/journals")
    assert has_element?(places, "#places-directory")
    assert has_element?(places, "a[href='/correspondence/journals/new']", "Add a place")

    {:ok, writing, _} = live(conn, "/correspondence/writing")
    assert has_element?(writing, "#correspondence-search[aria-label='Search works']")
    assert has_element?(writing, "a[href='/correspondence/packets/new']")
  end

  test "a small collection connects a manuscript to its current text, history, and place", %{
    conn: conn,
    location: location
  } do
    {:ok, piece} =
      save_piece(location, "Small collection poem", "A first saved line.\nA second line.")

    {:ok, _other} = save_piece(location, "Another saved page", "A second manuscript.")
    {:ok, journal} = save_journal(location, "Small Press")

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Small collection submission",
        journal_id: journal.id,
        piece_ids: [piece.id]
      })

    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-20")

    {:ok, replied} =
      Correspondence.respond(
        location,
        sent.id,
        sent.token,
        "declined",
        "A thoughtful reply.",
        "2026-10-22"
      )

    {:ok, work, _} = live(conn, "/correspondence/writing/#{piece.id}")
    assert has_element?(work, "#work-history")
    assert has_element?(work, ".corr-manuscript", "A first saved line.")
    assert has_element?(work, "#work-history", "A thoughtful reply.")
    assert has_element?(work, "a[href='/correspondence/journals/#{journal.id}']")
    assert has_element?(work, "a[href='/correspondence/packets/#{replied.id}']")
    assert has_element?(work, "a[href='/writing/#{piece.id}/edit']", "Edit in Now")

    {:ok, journal_view, _} = live(conn, "/correspondence/journals/#{journal.id}")
    assert has_element?(journal_view, "h1", "Small Press")
    assert has_element?(journal_view, ".corr-history", "Small collection submission")
    assert has_element?(journal_view, "a[href='/correspondence/packets/#{packet.id}']")
  end

  test "a place suggests only a saved destination to a new packet", %{
    conn: conn,
    location: location
  } do
    {:ok, journal} = save_journal(location, "Suggested destination")
    {:ok, view, _} = live(conn, "/correspondence/packets/new?journal=#{journal.id}")

    assert has_element?(
             view,
             "select[name='packet[journal_id]'] option[selected][value='#{journal.id}']"
           )

    {:ok, unknown, _} = live(conn, "/correspondence/packets/new?journal=missing")
    refute has_element?(unknown, "select[name='packet[journal_id]'] option[selected]")
  end

  test "packet ordering, frozen text, reply history, and preparing again survive the full workflow",
       %{
         conn: conn,
         location: location
       } do
    {:ok, first} =
      save_piece(location, "First in selection", "First exact words\r\nwith a second line.\n")

    {:ok, second} = save_piece(location, "Second in selection", "Second exact words\n")
    {:ok, journal} = save_journal(location, "Workflow Review")
    {:ok, _legacy} = Writing.save_entry(nil, "SQLite-only legacy words")
    sqlite_before = Writing.list_entries()

    {:ok, packet_view, _} = live(conn, "/correspondence/packets/new")
    render_click(element(packet_view, "[phx-click='toggle_piece'][phx-value-id='#{first.id}']"))
    render_click(element(packet_view, "[phx-click='toggle_piece'][phx-value-id='#{second.id}']"))

    render_click(
      element(
        packet_view,
        "[phx-click='move_piece'][phx-value-id='#{first.id}'][phx-value-direction='down']"
      )
    )

    assert_order(render(element(packet_view, ".corr-ordered")), [
      "Second in selection",
      "First in selection"
    ])

    render_submit(element(packet_view, "#packet-form"), %{
      "packet" => %{
        "title" => "Two piece packet",
        "journal_id" => journal.id,
        "preparation_notes" => "Second piece leads.",
        "cover_letter" => "Please consider these poems."
      }
    })

    assert has_element?(packet_view, "#packet-preview")
    assert has_element?(packet_view, "#packet-preview", "Second exact words")
    assert has_element?(packet_view, "#packet-preview", "First exact words")

    assert_order(render(element(packet_view, "#packet-preview")), [
      "Second exact words",
      "First exact words"
    ])

    render_submit(element(packet_view, ".corr-send-form"), %{"date" => "2026-10-23"})
    assert has_element?(packet_view, "[role='status']", "submitted text is now preserved")
    assert has_element?(packet_view, ".corr-snapshot", "First exact words")

    {:ok, changed} = Poems.get(location, first.id)

    {:ok, _changed} =
      Poems.save(location, changed, %{title: "First in selection", body: "A later revision."})

    {:ok, overview} = Correspondence.overview(location)
    packet = Enum.find(overview.packets, &(&1.title == "Two piece packet"))

    assert Enum.map(packet.snapshot.pieces, & &1.body) == [
             "Second exact words\n",
             "First exact words\r\nwith a second line.\n"
           ]

    render_submit(element(packet_view, "#response-form"), %{
      "response" => %{
        "status" => "declined",
        "date" => "2026-10-25",
        "notes" => "A reply after careful reading."
      }
    })

    assert has_element?(packet_view, ".corr-packet-timeline", "A reply after careful reading.")

    {:ok, work, _} = live(conn, "/correspondence/writing/#{first.id}")
    assert has_element?(work, ".corr-manuscript", "A later revision.")
    assert has_element?(work, "#work-history", "First exact words")
    assert has_element?(work, "#work-history", "A reply after careful reading.")
    assert has_element?(work, "a[href='/correspondence/packets/new?from=#{packet.id}']")

    {:ok, again, _} = live(conn, "/correspondence/packets/new?from=#{packet.id}")
    assert has_element?(again, "#packet-preview", "First in selection")
    assert has_element?(again, "#packet-form")
    assert Writing.list_entries() == sqlite_before
    refute render(again) =~ "SQLite-only"
  end

  test "established synthetic collections keep every piece and place discoverable", %{
    conn: conn,
    location: location
  } do
    pieces = for n <- 1..12, do: save_piece!(location, "Established piece #{n}", "Body #{n}.")
    journals = for n <- 1..4, do: save_journal!(location, "Established journal #{n}")

    for n <- 1..8 do
      piece = Enum.at(pieces, rem(n - 1, length(pieces)))
      journal = Enum.at(journals, rem(n - 1, length(journals)))

      {:ok, packet} =
        Correspondence.save_packet(location, %{
          title: "Established packet #{n}",
          journal_id: journal.id,
          piece_ids: [piece.id]
        })

      {:ok, sent} =
        Correspondence.submit(
          location,
          packet.id,
          packet.token,
          "2026-10-#{String.pad_leading(Integer.to_string(n), 2, "0")}"
        )

      case rem(n, 3) do
        0 ->
          Correspondence.respond(
            location,
            sent.id,
            sent.token,
            "declined",
            "Returned #{n}",
            "2026-10-22"
          )

        1 ->
          Correspondence.set_status(location, sent.id, sent.token, "awaiting")

        _ ->
          :ok
      end
    end

    {:ok, home, _} = live(conn, "/correspondence")
    assert has_element?(home, "#correspondence-home")

    {:ok, writing, _} = live(conn, "/correspondence/writing")
    for piece <- pieces, do: assert(has_element?(writing, ".corr-library-piece", piece.title))

    {:ok, places, _} = live(conn, "/correspondence/journals")
    for journal <- journals, do: assert(has_element?(places, "#places-directory", journal.name))

    {:ok, packets, _} = live(conn, "/correspondence/packets")

    for n <- 1..8,
        do: assert(has_element?(packets, ".corr-library-piece", "Established packet #{n}"))
  end

  defp save_piece(location, title, body),
    do: Poems.save(location, Poems.new(location), %{title: title, body: body})

  defp save_piece!(location, title, body) do
    {:ok, piece} = save_piece(location, title, body)
    piece
  end

  defp save_journal(location, name),
    do:
      Correspondence.save_journal(location, %{
        name: name,
        guidelines: "Poetry welcome",
        shortlisted: true
      })

  defp save_journal!(location, name) do
    {:ok, journal} = save_journal(location, name)
    journal
  end

  defp assert_order(html, texts) do
    positions = Enum.map(texts, &:binary.match(html, &1))
    assert Enum.all?(positions, &match?({_, _}, &1))
    offsets = Enum.map(positions, fn {offset, _} -> offset end)
    assert offsets == Enum.sort(offsets)
  end
end
