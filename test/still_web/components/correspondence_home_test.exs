defmodule StillWeb.CorrespondenceHomeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StillWeb.CorrespondenceHome

  test "empty dashboard gives collection access and a clear start" do
    html = render_home(%{pieces: [], journals: [], packets: []})

    assert html =~ ~s(id="correspondence-home")
    assert html =~ "Home"
    assert html =~ "Preparing"
    assert html =~ "Awaiting replies"
    assert html =~ "Recent responses"
    assert html =~ "No packets are being prepared."
    assert html =~ "Nothing is awaiting a reply just now."
    assert html =~ "Recorded responses will appear here."
    assert html =~ ~s(href="/correspondence/packets/new")
    assert length(Regex.scan(~r/<strong[^>]*>0<\/strong>/, html)) == 3
    assert html =~ "Works"
    assert html =~ "Places"
    assert html =~ "Packets"
    refute html =~ "On the desk"
    refute html =~ "editorial-desk"
  end

  test "preparing packets are visible with or without a destination" do
    piece = piece("Thaw", "Saved words", "piece-1")
    with_place = packet("Spring packet", "preparing", [piece.id], "place-1", [])
    without_place = packet("Unplaced packet", "preparing", [], nil, [])

    html =
      render_home(%{
        pieces: [piece],
        journals: [%{id: "place-1", name: "North Window"}],
        packets: [with_place, without_place]
      })

    assert html =~ "Spring packet"
    assert html =~ "Unplaced packet"
    assert html =~ "North Window"
    assert html =~ "No destination chosen"
    assert html =~ "Thaw"
    assert html =~ ~s(href="/correspondence/packets/#{with_place.id}")
    refute html =~ "Mark ready"
  end

  test "awaiting entries show submitted date, place, packet, and included works" do
    piece = piece("Thaw", "Saved words", "piece-1")

    sent =
      packet("Spring packet", "awaiting", [piece.id], "place-1", [
        %{kind: "submitted", date: "2026-10-03"}
      ])

    html =
      render_home(%{
        pieces: [piece],
        journals: [%{id: "place-1", name: "North Window"}],
        packets: [sent]
      })

    assert html =~ "North Window"
    assert html =~ "Spring packet"
    assert html =~ "3 Oct 2026"
    assert html =~ "Thaw"
    assert html =~ ~s(href="/correspondence/writing/piece-1")
    assert html =~ ~s(href="/correspondence/packets/#{sent.id}")
  end

  test "recent responses are date ordered, compact, and open packet history" do
    packets = [
      packet("Earlier", "declined", [], "place-1", [
        %{kind: "response", status: "declined", date: "2026-10-01", note: "A short note."}
      ]),
      packet("Later", "accepted", [], "place-1", [
        %{kind: "response", status: "accepted", date: "2026-10-03", note: "A yes."}
      ])
    ]

    html =
      render_home(%{
        pieces: [],
        journals: [%{id: "place-1", name: "North Window"}],
        packets: packets
      })

    assert html =~ "Accepted"
    assert html =~ "Declined"
    assert html =~ "A short note."
    assert html =~ ~s(href="/correspondence/packets/#{Enum.at(packets, 1).id}")
    assert :binary.match(html, "Later") < :binary.match(html, "Earlier")
  end

  defp render_home(overview) do
    render_component(&CorrespondenceHome.home/1, %{overview: overview, desk: %{piece_id: nil}})
  end

  defp piece(title, body, id), do: %{id: id, title: title, title_source: "explicit", body: body}

  defp packet(title, status, piece_ids, journal_id, events) do
    %{
      id: Ecto.UUID.generate(),
      title: title,
      status: status,
      updated_at: "2026-10-20",
      journal_id: journal_id,
      piece_ids: piece_ids,
      accepted_piece_ids: [],
      events: events
    }
  end
end
