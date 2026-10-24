defmodule StillWeb.CorrespondenceHomeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StillWeb.CorrespondenceHome

  test "empty overview invites choosing a saved work and places" do
    html = render_home(%{pieces: [], journals: [], packets: []}, %{})

    assert html =~ ~s(id="correspondence-home")
    assert html =~ ~s(id="on-the-desk")
    assert html =~ ~s(id="out-in-world")
    assert html =~ ~s(id="recent-replies")
    assert html =~ ~s(id="places-to-consider")
    assert html =~ "On the desk"
    assert html =~ "Choose a work to keep in view."
    assert html =~ ~s(href="/correspondence/writing")
    assert html =~ "Nothing is awaiting a reply just now."
    assert html =~ "Places to consider"
    assert html =~ ~s(href="/correspondence/journals/new")
    assert html =~ "Keep a publication’s details and your own notes together here."
    assert html =~ "Add a place"
  end

  test "saved unshortlisted places invite browsing the directory" do
    journal = place("Saved place", false, false, "", "unknown")
    html = render_home(%{pieces: [], journals: [journal], packets: []}, %{})
    assert html =~ "No places are shortlisted yet."
    assert html =~ "Browse Places"
    refute html =~ "Add a place</a>"
  end

  test "a desk selection shows current text and direct history and packet actions" do
    piece_id = "a3af90c1-712a-4a08-a246-e24dd094ae1c"
    body = Enum.map_join(1..9, "\n", &"Line #{&1}")
    piece = piece("Desk poem", body, piece_id)
    html = render_home(%{pieces: [piece], journals: [], packets: []}, %{piece_id: piece_id})

    assert html =~ ~s(<h2 id="desk-piece-title">)
    assert html =~ "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8"
    assert html =~ "More in the saved work."
    refute html =~ "Line 9"
    assert html =~ ~s(href="/correspondence/writing/#{piece_id}")
    assert html =~ ~s(href="/correspondence/packets/new?piece=#{piece_id}")
    assert html =~ ~s(phx-click="clear_desk")
    assert html =~ "Change the work on the desk"
  end

  test "chooser switches among Works and reports a missing selected piece" do
    first = piece("First", "First words", "a3af90c1-712a-4a08-a246-e24dd094ae1c")
    second = piece("Second", "Second words", "48fd08dd-600c-45f1-bc57-958cf0b82c5b")

    chooser =
      render_home(%{pieces: [first, second], journals: [], packets: []}, %{piece_id: first.id})

    assert chooser =~ ~s(phx-click="place_on_desk" phx-value-id="#{second.id}")
    assert chooser =~ "Place on desk"
    assert chooser =~ "Browse all Works"

    missing = render_home(%{pieces: [], journals: [], packets: []}, %{piece_id: first.id})
    assert missing =~ "no longer in the current Works collection"
    assert missing =~ ~s(phx-click="clear_desk")
    assert missing =~ "Choose a saved work"
  end

  test "active submissions include unresolved partial acceptances and cap at three" do
    journal_id = "91e0cc18-87bb-4ac0-9356-791901bd03f0"
    piece_id = "a3af90c1-712a-4a08-a246-e24dd094ae1c"

    packets = [
      packet("Active one", "submitted", "2026-10-05", [piece_id], journal_id),
      packet("Active two", "awaiting", "2026-10-04", [piece_id], journal_id),
      packet(
        "Partial acceptance",
        "accepted",
        "2026-10-03",
        [piece_id, "other-piece"],
        journal_id,
        [piece_id]
      ),
      packet("Active four", "submitted", "2026-10-02", [piece_id], journal_id),
      packet("Fully accepted", "accepted", "2026-10-01", [piece_id], journal_id, [piece_id]),
      packet("Declined history", "declined", "2026-09-30", [piece_id], journal_id)
    ]

    journal = %{id: journal_id, name: "North Window", shortlisted: false}
    piece = piece("Thaw", "A saved line.", piece_id)
    html = render_home(%{pieces: [piece], journals: [journal], packets: packets}, %{})
    [_full, active] = Regex.run(~r/id="out-in-world"(?s)(.*?)id="recent-replies"/, html)

    assert length(Regex.scan(~r/class="editorial-active-packet"/, active)) == 3
    assert active =~ "Active one"
    assert active =~ "Active two"
    assert active =~ "Partial acceptance"
    assert active =~ "Partly accepted · awaiting reply"
    refute active =~ "Active four"
    refute active =~ "Fully accepted"
    refute active =~ "Declined history"
    assert html =~ ~s(href="/correspondence/journals/#{journal_id}")
    assert html =~ ~s(href="/correspondence/packets/)
    assert html =~ ~s(href="/correspondence/writing/#{piece_id}")
  end

  test "recent replies are separate, compact, and capped at two" do
    packets = [
      reply_packet("Reply one", "declined", "2026-10-03", "A brief note."),
      reply_packet("Reply two", "accepted", "2026-10-02", "A yes."),
      reply_packet("Reply three", "withdrawn", "2026-10-01", "Withdrawn note."),
      packet("No reply event", "awaiting", "2026-09-30", [], nil)
    ]

    html = render_home(%{pieces: [], journals: [], packets: packets}, %{})
    [_full, replies] = Regex.run(~r/(<section id="recent-replies".*?<\/section>)/s, html)

    assert length(Regex.scan(~r/class="editorial-reply-row"/, replies)) == 2
    assert replies =~ "Reply one"
    assert replies =~ "Reply two"
    refute replies =~ "Reply three"
    refute replies =~ "No reply event"
    assert replies =~ "Declined"
    assert replies =~ "Accepted"
  end

  test "places shelf shows only a few shortlisted places and verified saved facts" do
    journals = [
      place("Verified place", true, true, "Spring", "allowed"),
      place("Unverified place", true, false, "Autumn", "not_allowed"),
      place("Third place", true, false, "", "unknown"),
      place("Fourth place", true, false, "", "unknown"),
      place("Not shortlisted", false, true, "Winter", "allowed")
    ]

    journal_id = journals |> hd() |> Map.fetch!(:id)
    history = packet("Prior packet", "declined", "2026-10-01", [], journal_id)

    html = render_home(%{pieces: [], journals: journals, packets: [history]}, %{})
    [_full, places] = Regex.run(~r/id="places-to-consider"(?s)(.*)$/, html)

    assert length(Regex.scan(~r/class="editorial-home-place"/, places)) == 3
    assert places =~ "Verified place"
    assert places =~ "Personal note"
    assert places =~ "Lyric work"
    assert places =~ "Details marked checked by you"
    assert places =~ "Window: Spring"
    assert places =~ "Simultaneous submissions: Allowed"
    assert places =~ "Prior packet"
    assert places =~ "Unverified place"
    refute places =~ "Autumn"
    refute places =~ "Not allowed"
    refute places =~ "Fourth place"
    refute places =~ "Not shortlisted"
    assert places =~ ~s(phx-click="toggle_shortlist" phx-value-id="#{journal_id}")
    assert places =~ ~s(href="/correspondence/journals/#{journal_id}")
  end

  test "long home notes are clipped for display without changing their saved values" do
    long_text = String.duplicate("A saved detail. ", 18)

    journal = %{
      id: Ecto.UUID.generate(),
      name: "Long notes journal",
      shortlisted: true,
      verified: false,
      interests: long_text,
      notes: long_text,
      windows: "",
      simultaneous_policy: "unknown"
    }

    response = reply_packet("Timestamped reply", "declined", "2026-10-03T14:32:00Z", long_text)
    html = render_home(%{pieces: [], journals: [journal], packets: [response]}, %{})

    assert html =~ String.slice(long_text, 0, 179) <> "…"
    assert html =~ String.slice(long_text, 0, 159) <> "…"
    refute html =~ long_text
    assert journal.interests == long_text
    assert journal.notes == long_text
    assert response.events |> hd() |> Map.fetch!(:note) == long_text
    assert html =~ "3 Oct 2026"
    refute html =~ "2026-10-03T14:32:00Z"
  end

  defp render_home(overview, desk) do
    render_component(&CorrespondenceHome.home/1, %{overview: overview, desk: desk})
  end

  defp piece(title, body, id) do
    %{id: id, title: title, title_source: "explicit", body: body, updated_at: "2026-10-20"}
  end

  defp packet(title, status, updated_at, piece_ids, journal_id, accepted_piece_ids \\ []) do
    %{
      id: Ecto.UUID.generate(),
      title: title,
      status: status,
      updated_at: updated_at,
      journal_id: journal_id,
      piece_ids: piece_ids,
      accepted_piece_ids: accepted_piece_ids,
      events: [],
      snapshot: %{date: updated_at}
    }
  end

  defp reply_packet(title, status, date, note) do
    packet = packet(title, status, date, [], nil)
    %{packet | events: [%{kind: "response", status: status, date: date, note: note}]}
  end

  defp place(name, shortlisted, verified, windows, policy) do
    %{
      id: Ecto.UUID.generate(),
      name: name,
      shortlisted: shortlisted,
      verified: verified,
      interests: if(name == "Verified place", do: "Lyric work", else: ""),
      notes: if(name == "Verified place", do: "Personal note", else: ""),
      windows: windows,
      simultaneous_policy: policy
    }
  end
end
