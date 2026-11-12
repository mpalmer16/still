defmodule Still.Correspondence.PlaceDirectoryTest do
  use ExUnit.Case, async: true

  alias Still.Correspondence.PlaceDirectory

  test "filters text, status, reach and history together without changing source maps" do
    place = %{
      id: "b",
      name: "Élan Review",
      description: "Literary journal",
      notes: "quiet window",
      reach: "stretch"
    }

    inactive = %{
      id: "a",
      name: "Élan Review",
      inactive: true,
      reach: "stretch",
      notes: "quiet window"
    }

    packets = [
      %{
        id: "p",
        journal_id: "b",
        status: "awaiting",
        snapshot_ref: "snap",
        events: [%{kind: "submitted", date: "2025-01-02"}],
        piece_ids: ["x"]
      }
    ]

    result =
      PlaceDirectory.browse([inactive, place], packets, %{
        "q" => "quiet",
        "history" => "awaiting",
        "reach" => "stretch"
      })

    assert result.total == 2
    assert result.matched == 1
    assert hd(result.rows).journal === place
    assert hd(result.rows).packet_count == 1
    assert hd(result.rows).awaiting_count == 1
    assert hd(result.rows).last_sent_at == "2025-01-02"
    assert place.name == "Élan Review"
  end

  test "clamps pages, tolerates malformed parameters and keeps missing last sent dates last" do
    journals = [%{id: "a", name: "Same"}, %{id: "b", name: "Same"}, %{id: "c", name: "Zed"}]

    packets = [
      %{
        id: "p",
        journal_id: "c",
        status: "submitted",
        snapshot_ref: "s",
        events: [%{kind: "submitted", date: "2024-01-02"}]
      }
    ]

    result =
      PlaceDirectory.browse(journals, packets, %{
        sort: "last_sent",
        direction: "desc",
        page: "900",
        status: "bogus"
      })

    assert result.filters["status"] == "active"
    assert result.filters["page"] == 1
    assert result.shown == 3
    assert Enum.map(result.rows, & &1.journal.id) == ["c", "a", "b"]
    assert result.more? == false
  end

  test "counts only submitted snapshots as sent and sorts explicit dates without timestamps" do
    journals = [%{id: "1", name: "One"}, %{id: "2", name: "Two"}]

    packets = [
      %{id: "draft", journal_id: "1", status: "preparing", snapshot_ref: nil},
      %{
        id: "sent",
        journal_id: "2",
        status: "declined",
        snapshot_ref: "s",
        updated_at: "2099-01-01",
        events: [%{kind: "submitted", date: "2020-04-05"}]
      }
    ]

    result = PlaceDirectory.browse(journals, packets, %{history: "never_sent", sort: "last_sent"})
    assert Enum.map(result.rows, & &1.journal.id) == ["1"]
    assert hd(result.rows).packet_count == 1
    all = PlaceDirectory.browse(journals, packets, %{sort: "last_sent"})
    assert Enum.map(all.rows, & &1.journal.id) == ["2", "1"]
    assert hd(all.rows).last_sent_at == "2020-04-05"
  end

  test "uses persisted shortlist and exact simultaneous policies" do
    journals = [
      %{id: "near", name: "Near", shortlisted: true, simultaneous_policy: "allowed"},
      %{id: "no", name: "No", shortlisted: false, simultaneous_policy: "not_allowed"},
      %{id: "unknown", name: "Unknown", shortlisted: false, simultaneous_policy: nil}
    ]

    assert ids(journals, %{nearby: "nearby", simultaneous: "allowed"}) == ["near"]
    assert ids(journals, %{nearby: "not_nearby", simultaneous: "not_allowed"}) == ["no"]
    assert ids(journals, %{simultaneous: "unknown"}) == ["unknown"]
  end

  test "search is literal and ANDs normalized terms across fields; missing reach is unknown" do
    journals = [
      %{id: "hit", name: "Cafe\u0301", notes: "(quiet) window", reach: nil},
      %{id: "miss", name: "Cafe", notes: "quiet window", reach: "stretch"}
    ]

    assert ids(journals, %{q: "CAFÉ (quiet)", reach: "unknown"}) == ["hit"]
    assert ids(journals, %{q: "[", reach: "unknown"}) == []
  end

  test "paginates a large directory and clamps pages to its final page" do
    journals =
      for n <- 1..85, do: %{id: "#{n}", name: "Place #{String.pad_leading(to_string(n), 3, "0")}"}

    first = PlaceDirectory.browse(journals, [], %{page: 1})
    third = PlaceDirectory.browse(journals, [], %{page: 3})
    beyond = PlaceDirectory.browse(journals, [], %{page: 9})

    assert {first.shown, first.pages, first.more?} == {40, 3, true}
    assert {third.shown, third.page, third.more?} == {5, 3, false}
    assert Enum.map(third.rows, & &1.journal.id) == Enum.map(beyond.rows, & &1.journal.id)
    assert beyond.filters["page"] == 3
  end

  test "partial acceptance remains awaiting while only submitted event dates define last sent" do
    journal = %{id: "j", name: "Place"}

    packets = [
      %{
        id: "partial",
        journal_id: "j",
        status: "accepted",
        snapshot_ref: "s",
        piece_ids: ["a", "b"],
        accepted_piece_ids: ["a"],
        updated_at: "2099-01-01",
        events: [%{kind: "status", date: "2024-01-01"}]
      },
      %{
        id: "sent",
        journal_id: "j",
        status: "declined",
        snapshot_ref: "s2",
        piece_ids: ["a"],
        events: [%{kind: "submitted", date: "2022-03-04"}]
      }
    ]

    result = PlaceDirectory.browse([journal], packets, %{history: "awaiting"})
    assert result.matched == 1
    assert hd(result.rows).awaiting_count == 1
    assert hd(result.rows).sent_count == 2
    assert hd(result.rows).last_sent_at == "2022-03-04"
  end

  defp ids(journals, params),
    do: PlaceDirectory.browse(journals, [], params).rows |> Enum.map(& &1.journal.id)
end
