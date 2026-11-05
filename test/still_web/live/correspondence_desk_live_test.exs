defmodule StillWeb.CorrespondenceDeskLiveTest do
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

    on_exit(fn ->
      if previous,
        do: Application.put_env(:still, :storage_state_directory, previous),
        else: Application.delete_env(:still, :storage_state_directory)
    end)

    %{location: Storage.collection_location(), collection: collection}
  end

  test "placing, changing, and clearing a work persists across home mounts without changing writing or submissions",
       %{
         conn: conn,
         location: location
       } do
    first = save_piece(location, "First desk piece", "First exact manuscript words.\n")
    second = save_piece(location, "Second desk piece", "Second exact manuscript words.\n")
    assert :ok = Correspondence.set_focus(location, second.id, true)
    journal = save_journal(location, "Desk Review")
    packet = prepare_packet(location, journal, [first])
    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-23")
    source_before = File.read!(first.path)
    packet_before = Correspondence.packet(location, sent.id)

    {:ok, works, _} = live(conn, "/correspondence/writing")
    render_click(element(works, "[phx-click='place_on_desk'][phx-value-id='#{first.id}']"))

    assert {:ok, first_desk} = Correspondence.desk(location)
    assert first_desk.piece_id == first.id
    assert is_binary(first_desk.token)
    assert File.read!(first.path) == source_before
    assert Correspondence.packet(location, sent.id) == packet_before

    {:ok, home, _} = live(conn, "/correspondence")
    assert has_element?(home, "#on-the-desk", "First desk piece")
    assert has_element?(home, "#on-the-desk", "First exact manuscript words.")
    assert has_element?(home, "#on-the-desk a[href='/correspondence/writing/#{first.id}']")

    assert has_element?(
             home,
             "#on-the-desk a[href='/correspondence/packets/new?piece=#{first.id}']"
           )

    {:ok, reopened, _} = live(conn, "/correspondence")
    assert has_element?(reopened, "#on-the-desk", "First desk piece")
    assert {:ok, reopened_desk} = Correspondence.desk(location)
    assert reopened_desk.token == first_desk.token

    render_click(element(reopened, "[phx-click='place_on_desk'][phx-value-id='#{second.id}']"))
    assert {:ok, second_desk} = Correspondence.desk(location)
    assert second_desk.piece_id == second.id
    assert second_desk.token != first_desk.token
    assert File.read!(first.path) == source_before
    assert Correspondence.packet(location, sent.id) == packet_before

    {:ok, changed, _} = live(conn, "/correspondence")
    assert has_element?(changed, ".editorial-desk-piece", "Second desk piece")
    refute has_element?(changed, ".editorial-desk-piece", "First desk piece")
    render_click(element(changed, "[phx-click='clear_desk']"))

    assert {:ok, cleared_desk} = Correspondence.desk(location)
    assert cleared_desk.piece_id == nil
    assert is_binary(cleared_desk.token)
    {:ok, cleared, _} = live(conn, "/correspondence")
    assert has_element?(cleared, ".editorial-desk-empty")
    refute has_element?(cleared, ".editorial-desk-piece", "Second desk piece")
    assert File.read!(first.path) == source_before
    assert Correspondence.packet(location, sent.id) == packet_before
  end

  test "shortlisting a journal is a persisted personal marker and updates home places", %{
    conn: conn,
    location: location
  } do
    journal = save_journal(location, "Shortlist Journal")
    other = save_journal(location, "Unshortlisted Journal")

    {:ok, places, _} = live(conn, "/correspondence/journals")
    render_click(element(places, "[phx-click='toggle_shortlist'][phx-value-id='#{journal.id}']"))

    assert {:ok, %{shortlisted: true}} = Correspondence.journal(location, journal.id)
    assert {:ok, %{shortlisted: false}} = Correspondence.journal(location, other.id)

    {:ok, home, _} = live(conn, "/correspondence")
    assert has_element?(home, "#places-to-consider", "Shortlist Journal")
    refute has_element?(home, "#places-to-consider", "Unshortlisted Journal")

    assert has_element?(
             home,
             "#places-to-consider a[href='/correspondence/journals/#{journal.id}']"
           )

    {:ok, reopened_places, _} = live(conn, "/correspondence/journals")

    render_click(
      element(reopened_places, "[phx-click='toggle_shortlist'][phx-value-id='#{journal.id}']")
    )

    assert {:ok, %{shortlisted: false}} = Correspondence.journal(location, journal.id)
  end

  test "quick shortlisting preserves unsaved journal notes and refuses outside edits", %{
    conn: conn,
    location: location
  } do
    journal = save_journal(location, "A place with draft notes")
    {:ok, view, _} = live(conn, "/correspondence/journals/#{journal.id}")

    render_change(element(view, "#journal-form"), %{
      "journal" => %{"name" => journal.name, "notes" => "Unsaved editorial notes"}
    })

    render_click(element(view, "[phx-click='toggle_shortlist'][phx-value-id='#{journal.id}']"))
    assert has_element?(view, "textarea[name='journal[notes]']", "Unsaved editorial notes")
    assert {:ok, saved} = Correspondence.journal(location, journal.id)
    assert saved.shortlisted
    assert saved.notes == journal.notes
    assert saved.guidelines == journal.guidelines
    # An outside update must not be silently replaced by a later quick toggle.
    attrs =
      Map.take(saved, [
        :name,
        :website,
        :submission_url,
        :interests,
        :guidelines,
        :windows,
        :fee,
        :simultaneous_policy,
        :response_expectation,
        :notes,
        :shortlisted,
        :verified
      ])

    {:ok, external} =
      Correspondence.save_journal(
        location,
        Map.put(attrs, :notes, "Outside notes"),
        saved.id,
        saved.token
      )

    render_click(element(view, "[phx-click='toggle_shortlist'][phx-value-id='#{journal.id}']"))
    assert has_element?(view, "[role='alert']", "changed on disk")
    assert Correspondence.journal(location, journal.id) == {:ok, external}
    assert has_element?(view, "textarea[name='journal[notes]']", "Unsaved editorial notes")
  end

  test "home limits active submissions to three and recent replies to two while keeping full history linked",
       %{
         conn: conn,
         location: location
       } do
    journal = save_journal(location, "Activity Review")

    active_packets =
      for n <- 1..5 do
        piece = save_piece(location, "Active piece #{n}", "Active words #{n}.")
        packet = prepare_packet(location, journal, [piece], "Active packet #{n}")
        day = String.pad_leading(Integer.to_string(n + 1), 2, "0")
        {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-#{day}")
        {:ok, awaiting} = Correspondence.set_status(location, sent.id, sent.token, "awaiting")
        awaiting
      end

    reply_packets =
      for n <- 1..4 do
        piece = save_piece(location, "Reply piece #{n}", "Reply words #{n}.")
        packet = prepare_packet(location, journal, [piece], "Reply packet #{n}")

        day = String.pad_leading(Integer.to_string(n + 10), 2, "0")
        {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-#{day}")

        {:ok, replied} =
          Correspondence.respond(
            location,
            sent.id,
            sent.token,
            "declined",
            "A considered reply #{n}.",
            "2026-10-#{n + 20}"
          )

        replied
      end

    {:ok, home, _} = live(conn, "/correspondence")

    displayed_active = Enum.count(active_packets, &has_element?(home, "#out-in-world", &1.title))
    assert displayed_active == 3

    replies_html = render(element(home, "#recent-replies"))
    assert length(Regex.scan(~r/class="editorial-reply-open"/, replies_html)) == 2

    assert has_element?(
             home,
             "#correspondence-home a[href='/correspondence/packets']",
             "All packets"
           )

    {:ok, history, _} = live(conn, "/correspondence/packets")

    for packet <- active_packets ++ reply_packets,
        do: assert(has_element?(history, ".corr-library-piece", packet.title))

    for packet <- reply_packets,
        do: assert(has_element?(history, "a[href='/correspondence/packets/#{packet.id}']"))
  end

  test "an unavailable pinned work is not presented as current writing and the pin can be cleared",
       %{
         conn: conn,
         location: location
       } do
    piece = save_piece(location, "Removed desk piece", "Words no longer in the collection.")
    assert {:ok, desk} = Correspondence.place_on_desk(location, piece.id, nil)
    assert desk.piece_id == piece.id
    {:ok, _trashed} = Poems.trash(location, piece)

    {:ok, home, _} = live(conn, "/correspondence")
    refute has_element?(home, "#on-the-desk", "Removed desk piece")
    refute has_element?(home, "#on-the-desk", "Words no longer in the collection.")
    assert has_element?(home, "#on-the-desk [phx-click='clear_desk']")

    render_click(element(home, "[phx-click='clear_desk']"))
    assert {:ok, %{piece_id: nil}} = Correspondence.desk(location)
  end

  test "an unavailable collection shows guidance without creating Correspondence data", %{
    conn: conn,
    collection: collection
  } do
    {:ok, _} = Storage.clear_folder()
    {:ok, view, _} = live(conn, "/correspondence")
    assert has_element?(view, "[role='alert']", "collection folder")
    refute File.exists?(Path.join(collection, "correspondence"))
    {:ok, _} = Storage.set_folder(collection)
  end

  test "a missing configured folder stays missing and is described as the collection", %{
    conn: conn,
    collection: collection
  } do
    offline = collection <> "-offline"
    File.rename!(collection, offline)

    try do
      {:ok, view, _} = live(conn, "/correspondence")
      assert has_element?(view, "[role='alert']", "collection folder is unavailable")
      refute render(view) =~ "backup folder is unavailable"
      refute has_element?(view, "#correspondence-home")
      refute File.exists?(collection)
    after
      File.rename!(offline, collection)
    end
  end

  defp save_piece(location, title, body) do
    {:ok, piece} = Poems.save(location, Poems.new(location), %{title: title, body: body})
    piece
  end

  defp save_journal(location, name) do
    {:ok, journal} =
      Correspondence.save_journal(location, %{
        name: name,
        interests: "Synthetic poetry",
        windows: "Not recorded",
        simultaneous_policy: "unknown",
        shortlisted: false,
        verified: false
      })

    journal
  end

  defp prepare_packet(location, journal, pieces, title \\ "Synthetic packet") do
    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: title,
        journal_id: journal.id,
        piece_ids: Enum.map(pieces, & &1.id)
      })

    packet
  end
end
