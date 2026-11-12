defmodule Still.Correspondence.PacketDirectoryTest do
  use ExUnit.Case, async: true
  alias Still.Correspondence.PacketDirectory

  test "joins packet destinations and ordered contents for combined filters" do
    packet = %{
      id: "p",
      title: "Submission",
      journal_id: "j",
      piece_ids: ["a", "b"],
      status: "submitted",
      events: [%{kind: "submitted", date: "2026-02-03"}]
    }

    result =
      PacketDirectory.browse(
        [packet],
        [%{id: "j", name: "Review"}],
        [%{id: "a", title: "First"}, %{id: "b", title: "Second"}],
        %{q: "second review", status: "submitted", destination: "chosen"}
      )

    row = hd(result.rows)
    assert row.destination_name == "Review"
    assert Enum.map(row.pieces, & &1.id) == ["a", "b"]
    assert row.piece_count == 2
    assert row.date == "2026-02-03"
  end

  test "labels missing destination and filters it without confusing packet status" do
    packets = [%{id: "p", title: "Draft", journal_id: nil, piece_ids: [], status: "preparing"}]

    result =
      PacketDirectory.browse(packets, [], [], %{destination: "unchosen", status: "preparing"})

    assert hd(result.rows).destination_name == "Not chosen"
    assert hd(result.rows).piece_count == 0
  end

  test "uses submitted destination and frozen work titles for archived packets" do
    packets = [
      %{
        id: "old",
        title: "Z packet",
        journal_id: "j",
        journal_name: "Original Review",
        piece_ids: ["w"],
        status: "declined",
        snapshot: %{pieces: [%{id: "w", title: "Sent title", body: "sent words"}]},
        events: [%{kind: "submitted", date: "2022-02-03"}],
        updated_at: "2026-01-01T00:00:00Z"
      },
      %{
        id: "new",
        title: "A packet",
        journal_id: "j",
        journal_name: "Original Review",
        piece_ids: [],
        status: "preparing",
        updated_at: "2026-02-01T00:00:00Z"
      }
    ]

    result =
      PacketDirectory.browse(
        packets,
        [%{id: "j", name: "Renamed Review"}],
        [%{id: "w", title: "Current title"}],
        %{q: "original sent title", sort: "sent_date", direction: "asc"}
      )

    [row] = result.rows
    assert row.destination_name == "Original Review"
    assert hd(row.pieces).title == "Sent title"
    assert row.date == "2022-02-03"
  end

  test "sorts packets by recent activity by default and by destination when asked" do
    packets = [
      %{id: "older", title: "B", journal_name: "Beta", updated_at: "2024-01-01"},
      %{id: "newer", title: "A", journal_name: "Alpha", updated_at: "2025-01-01"}
    ]

    [recent | _] = PacketDirectory.browse(packets, [], []).rows
    assert recent.packet.id == "newer"

    [dest_first | _] =
      PacketDirectory.browse(packets, [], [], %{sort: "destination", direction: "asc"}).rows

    assert dest_first.packet.id == "newer"
  end
end
