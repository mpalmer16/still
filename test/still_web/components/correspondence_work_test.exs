defmodule StillWeb.CorrespondenceWorkTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StillWeb.CorrespondenceWork

  test "keeps current words distinct from exact submitted words and shows correspondence" do
    piece_id = "a3af90c1-712a-4a08-a246-e24dd094ae1c"
    packet_id = "48fd08dd-600c-45f1-bc57-958cf0b82c5b"
    journal_id = "84af1c03-b274-4c9f-a6aa-8914f37f0a87"
    current = "The revised line stays exactly here.\nA second line."
    sent = "The original submitted line stays exactly here.\nA second line."

    html =
      render_component(&CorrespondenceWork.detail/1, %{
        piece: %{id: piece_id, title: "Blue Hour", body: current, updated_at: "2026-10-18"},
        revisions: [
          %{title: "Blue Hour", body: "An earlier exact revision.", updated_at: "2026-09-01"}
        ],
        history: [
          %{
            packet: %{
              id: packet_id,
              title: "Autumn packet",
              status: "accepted",
              journal_name: "Moss Review",
              events: [
                %{kind: "submitted", date: "2026-08-20", status: nil},
                %{
                  kind: "response",
                  date: "2026-09-03",
                  status: "accepted",
                  note: "We would be glad to publish this piece.",
                  accepted_piece_ids: [piece_id]
                }
              ],
              snapshot: %{date: "2026-08-20", packet_title: "Autumn packet"}
            },
            journal: %{id: journal_id, name: "Moss Review"},
            snapshot: %{body: sent}
          },
          %{
            packet: %{
              id: "1d40b46a-1901-4bfa-9685-31c33a3b5a6f",
              title: "A later packet",
              status: "declined",
              journal_name: "North Window",
              piece_ids: [piece_id],
              accepted_piece_ids: [piece_id],
              events: [
                %{
                  kind: "response",
                  date: "2026-10-10",
                  status: "declined",
                  note: "A later reply."
                }
              ],
              snapshot: %{date: "2026-09-20", packet_title: "A later packet"}
            },
            journal: nil,
            snapshot: %{body: "Words sent later."}
          },
          %{
            packet: %{
              id: "e9a20c35-3485-4e3c-9848-81a9807cb4ac",
              title: "A partial packet",
              status: "accepted",
              journal_name: "Harbor Light",
              piece_ids: [piece_id, "another-piece"],
              accepted_piece_ids: ["another-piece"],
              events: [
                %{
                  kind: "response",
                  date: "2026-10-16",
                  status: "accepted",
                  note: "One piece accepted.",
                  accepted_piece_ids: ["another-piece"]
                }
              ],
              snapshot: %{date: "2026-10-01", packet_title: "A partial packet"}
            },
            journal: nil,
            snapshot: %{body: "The selected work is still in consideration."}
          }
        ]
      })

    assert html =~ "class=\"corr-manuscript editorial-work-manuscript\""
    assert html =~ "id=\"work-history\""
    assert html =~ "Current revision · revised 18 Oct 2026"
    refute html =~ "A PIECE WITH A LIFE OF ITS OWN"
    assert html =~ current
    assert html =~ sent
    assert html =~ "We would be glad to publish this piece."
    assert html =~ "This piece was accepted."
    assert html =~ "Still under consideration"
    assert html =~ "A later reply."

    assert Regex.match?(
             ~r/id="piece-history-1d40b46a-1901-4bfa-9685-31c33a3b5a6f".*?status-accepted">\s*Accepted/s,
             html
           )

    assert Regex.match?(
             ~r/id="piece-history-e9a20c35-3485-4e3c-9848-81a9807cb4ac".*?status-considering">\s*Still under consideration/s,
             html
           )

    assert html =~ "/writing/#{piece_id}/edit"
    assert html =~ "/correspondence/packets/new?piece=#{piece_id}"
    assert html =~ "/correspondence/journals/#{journal_id}"
    assert html =~ "/correspondence/packets/#{packet_id}"
    assert html =~ "Read the exact version sent"
    assert html =~ "Earlier versions"
  end

  test "renders no section for a missing piece" do
    assert render_component(&CorrespondenceWork.detail/1, %{piece: nil}) == ""
  end
end
