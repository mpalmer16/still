defmodule StillWeb.CalendarLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Storage, Repo, LocalRecord}
  alias Still.Correspondence
  alias Still.Correspondence.{Calendar, CalendarImport}
  import Ecto.Query
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    old = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "words")
    File.mkdir_p!(folder)
    {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      if old,
        do: Application.put_env(:still, :storage_state_directory, old),
        else: Application.delete_env(:still, :storage_state_directory)
    end)

    date =
      NaiveDateTime.local_now() |> NaiveDateTime.to_date() |> Date.add(7) |> Date.to_iso8601()

    %{location: Storage.collection_location(), date: date, folder: folder}
  end

  test "calendar is part of Correspondence and manual recurring events stay one saved series", %{
    conn: conn,
    location: loc,
    date: date
  } do
    {:ok, view, _} = live(conn, "/correspondence/calendar")
    assert has_element?(view, "nav[aria-label='Correspondence'] a.active", "Calendar")
    refute has_element?(view, ".site-header")

    assert has_element?(
             view,
             ".corr-calendar-heading form#calendar-filters.corr-calendar-toolbar"
           )

    assert has_element?(view, "#calendar-filters h1", "Calendar")
    assert has_element?(view, "#calendar-filters input[name='calendar[q]']")
    assert has_element?(view, "#calendar-filters input[name='calendar[cancelled]']")
    assert has_element?(view, "#calendar-filters input[name='calendar[hidden]']")

    assert has_element?(
             view,
             "#calendar-filters .corr-calendar-new-event[href='/correspondence/calendar/events/new']",
             "Add event"
           )

    assert has_element?(
             view,
             "#calendar-filters .corr-calendar-actions a[href='/correspondence/calendar/import']",
             "Import calendar events"
           )

    assert has_element?(view, ".corr-calendar-agenda-heading")

    assert has_element?(
             view,
             "#calendar-agenda-events[role='region'][aria-label='Calendar events'][tabindex='0']"
           )

    refute has_element?(view, "#calendar-agenda-events .corr-calendar-agenda-heading")

    view
    |> element("a[href='/correspondence/calendar/events/new']", "Add event")
    |> render_click()

    render_submit(element(view, "#calendar-event-form"), %{
      "event" => %{
        "title" => "My reading",
        "date" => date,
        "start_time" => "19:00",
        "repeat_frequency" => "weekly",
        "repeat_interval" => "1",
        "notes" => "<script>authored notes</script>"
      }
    })

    assert {:ok, [event]} = Calendar.list(loc)
    assert event.title == "My reading"
    assert event.start_time == "19:00"
    assert event.recurrence["frequency"] == "weekly"
    assert String.starts_with?(event.external_id, "still-")
    assert has_element?(view, ".corr-calendar-event", "My reading")
    assert has_element?(view, ".corr-calendar-event-time", "7:00 pm")
    assert has_element?(view, ".corr-calendar-recurrence", "Every week")
    refute has_element?(view, "script", "authored notes")

    assert Repo.aggregate(
             from(r in LocalRecord, where: r.scope == ^loc.scope and r.kind == "calendar_event"),
             :count
           ) == 1

    {:ok, editor, _} = live(conn, "/correspondence/calendar/events/#{event.id}/edit")

    render_submit(element(editor, "#calendar-event-form"), %{
      "event" => %{"title" => "My revised reading", "repeat_frequency" => "none"}
    })

    assert {:ok, revised} = Calendar.get(loc, event.id)
    assert revised.title == "My revised reading"
    assert revised.recurrence == nil
    assert revised.external_id == event.external_id
  end

  test "Reading periods timeline spans a month and keeps the Nearby filter across navigation", %{
    conn: conn,
    location: location
  } do
    today = NaiveDateTime.local_now() |> NaiveDateTime.to_date()
    month = Date.beginning_of_month(today)
    next_month = Date.add(Date.end_of_month(month), 1)
    span_start = Date.add(month, -4)
    span_end = Date.add(next_month, 4)

    for {name, opens, closes, nearby} <- [
          {"Nearby Journal", today, Date.add(today, 7), true},
          {"Month-spanning Journal", span_start, span_end, false},
          {"Past Journal", Date.add(month, -20), Date.add(month, -1), false},
          {"Future Journal", Date.add(next_month, 2), Date.add(next_month, 8), false}
        ] do
      assert {:ok, _} =
               Correspondence.save_journal(location, %{
                 name: name,
                 shortlisted: nearby,
                 submission_window: %{
                   "mode" => "dates",
                   "opens" => Date.to_iso8601(opens),
                   "closes" => Date.to_iso8601(closes)
                 }
               })
    end

    assert {:ok, _} =
             Correspondence.save_journal(location, %{
               name: "Year-round Journal",
               submission_window: %{"mode" => "always"}
             })

    assert {:ok, _} =
             Correspondence.save_journal(location, %{
               name: "Unconfirmed Journal",
               windows: "Dates to confirm"
             })

    month_param = Elixir.Calendar.strftime(month, "%Y-%m")
    {:ok, view, _} = live(conn, "/correspondence/calendar?month=#{month_param}")

    assert has_element?(view, "nav[aria-label='Calendar content'] a", "Reading periods")
    render_click(element(view, "nav[aria-label='Calendar content'] a", "Reading periods"))

    assert has_element?(view, "#reading-periods-timeline")
    assert has_element?(view, "#reading-periods-timeline li.reading-period-row", "Nearby Journal")

    assert has_element?(
             view,
             "#reading-periods-timeline li.reading-period-row",
             "Month-spanning Journal"
           )

    assert has_element?(
             view,
             ".reading-period-dates",
             Elixir.Calendar.strftime(span_start, "%b %-d")
           )

    assert has_element?(
             view,
             ".reading-period-dates",
             Elixir.Calendar.strftime(span_end, "%b %-d")
           )

    assert has_element?(view, ".reading-period-range.continues-before.continues-after")
    assert has_element?(view, "#reading-periods-timeline", "Open today")
    assert has_element?(view, "#reading-periods-timeline .reading-period-today")
    refute has_element?(view, "#reading-periods-timeline li.reading-period-row", "Past Journal")
    refute has_element?(view, "#reading-periods-timeline li.reading-period-row", "Future Journal")
    refute has_element?(view, ".corr-calendar-grid")
    refute has_element?(view, "#calendar-agenda-events")

    assert has_element?(view, "#reading-periods-year-round", "Open year-round")
    assert has_element?(view, "#reading-periods-year-round a", "Year-round Journal")
    assert has_element?(view, "#reading-periods-unconfirmed", "Dates to confirm")
    assert has_element?(view, "#reading-periods-unconfirmed a", "Unconfirmed Journal")

    filters = element(view, "#calendar-filters")
    render_change(filters, %{"calendar" => %{"nearby_windows" => "true"}})
    assert has_element?(view, "#reading-periods-timeline li.reading-period-row", "Nearby Journal")

    refute has_element?(
             view,
             "#reading-periods-timeline li.reading-period-row",
             "Month-spanning Journal"
           )

    render_click(element(view, "a[aria-label='Next month']"))
    assert has_element?(view, "#calendar-filters input[name='calendar[nearby_windows]'][checked]")
    assert has_element?(view, "a[aria-label='Previous month'][href*='nearby_windows=true']")
    refute has_element?(view, "#reading-periods-timeline .reading-period-today")
    refute has_element?(view, ".reading-period-row", "Future Journal")
    render_change(filters, %{"calendar" => %{"nearby_windows" => "false"}})
    assert has_element?(view, ".reading-period-row", "Future Journal")

    render_click(element(view, "nav[aria-label='Calendar content'] a", "Events"))
    refute has_element?(view, "#reading-periods-timeline")
    assert has_element?(view, ".corr-calendar-grid")
    assert has_element?(view, "#calendar-agenda-events")

    render_click(element(view, "nav[aria-label='Calendar content'] a", "Funding"))
    refute has_element?(view, "#reading-periods-timeline")

    assert has_element?(
             view,
             "nav[aria-label='Calendar content'] a[aria-current='page']",
             "Funding"
           )
  end

  test "Reading periods search and exports cover the active directory", %{
    conn: conn,
    location: location
  } do
    today = NaiveDateTime.local_now() |> NaiveDateTime.to_date()
    outside_month = Date.add(Date.end_of_month(today), 20)

    assert {:ok, _} =
             Correspondence.save_journal(location, %{
               name: "Amber Review",
               website: "https://amber.example/journal",
               submission_url: "https://amber.example/submit",
               windows: "Amber window note",
               submission_window: %{
                 "mode" => "dates",
                 "opens" => Date.to_iso8601(outside_month),
                 "closes" => Date.to_iso8601(Date.add(outside_month, 8))
               },
               notes: "Private planning note"
             })

    assert {:ok, _} =
             Correspondence.save_journal(location, %{
               name: "Blue Review",
               windows: "Blue anthology window",
               submission_window: %{"mode" => "always"}
             })

    assert {:ok, _} =
             Correspondence.save_journal(location, %{
               name: "Dates to Confirm",
               windows: "Confirm by email",
               submission_window: nil
             })

    assert {:ok, _} =
             Correspondence.save_journal(location, %{
               name: "Inactive Review",
               inactive: true,
               submission_window: %{"mode" => "always"}
             })

    month = Elixir.Calendar.strftime(today, "%Y-%m")
    {:ok, view, _} = live(conn, "/correspondence/calendar?month=#{month}")
    render_click(element(view, "nav[aria-label='Calendar content'] a", "Reading periods"))

    assert has_element?(
             view,
             "#calendar-filters input[type='search'][name='calendar[q]'][placeholder='Search reading periods']"
           )

    assert has_element?(view, "#calendar-filters input[name='calendar[nearby_windows]']")
    assert has_element?(view, "#correspondence-calendar[data-source='reading']")

    filters = element(view, "#calendar-filters")
    render_change(filters, %{"calendar" => %{"q" => "Confirm by email"}})
    assert has_element?(view, "#reading-periods-unconfirmed a", "Dates to Confirm")
    refute has_element?(view, "#reading-periods-year-round a", "Blue Review")
    render_change(filters, %{"calendar" => %{"q" => "amber.example/submit"}})
    refute has_element?(view, ".reading-period-row", "Amber Review")
    render_click(element(view, "a[aria-label='Next month']"))

    assert has_element?(
             view,
             "#calendar-filters input[name='calendar[q]'][value='amber.example/submit']"
           )

    assert has_element?(view, "#reading-periods-timeline li.reading-period-row", "Amber Review")
    render_change(filters, %{"calendar" => %{"q" => "Amber window note"}})
    assert has_element?(view, "#reading-periods-timeline li.reading-period-row", "Amber Review")
    render_change(filters, %{"calendar" => %{"q" => "Blue anthology window"}})
    assert has_element?(view, "#reading-periods-year-round a", "Blue Review")

    render_change(filters, %{"calendar" => %{"q" => "Amber", "nearby_windows" => "true"}})
    refute has_element?(view, "#reading-periods-timeline li.reading-period-row", "Amber Review")
    render_click(element(view, "a[aria-label='Next month']"))
    assert has_element?(view, "#correspondence-calendar[data-source='reading']")
    assert has_element?(view, "#calendar-filters input[name='calendar[q]'][value='Amber']")
    assert has_element?(view, "#calendar-filters input[name='calendar[nearby_windows]'][checked]")
    assert has_element?(view, "a[aria-label='Previous month'][href*='nearby_windows=true']")

    unconfirmed =
      view
      |> element(".corr-calendar-actions button", "Export dates to confirm")
      |> render_click()
      |> exported_json()

    assert has_element?(view, "#correspondence-export-json")
    assert has_element?(view, "button", "Copy JSON")
    assert Enum.map(unconfirmed, & &1["name"]) == ["Dates to Confirm"]
    assert hd(unconfirmed)["windows"] == "Confirm by email"
    assert hd(unconfirmed)["submission_window"] == nil
    refute String.contains?(Jason.encode!(unconfirmed), "Private planning note")

    render_click(element(view, "button[phx-click='close_json_export']"))

    all =
      view
      |> element(".corr-calendar-actions button", "Export all reading periods")
      |> render_click()
      |> exported_json()

    assert Enum.map(all, & &1["name"]) == ["Amber Review", "Blue Review", "Dates to Confirm"]
    amber = Enum.find(all, &(&1["name"] == "Amber Review"))
    blue = Enum.find(all, &(&1["name"] == "Blue Review"))
    assert amber["website"] == "https://amber.example/journal"
    assert amber["submission_url"] == "https://amber.example/submit"
    assert amber["windows"] == "Amber window note"

    assert amber["submission_window"] == %{
             "mode" => "dates",
             "opens" => Date.to_iso8601(outside_month),
             "closes" => Date.to_iso8601(Date.add(outside_month, 8))
           }

    assert blue["submission_window"] == %{"mode" => "always"}
    refute String.contains?(Jason.encode!(all), "Private planning note")

    render_click(element(view, "nav[aria-label='Calendar content'] a", "Events"))
    assert has_element?(view, ".corr-calendar-grid")
    refute has_element?(view, "#correspondence-export-json")
    refute has_element?(view, "button", "Export all reading periods")
    render_click(element(view, "nav[aria-label='Calendar content'] a", "Funding"))

    assert has_element?(
             view,
             "nav[aria-label='Calendar content'] a[aria-current='page']",
             "Funding"
           )
  end

  defp exported_json(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#correspondence-export-json")
    |> LazyHTML.text()
    |> Jason.decode!()
  end

  test "Calendar JSON keeps one record per series and includes events outside the current view",
       %{
         conn: conn,
         location: location
       } do
    {:ok, series} =
      Calendar.save(location, %{
        external_id: "monthly-reading",
        title: "Monthly reading",
        date: "2026-08-17",
        recurrence: %{"frequency" => "monthly", "interval" => 1},
        notes: "Bring a poem.\nSign up at the door."
      })

    assert {:ok, _} = Calendar.set_hidden(location, series.id, series.token, true)

    assert {:ok, _} =
             Calendar.save(location, %{
               external_id: "other-reading",
               title: "Other reading",
               date: "2026-11-17"
             })

    {:ok, view, _} = live(conn, ~p"/correspondence/calendar?month=2026-11&q=Other")
    refute has_element?(view, ".corr-calendar-day-event", "Monthly reading")
    rendered = render_click(element(view, ".corr-calendar-actions button", "Export JSON"))

    json =
      rendered
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#correspondence-export-json")
      |> LazyHTML.text()

    assert [
             %{
               "external_id" => "monthly-reading",
               "date" => "2026-08-17",
               "recurrence" => %{"frequency" => "monthly"},
               "notes" => "Bring a poem.\nSign up at the door.",
               "hidden" => true
             } = monthly,
             %{"external_id" => "other-reading"}
           ] = Jason.decode!(json)

    refute Map.has_key?(monthly, "id")
    refute Map.has_key?(monthly, "token")
  end

  test "one repeated date or whole series can be hidden and restored through the list", %{
    conn: conn,
    location: loc,
    date: date
  } do
    {:ok, event} =
      Calendar.save(loc, %{
        external_id: "weekly",
        title: "Weekly reading",
        date: date,
        recurrence: %{"frequency" => "weekly"}
      })

    {:ok, view, _} = live(conn, "/correspondence/calendar?view=list")
    assert has_element?(view, "#calendar-events-table", "Weekly reading")
    render_click(view, "hide_calendar_event", %{"id" => event.id, "date" => date})
    assert {:ok, hidden} = Calendar.get(loc, event.id)
    assert date in hidden.hidden_dates
    refute hidden.hidden
    refute has_element?(view, "button[phx-click='hide_calendar_event'][phx-value-date='#{date}']")
    render_change(element(view, "#calendar-filters"), %{"calendar" => %{"hidden" => "true"}})

    assert has_element?(
             view,
             "button[phx-click='restore_calendar_event'][phx-value-date='#{date}']"
           )

    render_click(view, "restore_calendar_event", %{"id" => event.id, "date" => date})
    assert {:ok, restored} = Calendar.get(loc, event.id)
    assert restored.hidden_dates == []
    render_click(view, "hide_calendar_series", %{"id" => event.id})
    assert has_element?(view, "button[phx-click='restore_calendar_series']", "Show series")
    render_click(view, "restore_calendar_series", %{"id" => event.id})
    assert {:ok, shown} = Calendar.get(loc, event.id)
    refute shown.hidden
  end

  test "reviewed JSON imports add, skip and update without overriding visibility", %{
    conn: conn,
    location: loc,
    date: date
  } do
    {:ok, view, _} = live(conn, "/correspondence/calendar/import")

    row = %{
      "external_id" => "cal-reading",
      "title" => "Curated reading",
      "date" => date,
      "start_time" => "19:00",
      "notes" => "Old note",
      "recurrence" => %{"frequency" => "weekly"}
    }

    review(view, Jason.encode!([row]))
    assert has_element?(view, "#calendar-import-preview", "1 new")
    assert has_element?(view, "#calendar-import-preview", "7:00 pm")
    assert {:ok, []} = Calendar.list(loc)
    view |> element("#confirm-calendar-import") |> render_click()
    assert has_element?(view, "#calendar-import-result", "Added 1")
    {:ok, [event]} = Calendar.list(loc)
    assert event.start_time == "19:00"
    {:ok, _} = Calendar.set_hidden(loc, event.id, event.token, true)
    changed = row |> Map.put("title", "Updated reading") |> Map.delete("notes")
    review(view, Jason.encode!([changed]))
    assert has_element?(view, "#calendar-import-preview", "Old note")
    assert has_element?(view, "#calendar-import-preview", "Not set")
    view |> element("#confirm-calendar-import") |> render_click()
    {:ok, [updated]} = Calendar.list(loc)
    assert updated.hidden
    assert updated.title == "Updated reading"
    assert Map.get(updated, :notes) == nil
    review(view, Jason.encode!([changed]))
    assert has_element?(view, "#calendar-import-preview", "1 unchanged")
    refute has_element?(view, "#confirm-calendar-import")
  end

  test "bad next upload clears a reviewed plan and missing collection does not receive imports",
       %{conn: conn, location: loc, date: date, folder: folder} do
    {:ok, view, _} = live(conn, "/correspondence/calendar/import")
    review(view, Jason.encode!([%{external_id: "one", title: "An event", date: date}]))
    assert has_element?(view, "#confirm-calendar-import")
    review(view, ~s([{"external_id":"bad","title":"Bad date","date":"not a date"}]))
    refute has_element?(view, "#confirm-calendar-import")
    assert {:ok, []} = Calendar.list(loc)
    review(view, Jason.encode!([%{external_id: "one", title: "An event", date: date}]))
    File.rename!(folder, folder <> "-offline")
    render_click(view, "import_calendar", %{})
    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "#confirm-calendar-import")
    refute File.exists?(folder)
  end

  test "download serves the actual schema and valid calendar files follow its field contract", %{
    conn: conn,
    date: date
  } do
    response = get(conn, "/correspondence/calendar/schema")
    schema = response |> response(200) |> Jason.decode!()
    assert schema["items"]["required"] == ["external_id", "title", "date"]
    assert schema["items"]["additionalProperties"] == false
    properties = schema["items"]["properties"]

    for key <-
          ~w(external_id title date start_time end_time end_date timezone venue address url notes category status recurrence),
        do: assert(Map.has_key?(properties, key))

    assert Regex.match?(Regex.compile!(properties["date"]["pattern"]), date)
    assert properties["category"]["enum"] == ~w(reading workshop deadline other)
    url_pattern = Regex.compile!(properties["url"]["pattern"])

    for url <- [
          "https://example.org",
          "http://example.org/events/reading",
          "https://example.org/events/reading?date=2026-11-20&source=cal#tickets"
        ] do
      assert Regex.match?(url_pattern, url)
    end

    for url <- ["https://", "http://", "mailto:reader@example.org", "not a URL"] do
      refute Regex.match?(url_pattern, url)
    end

    assert {:ok, [_]} =
             CalendarImport.parse(
               Jason.encode!([
                 %{
                   external_id: "contract",
                   title: "Calendar contract",
                   date: date,
                   start_time: "19:00",
                   end_time: "21:00",
                   timezone: "America/Chicago",
                   venue: "The room",
                   address: "A street",
                   url: "https://example.org",
                   notes: "A note",
                   category: "reading",
                   status: "scheduled",
                   recurrence: %{frequency: "weekly", interval: 2}
                 }
               ])
             )
  end

  defp review(view, json) do
    upload =
      file_input(view, "#calendar-import-form", :events, [
        %{name: "events.json", content: json, type: "application/json"}
      ])

    render_upload(upload, "events.json")
    render_submit(element(view, "#calendar-import-form"))
  end
end
