defmodule Still.Correspondence.WorkDirectoryTest do
  use ExUnit.Case, async: true
  alias Still.Correspondence.WorkDirectory

  test "searches work metadata and exact text, derives packet involvement, and leaves input alone" do
    piece = %{
      id: "w",
      title: "Blue Door",
      body: "A quiet window",
      notebook: "Book 4",
      list_label: "List 8"
    }

    packets = [
      %{
        id: "p",
        piece_ids: ["w"],
        status: "awaiting",
        title: "First send",
        updated_at: "2026-01-02"
      }
    ]

    result = WorkDirectory.browse([piece], packets, %{q: "quiet Book", status: "awaiting"})
    assert result.matched == 1
    assert hd(result.rows).title == "Blue Door"
    assert hd(result.rows).packet_count == 1
    assert hd(result.rows).latest_packet.id == "p"
    assert piece.body == "A quiet window"
  end

  test "supports ready filtering, stable title order, and bounded paging" do
    pieces =
      for n <- 1..45,
          do: %{id: "#{n}", title: "Work #{String.pad_leading("#{n}", 2, "0")}", body: ""}

    first = WorkDirectory.browse(pieces, [], %{status: "ready", sort: "title"})
    next = WorkDirectory.browse(pieces, [], %{status: "ready", sort: "title", page: 2})
    assert {first.shown, first.pages, first.more?} == {40, 2, true}
    assert {next.shown, next.page, next.more?} == {5, 2, false}
    assert hd(first.rows).title == "Work 01"
  end

  test "summarizes simultaneous packet states without hiding accepted or other involvement" do
    piece = %{id: "w", title: "Blue Door", body: ""}

    packets = [
      %{id: "accepted", piece_ids: ["w", "x"], accepted_piece_ids: ["w"], status: "accepted"},
      %{id: "later-decline", piece_ids: ["w"], status: "declined"}
    ]

    [row] = WorkDirectory.browse([piece], packets).rows
    assert row.status == "accepted"
    assert row.status_counts == %{"accepted" => 1, "declined" => 1}
    assert WorkDirectory.browse([piece], packets, %{status: "declined"}).matched == 1
    assert WorkDirectory.browse([piece], packets, %{status: "ready"}).matched == 0
  end

  test "a not-yet-accepted member of a partially accepted packet remains awaiting" do
    pieces = [%{id: "kept", title: "Accepted"}, %{id: "waiting", title: "Still waiting"}]

    packet = %{
      id: "p",
      piece_ids: ["kept", "waiting"],
      accepted_piece_ids: ["kept"],
      status: "accepted"
    }

    rows = WorkDirectory.browse(pieces, [packet], %{status: "awaiting"}).rows
    assert Enum.map(rows, & &1.piece.id) == ["waiting"]
    assert hd(rows).status == "awaiting"
  end
end
