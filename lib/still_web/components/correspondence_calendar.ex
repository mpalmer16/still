defmodule StillWeb.CorrespondenceCalendar do
  @moduledoc "Calendar and agenda presentation for correspondence events."
  use StillWeb, :html

  attr :events, :list, default: []
  attr :today, :any, required: true
  attr :month, :any, required: true
  attr :selected_date, :any, default: nil
  attr :query, :string, default: ""
  attr :include_cancelled, :boolean, default: false
  attr :include_hidden, :boolean, default: false
  attr :view, :string, default: "calendar"
  attr :range, :string, default: "upcoming"
  attr :page, :integer, default: 1

  def page(assigns) do
    month_start = Date.beginning_of_month(assigns.month)
    grid_start = Date.add(month_start, -Date.day_of_week(month_start) + 1)
    dates = Enum.map(0..41, &Date.add(grid_start, &1))

    events =
      Enum.filter(assigns.events, fn event ->
        (assigns.include_cancelled || value(event, :status) != "cancelled") &&
          (assigns.include_hidden || !truthy?(value(event, :hidden))) &&
          matches_query?(event, assigns.query)
      end)

    matching_list_events =
      events
      |> Enum.filter(fn event ->
        assigns.range == "all" || not event_before_today?(event, assigns.today)
      end)
      |> Enum.sort_by(&date_sort_key/1)
      |> Enum.uniq_by(&value(&1, :id))

    list_page_count = max(1, ceil(length(matching_list_events) / 40))
    list_page = assigns.page |> normalize_page() |> min(list_page_count)
    list_events = Enum.slice(matching_list_events, (list_page - 1) * 40, 40)

    {agenda, agenda_more?} = agenda(events, assigns.today, assigns.selected_date)

    assigns =
      assigns
      |> assign(:events, events)
      |> assign(:list_events, list_events)
      |> assign(:list_page, list_page)
      |> assign(:list_page_count, list_page_count)
      |> assign(:list_total, length(matching_list_events))
      |> assign(:dates, dates)
      |> assign(:month_start, month_start)
      |> assign(:previous_month, Date.add(month_start, -1))
      |> assign(:next_month, Date.add(month_start, 32) |> Date.beginning_of_month())
      |> assign(:agenda, agenda)
      |> assign(:agenda_more?, agenda_more?)

    ~H"""
    <section id="correspondence-calendar" class="corr-calendar" aria-labelledby="calendar-heading">
      <header class="corr-calendar-heading">
        <div>
          <h1 id="calendar-heading">Calendar</h1>
          <nav class="corr-calendar-view-switch" aria-label="Calendar view">
            <.link
              aria-current={if @view == "calendar", do: "page"}
              patch={
                view_path(
                  "calendar",
                  @month_start,
                  @selected_date,
                  @query,
                  @include_cancelled,
                  @include_hidden,
                  @range,
                  @page
                )
              }
            >Calendar</.link>
            <.link
              aria-current={if @view == "list", do: "page"}
              patch={
                view_path(
                  "list",
                  @month_start,
                  @selected_date,
                  @query,
                  @include_cancelled,
                  @include_hidden,
                  @range,
                  @page
                )
              }
            >List</.link>
          </nav>
        </div>
        <div class="corr-calendar-header-actions">
          <.link patch={~p"/correspondence/calendar/events/new"} class="corr-button">Add event</.link>
          <details class="corr-popover corr-calendar-actions">
            <summary>Calendar menu <span aria-hidden="true">⌄</span></summary>
            <div class="corr-popover-panel">
              <.link patch={~p"/correspondence/calendar/import"}>Import calendar events</.link>
            </div>
          </details>
        </div>
      </header>

      <.form
        for={%{}}
        id="calendar-filters"
        class="corr-directory-toolbar"
        phx-change="filter_calendar"
        phx-submit="filter_calendar"
      >
        <label class="corr-directory-search">
          <span class="sr-only">Search calendar events</span>
          <input
            type="search"
            name="calendar[q]"
            value={@query}
            placeholder="Search events"
            phx-debounce="250"
            autocomplete="off"
          />
        </label>
        <label class="corr-calendar-cancelled">
          <input type="checkbox" name="calendar[cancelled]" value="true" checked={@include_cancelled} />
          Include cancelled
        </label>
        <label class="corr-calendar-hidden">
          <input type="checkbox" name="calendar[hidden]" value="true" checked={@include_hidden} />
          Include hidden
        </label>
        <label :if={@view == "list"} class="corr-calendar-range">
          <span>Show</span>
          <select name="calendar[range]">
            <option value="upcoming" selected={@range != "all"}>Upcoming</option>
            <option value="all" selected={@range == "all"}>All events</option>
          </select>
        </label>
      </.form>

      <div :if={@view == "list"} class="corr-calendar-list-view">
        <p class="corr-meta">
          One row per event or series. Recurring events show their next visible date.
        </p>
        <table id="calendar-events-table" class="corr-calendar-events-table">
          <thead>
            <tr>
              <th scope="col">Date</th><th scope="col">Event</th><th scope="col">Time</th><th scope="col">
                Location
              </th><th scope="col">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={event <- @list_events}
              class={if truthy?(value(event, :hidden)), do: "is-hidden"}
            >
              <td>{event_date_label(event)}</td>
              <td>
                <.link
                  patch={
                    date_path(
                      event_date(value(event, :date)),
                      @query,
                      @include_cancelled,
                      @include_hidden
                    )
                  }
                  class="corr-calendar-list-title"
                >{value(event, :title)}</.link>
                <span :if={value(event, :recurrence_label)} class="corr-calendar-recurrence">{value(
                  event,
                  :recurrence_label
                )}</span>
                <span :if={value(event, :status) == "cancelled"} class="corr-calendar-cancelled-label">Cancelled</span>
                <span :if={truthy?(value(event, :hidden))} class="corr-calendar-hidden-label">Hidden</span>
              </td>
              <td>
                {event_time(event)}<span :if={value(event, :timezone)} class="corr-calendar-timezone">{value(
                  event,
                  :timezone
                )}</span>
              </td>
              <td>
                {[value(event, :venue), value(event, :address)]
                |> Enum.reject(&(&1 in [nil, ""]))
                |> Enum.join(" · ")}
              </td>
              <td class="corr-calendar-event-actions">
                <.link patch={~p"/correspondence/calendar/events/#{value(event, :id)}/edit"}>Edit</.link>
                <button
                  :if={!truthy?(value(event, :hidden))}
                  type="button"
                  phx-click="hide_calendar_event"
                  phx-value-id={value(event, :id)}
                  phx-value-date={occurrence_date(event)}
                >Hide {if recurring?(event), do: "this date", else: "event"}</button>
                <button
                  :if={!truthy?(value(event, :hidden)) && recurring?(event)}
                  type="button"
                  phx-click="hide_calendar_series"
                  phx-value-id={value(event, :id)}
                >Hide series</button>
                <button
                  :if={truthy?(value(event, :hidden)) && truthy?(value(event, :series_hidden))}
                  type="button"
                  phx-click="restore_calendar_series"
                  phx-value-id={value(event, :id)}
                >{if recurring?(event), do: "Show series", else: "Show event"}</button>
                <button
                  :if={truthy?(value(event, :hidden)) && !truthy?(value(event, :series_hidden))}
                  type="button"
                  phx-click="restore_calendar_event"
                  phx-value-id={value(event, :id)}
                  phx-value-date={occurrence_date(event)}
                >Restore this date</button>
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={@list_events == []} class="corr-calendar-empty">
          No events in this view.
          <.link patch={~p"/correspondence/calendar/events/new"}>Add an event</.link>
          or <.link patch={~p"/correspondence/calendar/import"}>import events</.link>.
        </p>
        <nav :if={@list_page_count > 1} class="corr-calendar-pagination" aria-label="Event list pages">
          <.link
            :if={@list_page > 1}
            patch={
              view_path(
                "list",
                @month_start,
                @selected_date,
                @query,
                @include_cancelled,
                @include_hidden,
                @range,
                @list_page - 1
              )
            }
          >Previous</.link>
          <span>Page {@list_page} of {@list_page_count} · {@list_total} events</span>
          <.link
            :if={@list_page < @list_page_count}
            patch={
              view_path(
                "list",
                @month_start,
                @selected_date,
                @query,
                @include_cancelled,
                @include_hidden,
                @range,
                @list_page + 1
              )
            }
          >Next</.link>
        </nav>
        <p :if={@range != "all"} class="corr-calendar-range-note">
          Upcoming recurring dates are shown within the next year. Choose All events to include earlier events.
        </p>
      </div>

      <nav :if={@view == "calendar"} class="corr-calendar-month-nav" aria-label="Calendar month">
        <.link
          patch={month_path(@previous_month, @query, @include_cancelled, @include_hidden)}
          aria-label="Previous month"
          class="corr-calendar-month-step"
        >
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
            focusable="false"
          >
            <path d="m15 6-6 6 6 6" />
          </svg>
        </.link>
        <h2>{Calendar.strftime(@month_start, "%B %Y")}</h2>
        <.link
          patch={month_path(@next_month, @query, @include_cancelled, @include_hidden)}
          aria-label="Next month"
          class="corr-calendar-month-step"
        >
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
            focusable="false"
          >
            <path d="m9 6 6 6-6 6" />
          </svg>
        </.link>
        <.link
          patch={month_path(@today, @query, @include_cancelled, @include_hidden)}
          class="corr-text-link"
        >Today</.link>
      </nav>

      <div :if={@view == "calendar"} class="corr-calendar-layout">
        <div class="corr-calendar-grid">
          <div
            :for={weekday <- ~w(Mon Tue Wed Thu Fri Sat Sun)}
            class="corr-calendar-weekday"
          >
            {weekday}
          </div>
          <div
            :for={date <- @dates}
            class={day_classes(date, @month_start, @today, @selected_date)}
          >
            <.link
              patch={date_path(date, @query, @include_cancelled, @include_hidden)}
              class="corr-calendar-day-link"
              aria-label={Calendar.strftime(date, "%A, %B %-d, %Y")}
            >{date.day}</.link>
            <div class="corr-calendar-day-events">
              <.link
                :for={event <- Enum.take(events_on(@events, date), 2)}
                patch={date_path(date, @query, @include_cancelled, @include_hidden)}
                class={"corr-calendar-day-event status-#{value(event, :status) || "scheduled"}"}
              >{value(event, :title)}</.link>
              <.link
                :if={length(events_on(@events, date)) > 2}
                patch={date_path(date, @query, @include_cancelled, @include_hidden)}
                class="corr-calendar-more"
              >+{length(events_on(@events, date)) - 2} more</.link>
            </div>
          </div>
        </div>

        <aside class="corr-calendar-agenda" aria-labelledby="calendar-agenda-heading">
          <h2 id="calendar-agenda-heading">
            {if @selected_date, do: Calendar.strftime(@selected_date, "%B %-d"), else: "Coming up"}
          </h2>
          <.link
            :if={@selected_date}
            patch={month_path(@today, @query, @include_cancelled, @include_hidden)}
            class="corr-calendar-all-upcoming"
          >All upcoming dates</.link>
          <p :if={@agenda == []} class="corr-calendar-empty">
            <%= if @selected_date do %>
              Nothing planned for this day.
            <% else %>
              No upcoming events.
              <.link patch={~p"/correspondence/calendar/import"}>Import events</.link>
            <% end %>
          </p>
          <section :for={{date, events} <- @agenda} class="corr-calendar-agenda-day">
            <h3>{Calendar.strftime(date, "%A, %B %-d")}</h3>
            <article
              :for={event <- events}
              class={"corr-calendar-event status-#{value(event, :status) || "scheduled"}"}
            >
              <p :if={event_range(event)} class="corr-calendar-event-range">{event_range(event)}</p>
              <span class="corr-calendar-event-time">{event_time(event)}</span>
              <span :if={value(event, :recurrence_label)} class="corr-calendar-recurrence">{value(
                event,
                :recurrence_label
              )}</span>
              <h4>{value(event, :title)}</h4>
              <p :if={value(event, :category)} class="corr-calendar-category">
                {category_label(value(event, :category))}
              </p>
              <p :if={value(event, :timezone)} class="corr-calendar-timezone">
                {value(event, :timezone)}
              </p>
              <p :if={value(event, :venue)} class="corr-calendar-venue">
                {value(event, :venue)}<span :if={value(event, :address)}> · {value(event, :address)}</span>
              </p>
              <p :if={value(event, :status) == "cancelled"} class="corr-calendar-cancelled-label">
                Cancelled
              </p>
              <p :if={value(event, :notes)} class="corr-calendar-notes">{value(event, :notes)}</p>
              <a
                :if={safe_url(value(event, :url))}
                href={safe_url(value(event, :url))}
                target="_blank"
                rel="noopener noreferrer"
              >Event details ↗</a>
              <div class="corr-calendar-event-actions">
                <.link patch={~p"/correspondence/calendar/events/#{value(event, :id)}/edit"}>Edit</.link>
                <button
                  :if={!truthy?(value(event, :hidden))}
                  type="button"
                  phx-click="hide_calendar_event"
                  phx-value-id={value(event, :id)}
                  phx-value-date={occurrence_date(event)}
                >Hide {if recurring?(event), do: "this date", else: "event"}</button>
                <button
                  :if={!truthy?(value(event, :hidden)) && recurring?(event)}
                  type="button"
                  phx-click="hide_calendar_series"
                  phx-value-id={value(event, :id)}
                >Hide series</button>
                <button
                  :if={truthy?(value(event, :hidden)) && truthy?(value(event, :series_hidden))}
                  type="button"
                  phx-click="restore_calendar_series"
                  phx-value-id={value(event, :id)}
                >{if recurring?(event), do: "Show series", else: "Show event"}</button>
                <button
                  :if={truthy?(value(event, :hidden)) && !truthy?(value(event, :series_hidden))}
                  type="button"
                  phx-click="restore_calendar_event"
                  phx-value-id={value(event, :id)}
                  phx-value-date={occurrence_date(event)}
                >Restore this date</button>
              </div>
            </article>
          </section>
          <p :if={@agenda_more?} class="corr-calendar-more-occurrences">
            Showing the next 40 occurrences.
          </p>
        </aside>
      </div>
    </section>
    """
  end

  defp agenda(events, today, selected_date) do
    sorted =
      events
      |> Enum.filter(fn event ->
        date = event_date(value(event, :date))
        finish = event_date(value(event, :end_date)) || date

        if selected_date,
          do:
            date && Date.compare(selected_date, date) != :lt &&
              Date.compare(selected_date, finish) != :gt,
          else: date && Date.compare(finish, today) != :lt
      end)
      |> Enum.sort_by(fn event ->
        date = event_date(value(event, :date))
        {Date.to_gregorian_days(date), value(event, :start_time) || "", value(event, :title)}
      end)

    more? = length(sorted) > 40

    agenda =
      sorted
      |> Enum.take(40)
      |> Enum.group_by(fn event -> selected_date || event_date(value(event, :date)) end)
      |> Enum.sort_by(&elem(&1, 0), Date)

    {agenda, more?}
  end

  defp events_on(events, date) do
    Enum.filter(events, fn event ->
      start = event_date(value(event, :date))
      finish = event_date(value(event, :end_date)) || start
      start && Date.compare(date, start) != :lt && Date.compare(date, finish) != :gt
    end)
  end

  defp event_date(%Date{} = date), do: date

  defp event_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp event_date(_), do: nil

  defp event_time(event) do
    start = StillWeb.CalendarTime.format(value(event, :start_time))
    finish = StillWeb.CalendarTime.format(value(event, :end_time))

    cond do
      start && finish -> "#{start}–#{finish}"
      start -> start
      true -> "Time not provided"
    end
  end

  defp event_date_label(event) do
    start = event_date(value(event, :date))
    finish = event_date(value(event, :end_date))

    if start && finish && Date.compare(start, finish) != :eq do
      "#{Calendar.strftime(start, "%b %-d, %Y")}–#{Calendar.strftime(finish, "%b %-d, %Y")}"
    else
      if start, do: Calendar.strftime(start, "%b %-d, %Y"), else: "Date not provided"
    end
  end

  defp date_sort_key(event) do
    case event_date(value(event, :date)) do
      %Date{} = date -> {0, Date.to_gregorian_days(date), value(event, :start_time) || ""}
      nil -> {1, 0, ""}
    end
  end

  defp event_before_today?(event, today) do
    finish = event_date(value(event, :end_date)) || event_date(value(event, :date))
    finish && Date.compare(finish, today) == :lt
  end

  defp occurrence_date(event),
    do: event_date(value(event, :date)) |> then(&if(&1, do: Date.to_iso8601(&1), else: ""))

  defp recurring?(event), do: not is_nil(value(event, :recurrence))

  defp truthy?(value), do: value in [true, "true", 1, "1"]

  defp event_range(event) do
    start = event_date(value(event, :date))
    finish = event_date(value(event, :end_date))

    if start && finish && Date.compare(start, finish) != :eq do
      "#{Calendar.strftime(start, "%b %-d")}–#{Calendar.strftime(finish, "%b %-d")}"
    end
  end

  defp day_classes(date, month, today, selected_date) do
    [
      "corr-calendar-day",
      if(date.month != month.month, do: "is-outside"),
      if(date == today, do: "is-today"),
      if(date == selected_date, do: "is-selected")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp month_path(date, query, cancelled, hidden),
    do: path("month", Date.to_iso8601(date) |> String.slice(0, 7), query, cancelled, hidden)

  defp date_path(date, query, cancelled, hidden),
    do: path("date", Date.to_iso8601(date), query, cancelled, hidden)

  defp view_path(view, month, selected_date, query, cancelled, hidden, range, page) do
    params = %{
      "month" => Date.to_iso8601(month) |> String.slice(0, 7),
      "q" => query,
      "view" => view
    }

    params =
      if selected_date, do: Map.put(params, "date", Date.to_iso8601(selected_date)), else: params

    params = if cancelled, do: Map.put(params, "cancelled", "true"), else: params
    params = if hidden, do: Map.put(params, "hidden", "true"), else: params
    params = if range == "all", do: Map.put(params, "range", "all"), else: params

    params =
      if normalize_page(page) > 1, do: Map.put(params, "page", normalize_page(page)), else: params

    ~p"/correspondence/calendar?#{params}"
  end

  defp normalize_page(page) when is_integer(page) and page > 0, do: page
  defp normalize_page(_), do: 1

  defp path(key, value, query, cancelled, hidden) do
    params = %{"month" => String.slice(value, 0, 7), key => value, "q" => query}
    params = if cancelled, do: Map.put(params, "cancelled", "true"), else: params
    params = if hidden, do: Map.put(params, "hidden", "true"), else: params
    ~p"/correspondence/calendar?#{params}"
  end

  defp safe_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp safe_url(_), do: nil

  defp category_label("reading"), do: "Reading"
  defp category_label("workshop"), do: "Workshop"
  defp category_label("deadline"), do: "Deadline"
  defp category_label("other"), do: "Other"
  defp category_label(category), do: category

  defp matches_query?(_event, query) when query in [nil, ""], do: true

  defp matches_query?(event, query) do
    term = String.downcase(String.trim(query))
    fields = [:title, :venue, :address, :notes, :category]

    Enum.any?(fields, fn field ->
      case value(event, field) do
        text when is_binary(text) -> String.contains?(String.downcase(text), term)
        _ -> false
      end
    end)
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_, _), do: nil
end
