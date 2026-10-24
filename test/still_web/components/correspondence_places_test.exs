defmodule StillWeb.CorrespondencePlacesTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StillWeb.CorrespondencePlaces

  test "directory invites a first place and keeps source-check status manual" do
    empty = render_component(&CorrespondencePlaces.directory/1, %{journals: []})
    assert empty =~ ~s(id="places-directory")
    assert empty =~ ~s(href="/correspondence/journals/new")
    assert empty =~ "Add a place"
    assert empty =~ ~s(<h1 id="places-heading">Places</h1>)
    assert empty =~ ~s(<h2 id="all-places-heading">Active places</h2>)
    refute empty =~ "editorial-place-count"
    refute empty =~ "A PERSONAL DIRECTORY"
    refute empty =~ "Places to send work."
    refute empty =~ "Publication details, your own notes"

    html =
      render_component(&CorrespondencePlaces.directory/1, %{
        journals: [
          journal("Checked by writer", %{verified: true}),
          journal("Not checked", %{verified: false})
        ]
      })

    assert html =~ "Checked by writer"
    assert html =~ "You marked source checked"
    assert html =~ "Personal record"
    assert html =~ "Shortlisted"
    assert length(Regex.scan(~r/class="editorial-place-shortcuts"/, html)) == 1
    assert length(Regex.scan(~r/class="editorial-place-card"/, html)) == 2
    refute html =~ "class=\"editorial-place-card is-shortlisted"
    refute html =~ "Not recorded."
    assert html =~ "Simultaneous: Unknown"
  end

  test "profile states unknown details and links packets to their pieces" do
    journal_id = "5d1f70af-1951-42a7-b2ce-8bf0c76585ea"
    packet_id = "7a13a75e-49e6-45ea-8e62-7907823c4669"
    first_id = "a3af90c1-712a-4a08-a246-e24dd094ae1c"
    second_id = "48fd08dd-600c-45f1-bc57-958cf0b82c5b"

    html =
      render_component(&CorrespondencePlaces.details/1, %{
        journal: journal("North Window", %{id: journal_id, verified: true}),
        packets: [
          %{
            id: packet_id,
            title: "Spring poems",
            status: "accepted",
            piece_ids: [first_id, second_id],
            accepted_piece_ids: [first_id],
            updated_at: "2026-10-01"
          }
        ],
        pieces: [
          %{id: first_id, title: "Blue Hour", body: "First body"},
          %{id: second_id, title: "The Field", body: "Second body"}
        ],
        form: journal("North Window", %{id: journal_id, verified: true})
      })

    assert html =~ "Unknown"
    assert html =~ "Marked checked by you"
    assert html =~ "Partly accepted · awaiting"
    assert html =~ ~s(<h1 id="place-title">North Window</h1>)
    refute html =~ "MARKED CHECKED BY YOU"
    refute html =~ "editorial-place-profile-lede"
    assert html =~ ~s(class="corr-history editorial-place-correspondence")
    assert html =~ ~s(href="/correspondence/packets/#{packet_id}")
    assert html =~ ~s(href="/correspondence/packets/new?journal=#{journal_id}")
    assert html =~ ~s(href="/correspondence/writing/#{first_id}")
    assert html =~ ~s(href="/correspondence/writing/#{second_id}")
    refute html =~ "href=\"javascript:"
  end

  test "only HTTP and HTTPS publication URLs become external links" do
    safe_html =
      render_component(&CorrespondencePlaces.details/1, %{
        journal:
          journal("Alder Journal", %{
            website: "https://alder.example/journal",
            submission_url: "http://alder.example/submit"
          }),
        packets: [],
        pieces: [],
        form: journal("Alder Journal", %{})
      })

    assert safe_html =~ ~s(href="https://alder.example/journal")
    assert safe_html =~ ~s(href="http://alder.example/submit")
    assert safe_html =~ ~s(target="_blank" rel="noopener noreferrer")

    unsafe_html =
      render_component(&CorrespondencePlaces.details/1, %{
        journal:
          journal("Unsafe example", %{
            website: "javascript:alert(1)",
            submission_url: "data:text/html,unsafe"
          }),
        packets: [],
        pieces: [],
        form: journal("Unsafe example", %{})
      })

    refute unsafe_html =~ ~s(href="javascript:)
    refute unsafe_html =~ ~s(href="data:)
    assert unsafe_html =~ "Not recorded"
  end

  test "new place editor groups the manual fields and preserves LiveView form hooks" do
    html =
      render_component(&CorrespondencePlaces.editor/1, %{
        journal: nil,
        form: journal("", %{})
      })

    assert html =~ ~s(id="journal-form")
    assert html =~ ~s(phx-submit="save_journal")
    assert html =~ ~s(phx-change="validate_journal")
    assert html =~ ~r/<h1 id="place-editor-title">\s*Add a place\s*<\/h1>/
    refute html =~ "A DESTINATION TO REMEMBER"
    refute html =~ "Empty details stay marked as unknown"
    assert length(Regex.scan(~r/class="editorial-place-form-section"/, html)) == 3

    for field <-
          ~w(name website submission_url interests guidelines windows fee simultaneous_policy response_expectation notes verified shortlisted) do
      assert html =~ "journal[#{field}]"
    end

    assert html =~ "Unknown"
    assert html =~ "I checked these details at the publication’s own source"
    assert html =~ "Keep this place on my shortlist"
  end

  defp journal(name, overrides) do
    Map.merge(
      %{
        id: "91e0cc18-87bb-4ac0-9356-791901bd03f0",
        name: name,
        website: "",
        submission_url: "",
        interests: "",
        guidelines: "",
        windows: "",
        fee: "",
        simultaneous_policy: "unknown",
        response_expectation: "",
        notes: "",
        shortlisted: true,
        verified: false
      },
      overrides
    )
  end
end
