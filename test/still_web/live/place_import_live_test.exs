defmodule StillWeb.PlaceImportLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Correspondence, Poems, Storage}

  @moduletag :tmp_dir
  setup %{tmp_dir: root} do
    old = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    collection = Path.join(root, "collection")
    File.mkdir_p!(collection)
    {:ok, _} = Storage.set_folder(collection)
    on_exit(fn -> Application.put_env(:still, :storage_state_directory, old) end)
    %{location: Storage.collection_location(), collection: collection}
  end

  test "Places links to upload; review writes nothing and confirmation adds only new names", %{
    conn: conn,
    location: location
  } do
    {:ok, old} = Correspondence.save_journal(location, %{name: "Existing"})
    {:ok, view, _} = live(conn, ~p"/correspondence/journals")
    render_click(element(view, "a", "Import Places"))
    assert_patch(view, ~p"/correspondence/journals/import")
    assert has_element?(view, "pre code", "Example Poetry Review")
    assert has_element?(view, "nav a.active", "Places")
    review(view, ~s([{"name":"New","notes":"<script>not markup</script>"},{"name":"existing"}]))
    assert has_element?(view, "#places-import-preview", "1 to add · 1 skipped")
    assert {:ok, [^old]} = Correspondence.journals(location)
    render_click(element(view, "#confirm-places-import"))
    assert has_element?(view, "#places-import-result", "Added 1 place. Skipped 1.")
    refute has_element?(view, "#confirm-places-import")
    assert {:ok, journals} = Correspondence.journals(location)
    assert length(journals) == 2
    new = Enum.find(journals, &(&1.name == "New"))
    refute new.verified
    {:ok, details, _} = live(conn, ~p"/correspondence/journals/#{new.id}")
    assert has_element?(details, "p", "<script>not markup</script>")
    refute has_element?(details, "script", "not markup")
  end

  test "invalid next upload clears an earlier preview, and missing selection never imports", %{
    conn: conn,
    location: location
  } do
    {:ok, view, _} = live(conn, ~p"/correspondence/journals/import")
    review(view, ~s([{"name":"Valid"}]))
    assert has_element?(view, "#confirm-places-import")
    review(view, ~s([{"name":"Other"},{"name":"Bad","wrong_field":"no"}]))
    assert render(view) =~ "Place 2: Unsupported fields: wrong_field."
    refute has_element?(view, "#confirm-places-import")
    render_submit(element(view, "#places-import-form"))
    assert render(view) =~ "Choose one JSON file"
    assert {:ok, []} = Correspondence.journals(location)
  end

  test "collection disappearing after preview reports failure and does not add elsewhere", %{
    conn: conn,
    collection: folder
  } do
    {:ok, view, _} = live(conn, ~p"/correspondence/journals/import")
    review(view, ~s([{"name":"Later"}]))
    File.rename!(folder, folder <> "-offline")
    render_click(element(view, "#confirm-places-import"))
    assert has_element?(view, "#places-import-result", "Added 0 places.")
    assert has_element?(view, "#places-import-result [role=alert]", "Could not add Later")
    refute has_element?(view, "#confirm-places-import")
    refute File.exists?(folder)
  end

  test "import without a configured collection guides setup and provides no upload", %{conn: conn} do
    {:ok, _} = Storage.clear_folder()
    {:ok, view, _} = live(conn, ~p"/correspondence/journals/import")
    assert render(view) =~ "Storage"
    refute has_element?(view, "#places-import-form")
  end

  test "deactivated places leave active choices, preserve details across edits and reopen, and reactivate",
       %{conn: conn, location: location} do
    {:ok, place} =
      Correspondence.save_journal(location, %{name: "Synthetic Place", shortlisted: true})

    {:ok, view, _} = live(conn, ~p"/correspondence/journals/#{place.id}")
    render_click(element(view, "#toggle-place-active"))
    assert has_element?(view, "#toggle-place-active", "Reactivate place")
    refute has_element?(view, "a", "Prepare a packet")
    # Optional empty addresses must remain editable after a names-only import.
    render_submit(element(view, "#journal-form"), %{
      "journal" => %{
        "name" => "Synthetic Place",
        "website" => "",
        "submission_url" => "",
        "notes" => "Kept while inactive"
      }
    })

    assert {:ok, inactive} = Correspondence.journal(location, place.id)
    assert inactive.inactive
    assert inactive.notes == "Kept while inactive"
    {:ok, directory, _} = live(conn, ~p"/correspondence/journals?status=inactive")
    assert has_element?(directory, "#place-row-#{place.id}", "Synthetic Place")
    assert has_element?(directory, "#places-result-count", "1–1 of 1 place")
    {:ok, home, _} = live(conn, ~p"/correspondence")
    refute has_element?(home, ".editorial-home-place", "Synthetic Place")
    {:ok, packet, _} = live(conn, ~p"/correspondence/packets/new")
    refute has_element?(packet, "option[value='#{place.id}']")
    {:ok, reopened, _} = live(conn, ~p"/correspondence/journals/#{place.id}")
    assert has_element?(reopened, "#toggle-place-active", "Reactivate place")
    render_click(element(reopened, "#toggle-place-active"))
    assert has_element?(reopened, "#toggle-place-active", "Deactivate place")
    {:ok, directory, _} = live(conn, ~p"/correspondence/journals?status=active")
    assert has_element?(directory, "#place-row-#{place.id}", "Synthetic Place")
    refute has_element?(directory, "#places-result-count", "No places match")
  end

  test "place suggestions and personal connections appear on both sides, survive editing, and reject stale tabs",
       %{conn: conn, location: location} do
    {:ok, piece} =
      Poems.save(location, Poems.new(location), %{title: "Winter field", body: "Snow falls"})

    {:ok, other} =
      Poems.save(location, Poems.new(location), %{title: "Water", body: "An unrelated piece"})

    for candidate <- [piece, other],
        do: assert(:ok = Correspondence.set_focus(location, candidate.id, true))

    {:ok, journal} =
      Correspondence.save_journal(location, %{
        name: "Echo Review",
        keywords: "winter",
        reach: "stretch",
        reach_note: "Read recent issues"
      })

    {:ok, place, _} = live(conn, ~p"/correspondence/journals/#{journal.id}")
    {:ok, stale, _} = live(conn, ~p"/correspondence/journals/#{journal.id}")
    assert has_element?(place, "#place-possibilities", "Winter field")
    assert has_element?(place, "#place-possibilities", "Shares: winter")
    render_submit(element(place, "#keep-possible-piece"), %{possibility: %{piece_id: other.id}})
    assert has_element?(place, "#place-possibilities", "Kept by you")
    render_submit(element(stale, "#keep-possible-piece"), %{possibility: %{piece_id: piece.id}})
    assert render(stale) =~ "This record changed on disk"
    assert {:ok, kept} = Correspondence.journal(location, journal.id)
    assert kept.possible_piece_ids == [other.id]
    render_click(element(place, "button[phx-click=toggle_shortlist]"))

    render_submit(element(place, "#journal-form"), %{
      journal: %{
        name: "Echo Review",
        keywords: "winter",
        reach: "long_shot",
        reach_note: "Worth trying"
      }
    })

    {:ok, work, _} = live(conn, ~p"/correspondence/writing/#{piece.id}")
    assert has_element?(work, "#work-places", "Shares: winter")
    assert has_element?(work, "#work-places", "A long shot")
    assert has_element?(work, "#work-places", "Worth trying")
    {:ok, manual, _} = live(conn, ~p"/correspondence/writing/#{other.id}")
    assert has_element?(manual, "#work-places", "Kept by you")
    {:ok, reopened, _} = live(conn, ~p"/correspondence/journals/#{journal.id}")
    render_click(element(reopened, "button[phx-click=remove_possible_piece]"))
    {:ok, manual, _} = live(conn, ~p"/correspondence/writing/#{other.id}")
    refute has_element?(manual, "#work-places a", "Echo Review")
  end

  test "descriptions and automatic local icons appear without changing the place edit token", %{
    conn: conn,
    location: location
  } do
    old_enabled = Application.get_env(:still, :fetch_place_icons)
    old_fetcher = Application.get_env(:still, :place_icon_fetcher)
    parent = self()

    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
      )

    Application.put_env(:still, :fetch_place_icons, true)

    Application.put_env(:still, :place_icon_fetcher, fn url ->
      send(parent, {:icon_fetch, url})
      {:ok, %{bytes: png}}
    end)

    on_exit(fn ->
      Application.put_env(:still, :fetch_place_icons, old_enabled)

      if old_fetcher,
        do: Application.put_env(:still, :place_icon_fetcher, old_fetcher),
        else: Application.delete_env(:still, :place_icon_fetcher)
    end)

    {:ok, journal} =
      Correspondence.save_journal(location, %{
        name: "Small Review",
        website: "https://review.example",
        description: "<script>A small journal</script>",
        shortlisted: true
      })

    {:ok, view, _} = live(conn, ~p"/correspondence/journals")
    render_async(view)
    assert_received {:icon_fetch, "https://review.example/favicon.ico"}
    assert has_element?(view, ".place-icon img[src^='data:image/png;base64,']")
    assert has_element?(view, ".places-description", "<script>A small journal</script>")
    refute has_element?(view, "script", "A small journal")
    assert {:ok, ^journal} = Correspondence.journal(location, journal.id)
    {:ok, place, _} = live(conn, ~p"/correspondence/journals/#{journal.id}")
    render_async(place)
    refute_received {:icon_fetch, _}
    assert has_element?(place, ".is-profile .place-icon img")

    render_submit(element(place, "#journal-form"), %{
      journal: %{
        name: journal.name,
        description: "An edited short blurb",
        icon_url: "https://images.example/new.png"
      }
    })

    render_async(place)
    assert_received {:icon_fetch, "https://images.example/new.png"}
    assert {:ok, updated} = Correspondence.journal(location, journal.id)
    assert updated.description == "An edited short blurb"
    assert updated.icon_url == "https://images.example/new.png"
    {:ok, home, _} = live(conn, ~p"/correspondence")
    render_async(home)
    assert has_element?(home, ".editorial-home-place .place-description", "An edited short blurb")
    assert has_element?(home, ".editorial-home-place .place-icon img")
  end

  defp review(view, json) do
    upload =
      file_input(view, "#places-import-form", :places, [
        %{name: "places.json", content: json, type: "application/json"}
      ])

    render_upload(upload, "places.json")
    render_submit(element(view, "#places-import-form"))
  end
end
