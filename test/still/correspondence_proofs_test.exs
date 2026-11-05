defmodule Still.Correspondence.ProofsTest do
  use ExUnit.Case, async: true

  alias Still.Correspondence.Proofs

  test "sources sent snapshots first, sorted within each kind, using the frozen destination" do
    piece = %{id: "piece-1", title: "Current title", body: "current"}

    sent_old =
      sent_row("packet-old", "piece-1", "2026-01-02", "Journal before rename", "sent old")

    sent_between =
      sent_row(
        "packet-between",
        "piece-1",
        "2026-01-03T00:00:00Z",
        "Journal before rename",
        "sent between"
      )

    sent_new =
      sent_row("packet-new", "piece-1", "2026-02-03", "Journal before rename", "sent new")

    other_piece =
      sent_row("packet-other", "not-this-piece", "2026-03-04", "Other journal", "other")

    preparing = %{
      packet: %{id: "packet-preparing", status: "preparing", snapshot_ref: nil},
      snapshot: %{id: "piece-1", title: "Never sent", body: "preparation"}
    }

    revisions = [
      revision("revision-old", "piece-1", "2026-01-04T10:00:00Z", "saved old"),
      revision("revision-new", "piece-1", "2026-02-04T10:00:00Z", "saved new"),
      revision("revision-other", "another-piece", "2026-03-04T10:00:00Z", "other"),
      %{id: "revision-missing-body", piece_id: "piece-1", created_at: "2026-01-01T00:00:00Z"}
    ]

    history = [sent_old, other_piece, preparing, sent_between, sent_new]
    sources = Proofs.sources(piece, revisions, history)

    assert Enum.map(sources, & &1.key) == [
             "sent:packet-new",
             "sent:packet-between",
             "sent:packet-old",
             "saved:revision-new",
             "saved:revision-old"
           ]

    assert Enum.map(sources, & &1.kind) == [:sent, :sent, :sent, :saved, :saved]
    assert hd(sources).label == "Sent to Journal before rename"
    assert hd(sources).packet_id == "packet-new"
    assert Enum.at(sources, 3).title == "saved new"
    assert Enum.all?(sources, &(&1.body != "other" and &1.body != "preparation"))
  end

  test "sources ignore malformed and wrong-piece snapshots and revisions" do
    piece = %{id: "piece-1", title: nil, body: "now"}
    wrong_snapshot_id = sent_row("wrong-piece", "piece-2", "2026-01-01", "Frozen", "wrong")

    wrong_packet_reference =
      sent_row("wrong-reference", "piece-1", "2026-01-01", "Frozen", "wrong")

    wrong_packet_reference = %{
      wrong_packet_reference
      | packet: %{wrong_packet_reference.packet | snapshot_ref: "another-snapshot"}
    }

    malformed = %{
      packet: %{id: "no-snapshot", status: "submitted", snapshot_ref: "x"},
      snapshot: %{id: "piece-1", body: "missing title"}
    }

    sources =
      Proofs.sources(
        piece,
        [
          revision("belongs-elsewhere", "piece-2", "2026-01-02T00:00:00Z", "not this page"),
          %{id: "", body: "no identity", created_at: "2026-01-02T00:00:00Z"}
        ],
        [wrong_snapshot_id, wrong_packet_reference, malformed]
      )

    assert sources == []
  end

  test "a saved revision title falls back to its original first line" do
    piece = %{id: "piece-1", title: nil, body: "changed"}

    [source] =
      Proofs.sources(
        piece,
        [
          %{
            id: "revision-1",
            piece_id: "piece-1",
            title: nil,
            body: "  First line\nsecond",
            created_at: "2026-01-01T00:00:00Z"
          }
        ],
        []
      )

    assert source.title == "First line"
    assert source.date == "2026-01-01T00:00:00Z"
  end

  test "database revision ids and owning entry ids are accepted for file-backed writing" do
    [source] =
      Proofs.sources(
        %{id: "piece-1", entry_id: 27, title: "Current", body: "now"},
        [
          %{
            id: 41,
            entry_id: 27,
            title: "Earlier",
            body: "earlier full text",
            created_at: "2026-01-01T00:00:00Z"
          }
        ],
        []
      )

    assert source.key == "saved:41"
    assert source.body == "earlier full text"
    assert source.title == "Earlier"
  end

  test "line diff preserves exact authored bytes on both sides" do
    original = "Alpha\r\n  tab\t  \r\n\r\ncafé <script>literal</script>\r"
    current = "Alpha\r\n  tab\tchanged\r\ninserted\n\r\ncafé <script>literal</script>\r"

    result =
      Proofs.compare(%{title: "Old title", body: original}, %{title: "New title", body: current})

    assert IO.iodata_to_binary(Enum.map(result.earlier, & &1.text)) == original
    assert IO.iodata_to_binary(Enum.map(result.current, & &1.text)) == current
    assert Enum.any?(result.earlier, &(&1.kind == :removed))
    assert Enum.any?(result.current, &(&1.kind == :added))
    assert result.current_title == "New title"
    refute result.body_same?
    refute result.title_same?
    refute result.spacing_only?
    refute result.line_endings_only?
    assert result.detailed?
    assert Enum.any?(result.earlier, &String.contains?(&1.text, "café <script>literal</script>"))
  end

  test "line-ending-only and spacing-only changes are described without normalizing text" do
    line_endings =
      Proofs.compare(
        %{title: "Same", body: "one\r\ntwo\r"},
        %{title: "Same", body: "one\ntwo\n"}
      )

    assert line_endings.line_endings_only?
    refute line_endings.spacing_only?
    assert IO.iodata_to_binary(Enum.map(line_endings.earlier, & &1.text)) == "one\r\ntwo\r"

    spacing =
      Proofs.compare(
        %{title: "Same", body: "one  two\n"},
        %{title: "Same", body: "one\ttwo\n"}
      )

    assert spacing.spacing_only?
    refute spacing.line_endings_only?
    assert IO.iodata_to_binary(Enum.map(spacing.current, & &1.text)) == "one\ttwo\n"
  end

  test "identical, title-only, and empty comparisons stay exact" do
    body = "  <b>Words</b>\r\n\twith space  "
    same = Proofs.compare(%{title: "Before", body: body}, %{title: "Before", body: body})
    assert same.body_same? and same.title_same?
    assert IO.iodata_to_binary(Enum.map(same.earlier, & &1.text)) == body
    assert IO.iodata_to_binary(Enum.map(same.current, & &1.text)) == body

    title_only = Proofs.compare(%{title: "Before", body: body}, %{title: "After", body: body})
    assert title_only.body_same?
    refute title_only.title_same?

    empty = Proofs.compare(%{title: "Untitled", body: ""}, %{title: "Untitled", body: ""})
    assert empty.body_same?
    assert empty.earlier == []
    assert empty.current == []
    assert empty.detailed?
  end

  test "oversized all-unique documents use complete bounded fallback segments" do
    original = for index <- 1..601, into: "", do: "old-#{index}\n"
    current = for index <- 1..601, into: "", do: "new-#{index}\n"
    result = Proofs.compare(%{title: "Earlier", body: original}, %{title: "Now", body: current})

    refute result.detailed?
    assert result.earlier == [%{kind: :removed, text: original}]
    assert result.current == [%{kind: :added, text: current}]
    assert IO.iodata_to_binary(Enum.map(result.earlier, & &1.text)) == original
    assert IO.iodata_to_binary(Enum.map(result.current, & &1.text)) == current
  end

  defp sent_row(packet_id, piece_id, date, journal_name, body) do
    snapshot_id = "snapshot-#{packet_id}"

    %{
      packet: %{
        id: packet_id,
        status: "submitted",
        snapshot_ref: snapshot_id,
        snapshot: %{
          id: snapshot_id,
          packet_id: packet_id,
          date: date,
          journal_name: journal_name
        }
      },
      journal: %{name: "Current renamed journal"},
      snapshot: %{id: piece_id, title: "Frozen title", body: body}
    }
  end

  defp revision(id, piece_id, date, body),
    do: %{id: id, piece_id: piece_id, title: nil, body: body, created_at: date}
end
