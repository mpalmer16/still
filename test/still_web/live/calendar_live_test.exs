defmodule StillWeb.CalendarLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Storage, Repo, LocalRecord}
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
    assert event.recurrence["frequency"] == "weekly"
    assert String.starts_with?(event.external_id, "still-")
    assert has_element?(view, ".corr-calendar-event", "My reading")
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
      "notes" => "Old note",
      "recurrence" => %{"frequency" => "weekly"}
    }

    review(view, Jason.encode!([row]))
    assert has_element?(view, "#calendar-import-preview", "1 new")
    assert {:ok, []} = Calendar.list(loc)
    view |> element("#confirm-calendar-import") |> render_click()
    assert has_element?(view, "#calendar-import-result", "Added 1")
    {:ok, [event]} = Calendar.list(loc)
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
