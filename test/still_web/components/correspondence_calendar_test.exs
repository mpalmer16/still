defmodule StillWeb.CorrespondenceCalendarTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StillWeb.CorrespondenceCalendar

  test "shows a Sunday through Saturday six week grid and event details in the agenda" do
    html =
      calendar_html([
        event("Book launch", "2026-11-12", %{
          start_time: "18:30",
          end_time: "20:00",
          venue: "North Room",
          address: "12 Main St",
          timezone: "Central time",
          category: "reading",
          notes: "Bring a notebook",
          url: "https://example.test/event"
        }),
        event("Deadline", "2026-11-13")
      ])

    assert html =~ ~s(id="correspondence-calendar")

    weekday_headers =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".corr-calendar-weekday")
      |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))

    assert weekday_headers == ~w(Sun Mon Tue Wed Thu Fri Sat)
    assert length(Regex.scan(~r/class="corr-calendar-day(?:\s|\")/, html)) == 42
    assert first_grid_date(html) == "Sunday, November 1, 2026"
    assert html =~ "Book launch"
    assert html =~ "6:30 pm–8:00 pm"
    assert html =~ "Time not provided"
    assert html =~ "North Room"
    assert html =~ "Central time"
    assert html =~ "Bring a notebook"
    assert html =~ ~s(href="https://example.test/event")
    assert html =~ ~s(href="/correspondence/calendar?date=2026-11-12&amp;month=2026-11&amp;q=)
  end

  test "six week grids start on Sunday for Saturday and cross-year month starts" do
    assert first_grid_date(calendar_html([], %{month: ~D[2026-08-01]})) ==
             "Sunday, July 26, 2026"

    assert first_grid_date(calendar_html([], %{month: ~D[2027-01-01]})) ==
             "Sunday, December 27, 2026"
  end

  test "groups the upcoming agenda, includes ongoing events, and omits cancelled events by default" do
    html =
      calendar_html([
        event("Past", "2026-11-01"),
        event("Ongoing", "2026-11-01", %{end_date: "2026-11-15"}),
        event("Cancelled", "2026-11-14", %{status: "cancelled"}),
        event("Next", "2026-11-14")
      ])

    agenda =
      LazyHTML.query(LazyHTML.from_fragment(html), ".corr-calendar-agenda") |> LazyHTML.text()

    refute agenda =~ "Past"
    assert html =~ "Ongoing"
    assert html =~ "Next"
    refute html =~ "Cancelled"
    assert html =~ "Coming up"
    refute html =~ "No upcoming events."
  end

  test "selected day filters the agenda and cancelled events require explicit inclusion" do
    html =
      render_component(&CorrespondenceCalendar.page/1, %{
        today: ~D[2026-11-12],
        month: ~D[2026-11-01],
        selected_date: ~D[2026-11-13],
        events: [
          event("Cancelled reading", "2026-11-13", %{
            status: "cancelled",
            url: "javascript:alert(1)"
          })
        ],
        query: "reading",
        include_cancelled: true
      })

    assert html =~ "November 13"
    assert html =~ "Cancelled reading"
    assert html =~ "Cancelled"
    refute html =~ ~s(href="javascript:)
    assert html =~ ~s(name="calendar[q]")
    assert html =~ ~s(name="calendar[cancelled]")
  end

  test "month navigation preserves the query" do
    html = calendar_html([], %{query: "open mic"})
    assert html =~ ~s(href="/correspondence/calendar?month=2026-10&amp;q=open+mic")
    assert html =~ ~s(href="/correspondence/calendar?month=2026-12&amp;q=open+mic")
    assert html =~ ~s(href="/correspondence/calendar?month=2026-11&amp;q=open+mic")
  end

  test "calendar weeks cross year boundaries and selected ongoing events use the selected date" do
    html =
      render_component(&CorrespondenceCalendar.page/1, %{
        today: ~D[2026-12-31],
        month: ~D[2026-12-01],
        selected_date: ~D[2027-01-01],
        events: [event("Winter reading", "2026-12-30", %{end_date: "2027-01-02"})]
      })

    assert html =~ "2026-12"
    assert html =~ "January 1"
    assert html =~ "Dec 30–Jan 2"
    assert html =~ "is-selected"
    assert html =~ ~s(href="/correspondence/calendar?month=2026-12&amp;q=")
  end

  test "search filters visible calendar events by event details" do
    html =
      calendar_html(
        [
          event("Open reading", "2026-11-13", %{venue: "Maple Room"}),
          event("Studio workshop", "2026-11-14", %{venue: "Cedar Hall"})
        ],
        %{query: "maple"}
      )

    assert html =~ "Open reading"
    refute html =~ "Studio workshop"
  end

  test "list view preserves controls and exposes edit, occurrence hide, series hide, and restore actions" do
    html =
      render_component(&CorrespondenceCalendar.page/1, %{
        today: ~D[2026-11-12],
        month: ~D[2026-11-01],
        view: "list",
        query: "reading",
        include_cancelled: true,
        include_hidden: true,
        range: "all",
        events: [
          event("Weekly reading", "2026-11-13", %{
            id: "rec-1",
            start_time: "09:05",
            end_time: "12:00",
            recurrence: %{frequency: "weekly"},
            recurrence_label: "Every week"
          }),
          event("Hidden reading", "2026-11-14", %{id: "hidden-1", hidden: true})
        ]
      })

    assert html =~ ~s(id="calendar-events-table")
    assert html =~ "9:05 am–12:00 pm"
    assert html =~ ~s(name="calendar[hidden]")
    assert html =~ ~s(name="calendar[range]")

    assert html =~
             ~s(href="/correspondence/calendar?cancelled=true&amp;hidden=true&amp;month=2026-11&amp;q=reading&amp;range=all&amp;view=calendar")

    assert html =~ ~s(href="/correspondence/calendar/events/rec-1/edit")
    assert html =~ ~s(phx-click="hide_calendar_event")
    assert html =~ ~s(phx-click="hide_calendar_series")
    assert html =~ ~s(phx-value-date="2026-11-13")
    assert html =~ ~s(phx-click="restore_calendar_event")
    assert html =~ "Hidden reading"
  end

  test "hidden occurrences stay out of the view unless included" do
    events = [event("Kept hidden", "2026-11-13", %{hidden: true})]
    refute calendar_html(events) =~ "Kept hidden"
    assert calendar_html(events, %{include_hidden: true}) =~ "Kept hidden"
  end

  test "a hidden recurring series restores as a whole series" do
    html =
      render_component(&CorrespondenceCalendar.page/1, %{
        today: ~D[2026-11-12],
        month: ~D[2026-11-01],
        view: "list",
        include_hidden: true,
        events: [
          event("Weekly pages", "2026-11-13", %{
            id: "series-2",
            recurrence: %{frequency: "weekly"},
            hidden: true,
            series_hidden: true
          })
        ]
      })

    assert html =~ ~s(phx-click="restore_calendar_series")
    refute html =~ ~s(phx-click="restore_calendar_event")
    assert html =~ "Show series"
  end

  test "list pagination keeps every matching event reachable and preserves filters" do
    events =
      for number <- 1..41 do
        event("Event #{number}", Date.to_iso8601(Date.add(~D[2026-11-13], number)))
      end

    page_one =
      render_component(&CorrespondenceCalendar.page/1, %{
        today: ~D[2026-11-12],
        month: ~D[2026-11-01],
        view: "list",
        range: "all",
        include_hidden: true,
        query: "event",
        events: events
      })

    assert length(Regex.scan(~r/<tr class="">/, page_one)) == 40
    assert page_one =~ ">Event 1</a>"
    refute page_one =~ "Event 41"

    assert page_one =~ "page=2"
    assert page_one =~ "hidden=true&amp;month=2026-11"

    page_two =
      render_component(&CorrespondenceCalendar.page/1, %{
        today: ~D[2026-11-12],
        month: ~D[2026-11-01],
        view: "list",
        range: "all",
        page: 2,
        include_hidden: true,
        query: "event",
        events: events
      })

    assert page_two =~ ">Event 41</a>"
    refute page_two =~ ">Event 1</a>"
    assert page_two =~ "Page 2 of 2 · 41 events"
  end

  defp calendar_html(events, overrides \\ %{}) do
    assigns =
      Map.merge(%{events: events, today: ~D[2026-11-12], month: ~D[2026-11-01]}, overrides)

    render_component(&CorrespondenceCalendar.page/1, assigns)
  end

  defp first_grid_date(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".corr-calendar-day-link")
    |> Enum.at(0)
    |> LazyHTML.attribute("aria-label")
    |> Enum.at(0)
  end

  defp event(title, date, overrides \\ %{}) do
    Map.merge(
      %{id: title, external_id: title, title: title, date: date, status: "scheduled"},
      overrides
    )
  end
end
