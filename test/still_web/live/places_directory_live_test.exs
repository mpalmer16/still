defmodule StillWeb.PlacesDirectoryLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Correspondence, Poems, Storage}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "writing")
    File.mkdir_p!(folder)
    assert {:ok, _} = Storage.set_folder(folder)
    on_exit(fn -> Application.put_env(:still, :storage_state_directory, previous) end)
    %{location: Storage.collection_location()}
  end

  test "combined search, nearby, reach, exact simultaneous policy, and awaiting history filters agree",
       %{conn: conn, location: location} do
    matched =
      journal!(location, %{
        name: "Willow Review",
        notes: "Welcomes orchard poems",
        shortlisted: true,
        reach: "long_shot",
        simultaneous_policy: "not_allowed"
      })

    near_miss =
      journal!(location, %{
        name: "Other Orchard Review",
        notes: "Welcomes orchard poems",
        shortlisted: true,
        reach: "long_shot",
        simultaneous_policy: "allowed"
      })

    {:ok, piece} = Poems.save(location, Poems.new(location), %{title: "Orchard", body: "Words"})
    submit_packet!(location, matched.id, piece.id)

    path =
      "/correspondence/journals?q=orchard&nearby=nearby&reach=long_shot&simultaneous=not_allowed&history=awaiting"

    {:ok, view, _} = live(conn, path)
    assert has_element?(view, "#place-row-#{matched.id}", "Willow Review")
    refute has_element?(view, "#place-row-#{near_miss.id}")
    assert has_element?(view, "#places-nearby option[value='nearby'][selected]")
    assert has_element?(view, "#places-reach option[value='long_shot'][selected]")
    assert has_element?(view, "#places-simultaneous option[value='not_allowed'][selected]")
    assert has_element?(view, "#places-history option[value='awaiting'][selected]")
  end

  test "filter route reopens with its values and detail return keeps the current query", %{
    conn: conn,
    location: location
  } do
    places =
      for n <- 1..41 do
        journal!(location, %{
          name: "Archive #{String.pad_leading(to_string(n), 3, "0")}",
          shortlisted: true
        })
      end

    place = List.last(places)
    journal!(location, %{name: "Another Review", shortlisted: true})
    path = "/correspondence/journals?q=Archive&nearby=nearby&status=all&page=2"
    {:ok, view, _} = live(conn, path)
    assert has_element?(view, "#place-row-#{place.id}")
    assert has_element?(view, "#places-result-count", "41–41 of 41 places")
    assert has_element?(view, "#places-query[value='Archive']")
    assert has_element?(view, "#places-status option[value='all'][selected]")

    render_click(element(view, "a.places-name", place.name))
    assert_patch(view, ~p"/correspondence/journals/#{place.id}")

    assert has_element?(
             view,
             ".editorial-place-back[href*='q=Archive'][href*='nearby=nearby'][href*='page=2']"
           )

    render_click(element(view, ".editorial-place-back"))
    assert has_element?(view, "#place-row-#{place.id}")
    assert has_element?(view, "#places-query[value='Archive']")
    assert has_element?(view, "#places-nearby option[value='nearby'][selected]")
    assert has_element?(view, "#places-result-count", "41–41 of 41 places")

    {:ok, reopened, _} = live(conn, path)
    assert has_element?(reopened, "#place-row-#{place.id}")
    assert has_element?(reopened, "#places-query[value='Archive']")
  end

  test "Enter submits and retains the search and selected filters", %{
    conn: conn,
    location: location
  } do
    place = journal!(location, %{name: "Open Field", shortlisted: true})
    journal!(location, %{name: "Closed Field", shortlisted: false})
    {:ok, view, _} = live(conn, ~p"/correspondence/journals")

    render_submit(element(view, "#places-filters"), %{
      "places" => %{"q" => "Open", "nearby" => "nearby", "status" => "active"}
    })

    assert_patch(view, ~p"/correspondence/journals?nearby=nearby&q=Open")
    assert has_element?(view, "#place-row-#{place.id}")
    assert has_element?(view, "#places-query[value='Open']")
    assert has_element?(view, "#places-nearby option[value='nearby'][selected]")
  end

  test "sorting updates the aria state and keeps deterministic name ordering", %{
    conn: conn,
    location: location
  } do
    zulu = journal!(location, %{name: "Zulu Review", reach: "stretch"})
    alpha = journal!(location, %{name: "Alpha Review", reach: "stretch"})
    middle = journal!(location, %{name: "Middle Review", reach: "stretch"})
    {:ok, view, _} = live(conn, ~p"/correspondence/journals")

    assert has_element?(view, "th[aria-sort='ascending'] button[phx-value-column='name']")
    assert row_ids(view) == [alpha.id, middle.id, zulu.id]

    render_click(element(view, "button[phx-value-column='name']"))
    assert has_element?(view, "th[aria-sort='descending'] button[phx-value-column='name']")
    assert row_ids(view) == [zulu.id, middle.id, alpha.id]

    render_click(element(view, "button[phx-value-column='name']"))
    assert has_element?(view, "th[aria-sort='ascending'] button[phx-value-column='name']")
    assert row_ids(view) == [alpha.id, middle.id, zulu.id]

    render_click(element(view, "button[phx-value-column='reach']"))
    assert has_element?(view, "th[aria-sort='ascending'] button[phx-value-column='reach']")
    assert row_ids(view) == [alpha.id, middle.id, zulu.id]

    render_click(element(view, "button[phx-value-column='window']"))
    assert has_element?(view, "th[aria-sort='ascending'] button[phx-value-column='window']")

    render_click(element(view, "button[phx-value-column='last_sent']"))
    assert has_element?(view, "th[aria-sort='descending'] button[phx-value-column='last_sent']")
  end

  test "pagination shows 85 records, and a new search returns to page one with bounded filter queries",
       %{conn: conn, location: location} do
    for n <- 1..85,
        do: journal!(location, %{name: "Place #{String.pad_leading(to_string(n), 3, "0")}"})

    old_icon_fetch = Application.get_env(:still, :fetch_place_icons)
    Application.put_env(:still, :fetch_place_icons, false)
    on_exit(fn -> Application.put_env(:still, :fetch_place_icons, old_icon_fetch) end)
    {:ok, view, _} = live(conn, "/correspondence/journals?page=3")
    assert has_element?(view, "#places-result-count", "81–85 of 85 places")
    assert length(row_ids(view)) == 5

    render_click(element(view, "nav[aria-label='Places pages'] button", "Previous page"))
    assert_patch(view, "/correspondence/journals?page=2")
    assert has_element?(view, "#places-result-count", "41–80 of 85 places")
    assert length(row_ids(view)) == 40
    render_click(element(view, "nav[aria-label='Places pages'] button", "Next page"))
    assert_patch(view, "/correspondence/journals?page=3")
    assert has_element?(view, "#places-result-count", "81–85 of 85 places")

    count = :atomics.new(1, [])
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:still, :repo, :query],
        fn _, _, _, _ -> :atomics.add(count, 1, 1) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    view
    |> element("#places-filters")
    |> render_change(%{"places" => %{"q" => "Place 084"}})

    queries = :atomics.get(count, 1)
    assert queries < 8, "filtering the loaded Places list used #{queries} database queries"
    assert has_element?(view, "#places-result-count", "1–1 of 1 place")
    assert row_ids(view) == [find_id_by_name(location, "Place 084")]
    assert_patch(view, ~p"/correspondence/journals?q=Place+084")
  end

  test "no matches can be reset", %{conn: conn, location: location} do
    place = journal!(location, %{name: "Silver Review"})
    {:ok, view, _} = live(conn, ~p"/correspondence/journals")

    view
    |> element("#places-filters")
    |> render_change(%{"places" => %{"q" => "No such place"}})

    assert has_element?(view, "#places-result-count", "No places match this view")

    assert has_element?(
             view,
             ".editorial-place-empty-note",
             "Try another search or reset the view"
           )

    refute has_element?(view, "#places-table")
    render_click(element(view, "#reset-places"))
    assert has_element?(view, "#place-row-#{place.id}")
  end

  test "an empty directory has its own invitation", %{conn: conn} do
    {:ok, empty, _} = live(conn, ~p"/correspondence/journals")
    assert has_element?(empty, ".editorial-place-empty", "The directory is open.")
    assert has_element?(empty, "#places-result-count", "0 total")
    refute has_element?(empty, ".editorial-place-empty-note")
  end

  test "nearby toggle removes a row from the active nearby filter without clearing it", %{
    conn: conn,
    location: location
  } do
    place = journal!(location, %{name: "Nearby Review", shortlisted: true})
    path = ~p"/correspondence/journals?nearby=nearby"
    {:ok, view, _} = live(conn, path)
    assert has_element?(view, "#place-row-#{place.id}")

    render_click(element(view, "#place-row-#{place.id} button[phx-click=toggle_shortlist]"))
    refute has_element?(view, "#place-row-#{place.id}")
    assert has_element?(view, "#places-nearby option[value='nearby'][selected]")
    assert has_element?(view, "#places-result-count", "No places match this view")
    assert {:ok, updated} = Correspondence.journal(location, place.id)
    refute updated.shortlisted
  end

  test "reconnecting an unavailable folder reloads the directory instead of keeping an empty view",
       %{conn: conn, location: location} do
    place = journal!(location, %{name: "Reconnected Review"})
    {:ok, view, _} = live(conn, ~p"/correspondence/journals")
    assert has_element?(view, "#place-row-#{place.id}")
    away = location.folder <> "-unavailable"
    File.rename!(location.folder, away)
    on_exit(fn -> if File.dir?(away), do: File.rename!(away, location.folder) end)
    render_patch(view, ~p"/correspondence/journals?q=Reconnected")
    refute has_element?(view, "#places-table")
    File.rename!(away, location.folder)
    render_patch(view, ~p"/correspondence/journals?q=Review")
    assert has_element?(view, "#place-row-#{place.id}")
  end

  defp journal!(location, attrs) do
    {:ok, journal} =
      Correspondence.save_journal(location, Map.put_new(attrs, :name, "Synthetic Review"))

    journal
  end

  defp submit_packet!(location, journal_id, piece_id) do
    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Synthetic packet",
        journal_id: journal_id,
        piece_ids: [piece_id]
      })

    {:ok, submitted} = Correspondence.submit(location, packet.id, packet.token, "2026-09-21")
    submitted
  end

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#places-table tbody tr")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "place-row-", ""))
  end

  defp find_id_by_name(location, name) do
    {:ok, journals} = Correspondence.journals(location)
    Enum.find(journals, &(&1.name == name)).id
  end
end
