defmodule StillWeb.CorrespondenceLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Correspondence, Poems, Storage}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    collection = Path.join(root, "collection")
    File.mkdir_p!(collection)
    {:ok, _} = Storage.set_folder(collection)

    on_exit(fn -> Application.put_env(:still, :storage_state_directory, previous) end)

    %{location: Storage.collection_location()}
  end

  test "Correspondence keeps the work on its own shelf and preserves the exact sent text", %{
    conn: conn,
    location: location
  } do
    {:ok, piece} =
      Poems.save(location, Poems.new(location), %{
        title: "A Window at Dusk",
        body: "The lamp comes on\nbefore anyone arrives."
      })

    {:ok, works, _} = live(conn, ~p"/correspondence/writing")
    refute has_element?(works, "#correspondence-work-#{piece.id}")

    {:ok, reading, _} = live(conn, ~p"/writing/#{piece.id}")
    reading |> element("#submission-focus") |> render_click()
    assert has_element?(reading, "#submission-focus[aria-pressed=true]")
    assert {:ok, unchanged} = Poems.get(location, piece.id)
    assert unchanged.path == piece.path
    assert unchanged.token == piece.token
    assert File.read!(piece.path) == piece.body

    {:ok, home, _html} = live(conn, ~p"/correspondence")
    refute has_element?(home, "#desk-piece-title")
    assert has_element?(home, ".corr-home-summary[href='/correspondence/writing']", "1")
    assert has_element?(home, ".corr-home-primary-action", "Prepare a packet")

    {:ok, journal_view, _html} = live(conn, ~p"/correspondence/journals/new")

    render_submit(element(journal_view, "#journal-form"), %{
      "journal" => %{
        "name" => "Field Notes Review",
        "website" => "https://example.test",
        "submission_url" => "https://example.test/submit",
        "interests" => "Poems about ordinary attention",
        "guidelines" => "Send up to three poems.",
        "simultaneous_policy" => "allowed",
        "verified" => "true"
      }
    })

    assert {:ok, %{journals: [journal]}} = Correspondence.overview(location)

    {:ok, packet_view, _html} = live(conn, ~p"/correspondence/packets/new")
    render_click(element(packet_view, "[phx-click='toggle_piece'][phx-value-id='#{piece.id}']"))

    render_submit(element(packet_view, "#packet-form"), %{
      "packet" => %{
        "title" => "Two small poems",
        "journal_id" => journal.id,
        "preparation_notes" => "Lead with the quieter poem.",
        "cover_letter" => "Dear editors, please consider this work."
      }
    })

    assert {:ok, %{packets: [packet]}} = Correspondence.overview(location)
    assert packet.piece_ids == [piece.id]

    render_change(element(packet_view, "#packet-form"), %{
      "packet" => %{
        "title" => "An unsaved title",
        "journal_id" => "",
        "preparation_notes" => "Lead with the quieter poem.",
        "cover_letter" => "Dear editors, please consider this work."
      }
    })

    render_submit(element(packet_view, ".corr-send-form"), %{
      "date" => Date.to_iso8601(Date.utc_today())
    })

    assert has_element?(packet_view, ".corr-message.error", "Save your packet changes")
    assert {:ok, unsent} = Correspondence.packet(location, packet.id)
    assert unsent.status == "preparing"

    render_change(element(packet_view, "#packet-form"), %{
      "packet" => %{
        "title" => "Two small poems",
        "journal_id" => journal.id,
        "preparation_notes" => "Lead with the quieter poem.",
        "cover_letter" => "Dear editors, please consider this work."
      }
    })

    render_submit(element(packet_view, "#packet-form"), %{
      "packet" => %{
        "title" => "Two small poems",
        "journal_id" => journal.id,
        "preparation_notes" => "Lead with the quieter poem.",
        "cover_letter" => "Dear editors, please consider this work."
      }
    })

    render_submit(element(packet_view, ".corr-send-form"), %{
      "date" => Date.to_iso8601(Date.utc_today())
    })

    assert {:ok, sent} = Correspondence.packet(location, packet.id)
    assert sent.status == "submitted"

    assert sent.snapshot.pieces |> hd() |> Map.fetch!(:body) ==
             "A Window at Dusk\n\nThe lamp comes on\nbefore anyone arrives."

    {:ok, editor, _} = live(conn, ~p"/writing/#{piece.id}/edit")
    assert has_element?(editor, "#submitted-writing-note", "Saving edits creates a new version")
    revised = "A Window at Dusk\n\nThe lamp comes on\nafter the house is quiet."
    render_submit(element(editor, "#file-writing-form"), %{"writing" => %{"body" => revised}})
    assert {:ok, changed} = Poems.get(location, piece.id)
    assert {:ok, revisions} = Poems.revisions(location, piece.id)
    assert Enum.any?(revisions, &(&1.body == piece.body))
    assert changed.body == "A Window at Dusk\n\nThe lamp comes on\nafter the house is quiet."
    assert {:ok, still_sent} = Correspondence.packet(location, packet.id)

    assert still_sent.snapshot.pieces |> hd() |> Map.fetch!(:body) ==
             "A Window at Dusk\n\nThe lamp comes on\nbefore anyone arrives."

    render_submit(element(packet_view, "#response-form"), %{
      "response" => %{
        "status" => "declined",
        "date" => Date.to_iso8601(Date.utc_today()),
        "notes" => "A kind note from the editors."
      }
    })

    assert has_element?(packet_view, ".corr-packet-timeline", "A kind note from the editors.")
    {:ok, reopened_packet, _html} = live(conn, ~p"/correspondence/packets/#{packet.id}")
    assert has_element?(reopened_packet, ".corr-packet-timeline", "A kind note from the editors.")

    {:ok, piece_view, _html} = live(conn, ~p"/correspondence/writing/#{piece.id}")
    assert has_element?(piece_view, ".corr-manuscript", "after the house is quiet")
    assert has_element?(piece_view, ".corr-history", "before anyone arrives")

    assert has_element?(
             piece_view,
             "a[href='/correspondence/journals/#{journal.id}']",
             "Journal details"
           )

    assert has_element?(piece_view, "a[href='/correspondence/packets/new?from=#{packet.id}']")

    piece_view |> element("#submission-focus") |> render_click()
    assert has_element?(piece_view, "#submission-focus[aria-pressed=false]")
    {:ok, works, _} = live(conn, ~p"/correspondence/writing")
    refute has_element?(works, "#correspondence-work-#{piece.id}")
    assert {:ok, packet_after_unmarking} = Correspondence.packet(location, packet.id)
    assert hd(packet_after_unmarking.snapshot.pieces).body == piece.body
  end

  test "packet preview expands links, PDF requests are correlated, and private notes remain editable after sending",
       %{conn: conn, location: location} do
    {:ok, source} =
      Poems.save(location, Poems.new(location), %{
        title: "Inserted poem",
        body: "Exact inserted words"
      })

    {:ok, host} =
      Poems.save(location, Poems.new(location), %{
        title: "Host poem",
        body: Still.Writing.PoemReferences.marker(source)
      })

    {:ok, journal} =
      Correspondence.save_journal(location, %{
        name: "Quiet Review",
        submission_url: "https://example.test/submit"
      })

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Autumn",
        journal_id: journal.id,
        piece_ids: [host.id],
        preparation_notes: "Private original"
      })

    {:ok, view, _} = live(conn, ~p"/correspondence/packets/#{packet.id}")
    assert has_element?(view, "#packet-preview", "Exact inserted words")
    refute has_element?(view, "#packet-preview", "[[poem:")
    assert has_element?(view, "a[href='https://example.test/submit']")
    render_click(view, "export_packet_pdf", %{})
    assert_push_event(view, "writing-pdf-request", %{ticket: ticket, request_id: request_id})

    assert {:ok, %{kind: "packet", id: id}} =
             Phoenix.Token.verify(StillWeb.Endpoint, "writing-pdf-export", ticket, max_age: 300)

    assert id == packet.id

    render_click(view, "pdf_export_finished", %{
      "request_id" => "unrelated",
      "path" => "/wrong.pdf"
    })

    refute has_element?(view, ".corr-packet-export", "wrong.pdf")

    render_click(view, "pdf_export_finished", %{
      "request_id" => request_id,
      "path" => "/verified.pdf"
    })

    assert has_element?(view, ".corr-packet-export", "verified.pdf")
    render_submit(element(view, ".corr-send-form"), %{"date" => "2026-11-11"})
    assert has_element?(view, "#packet-notes-body", "Private original")
    {:ok, sent} = Correspondence.packet(location, packet.id)

    render_hook(view, "save_packet_notes", %{
      "id" => packet.id,
      "body" => "A long private note\n  with indentation",
      "token" => ""
    })

    assert {:ok, notes} = Still.Correspondence.PacketNotes.get(location, packet.id)
    assert notes.body == "A long private note\n  with indentation"
    assert {:ok, same_sent} = Correspondence.packet(location, packet.id)
    assert same_sent.token == sent.token
    assert same_sent.snapshot == sent.snapshot

    render_hook(view, "save_packet_notes", %{
      "id" => packet.id,
      "body" => "Stale note",
      "token" => ""
    })

    assert {:ok, ^notes} = Still.Correspondence.PacketNotes.get(location, packet.id)
    File.write!(source.path, "Later words")
    {:ok, reopened, _} = live(conn, ~p"/correspondence/packets/#{packet.id}")
    assert has_element?(reopened, ".corr-snapshot", "Exact inserted words")
    refute has_element?(reopened, ".corr-snapshot", "Later words")
  end

  test "an empty collection has a gentle first step and no invented activity", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/correspondence")

    assert has_element?(view, ".corr-home-preparing", "No packets are being prepared.")

    assert has_element?(
             view,
             ".corr-home-summary[href='/correspondence/writing']",
             "Works"
           )

    assert has_element?(view, ".corr-home-summary[href='/correspondence/journals']", "Places")
    refute has_element?(view, ".corr-journey")
  end
end
