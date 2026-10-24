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

    {:ok, home, _html} = live(conn, ~p"/correspondence")
    refute has_element?(home, "#desk-piece-title")
    render_click(element(home, "[phx-click='place_on_desk'][phx-value-id='#{piece.id}']"))
    assert has_element?(home, "#desk-piece-title", "A Window at Dusk")

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
             "The lamp comes on\nbefore anyone arrives."

    {:ok, changed} =
      Poems.save(location, piece, %{
        title: "A Window at Dusk",
        body: "The lamp comes on\nafter the house is quiet."
      })

    assert changed.body == "The lamp comes on\nafter the house is quiet."
    assert {:ok, still_sent} = Correspondence.packet(location, packet.id)

    assert still_sent.snapshot.pieces |> hd() |> Map.fetch!(:body) ==
             "The lamp comes on\nbefore anyone arrives."

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
  end

  test "an empty collection has a gentle first step and no invented activity", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/correspondence")

    assert has_element?(view, ".editorial-desk-empty", "Choose a work to keep in view.")

    assert has_element?(
             view,
             ".editorial-desk-empty a[href='/correspondence/writing']",
             "Browse Works"
           )

    assert has_element?(view, "a[href='/correspondence/journals/new']", "Add a place")
    refute has_element?(view, ".corr-journey")
  end
end
