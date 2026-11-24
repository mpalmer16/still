defmodule StillWeb.CorrespondenceCalendar do
  @moduledoc "Calendar views for events, funding dates, and journal reading periods."
  use StillWeb, :html

  alias StillWeb.CorrespondenceReadingPeriods

  attr :events, :list, default: []
  attr :tasks, :list, default: []
  attr :today, :any, required: true
  attr :month, :any, required: true
  attr :selected_date, :any, default: nil
  attr :query, :string, default: ""
  attr :include_cancelled, :boolean, default: false
  attr :include_hidden, :boolean, default: false
  attr :view, :string, default: "calendar"
  attr :range, :string, default: "upcoming"
  attr :page, :integer, default: 1
  attr :source, :string, default: "events"
  attr :nearby_windows, :boolean, default: false
  attr :reading_periods, :map, default: nil
  attr :reading_periods_problem, :string, default: nil
  attr :json_export, :string, default: nil
  attr :json_export_label, :string, default: nil

  def page(assigns) do
    month_start = Date.beginning_of_month(assigns.month)
    reading? = assigns.source == "reading"

    assigns =
      assign(assigns,
        month_start: month_start,
        previous_month: Date.add(month_start, -1),
        next_month: Date.add(month_start, 32) |> Date.beginning_of_month(),
        reading?: reading?,
        funding?: assigns.source == "funding",
        search_label: search_label(assigns.source),
        source_query: source_query(assigns.source, assigns.nearby_windows)
      )

    assigns = if reading?, do: assigns, else: assign_event_views(assigns)

    ~H"""
    <section
      id="correspondence-calendar"
      class="corr-calendar"
      data-view={if @reading?, do: "timeline", else: @view}
      data-source={@source}
      aria-labelledby="calendar-heading"
    >
      <header class="corr-calendar-heading">
        <.form
          for={%{}}
          id="calendar-filters"
          class="corr-calendar-toolbar"
          phx-change="filter_calendar"
          phx-submit="filter_calendar"
        >
          <h1 id="calendar-heading">Calendar</h1>
          <label class="corr-directory-search">
            <span class="sr-only">{@search_label}</span>
            <input
              type="search"
              name="calendar[q]"
              value={@query}
              placeholder={if @source == "events", do: "Search calendar", else: @search_label}
              phx-debounce="250"
              autocomplete="off"
            />
          </label>
          <label :if={@reading?} class="corr-reading-nearby">
            <input type="hidden" name="calendar[nearby_windows]" value="false" />
            <input
              type="checkbox"
              name="calendar[nearby_windows]"
              value="true"
              checked={@nearby_windows}
            /> Nearby only
          </label>
          <.link
            :if={@source == "events"}
            patch={~p"/correspondence/calendar/events/new"}
            class="corr-button corr-button-primary corr-calendar-new-event"
          >Add event</.link>
          <details class="corr-popover corr-calendar-actions">
            <summary aria-label="Calendar menu">
              Menu
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
                <path d="m6 9 6 6 6-6" />
              </svg>
            </summary>
            <div class="corr-popover-panel">
              <%= if @reading? do %>
                <button
                  type="button"
                  class="corr-menu-action"
                  phx-click="export_reading_periods"
                  phx-value-scope="unconfirmed"
                >
                  Export dates to confirm
                </button>
                <button
                  type="button"
                  class="corr-menu-action"
                  phx-click="export_reading_periods"
                  phx-value-scope="all"
                >
                  Export all reading periods
                </button>
              <% else %>
                <.link :if={@funding?} patch={~p"/correspondence/funding"}>Open Funding</.link>
                <.link :if={@funding?} patch={~p"/correspondence/funding/import"}>Import Funding</.link>
                <.link :if={!@funding?} patch={~p"/correspondence/calendar/import"}>Import calendar events</.link>
                <button
                  :if={!@funding?}
                  type="button"
                  class="corr-menu-action"
                  phx-click="export_json"
                >Export JSON</button>
                <div :if={!@funding? || @view == "list"} class="corr-calendar-menu-filters">
                  <label :if={!@funding?} class="corr-calendar-cancelled">
                    <input
                      type="checkbox"
                      name="calendar[cancelled]"
                      value="true"
                      checked={@include_cancelled}
                    /> Include cancelled
                  </label>
                  <label :if={!@funding?} class="corr-calendar-hidden">
                    <input
                      type="checkbox"
                      name="calendar[hidden]"
                      value="true"
                      checked={@include_hidden}
                    /> Include hidden
                  </label>
                  <label :if={@view == "list"} class="corr-calendar-range">
                    <span>Show</span>
                    <select name="calendar[range]">
                      <option value="upcoming" selected={@range != "all"}>Upcoming</option>
                      <option value="all" selected={@range == "all"}>
                        {if @funding?, do: "All funding dates", else: "All events"}
                      </option>
                    </select>
                  </label>
                </div>
              <% end %>
            </div>
          </details>
          <div class="corr-calendar-navigation">
            <nav class="corr-calendar-source-switch" aria-label="Calendar content">
              <.link
                :for={
                  {source, label} <- [
                    {"events", "Events"},
                    {"funding", "Funding"},
                    {"reading", "Reading periods"}
                  ]
                }
                patch={source_path(source, @month_start, @selected_date, @view)}
                aria-current={if @source == source, do: "page"}
              >{label}</.link>
            </nav>
            <div class="corr-calendar-layout-controls">
              <nav :if={!@reading?} class="corr-calendar-view-switch" aria-label="Calendar layout">
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
                      @page,
                      @source_query
                    )
                  }
                >Month</.link>
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
                      @page,
                      @source_query
                    )
                  }
                >List</.link>
              </nav>
              <nav
                :if={@reading? || @view == "calendar"}
                class="corr-calendar-month-nav"
                aria-label="Calendar month"
              >
                <.link
                  patch={
                    month_path(
                      @previous_month,
                      @query,
                      @include_cancelled,
                      @include_hidden,
                      @source_query
                    )
                  }
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
                  patch={
                    month_path(
                      @next_month,
                      @query,
                      @include_cancelled,
                      @include_hidden,
                      @source_query
                    )
                  }
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
                  patch={
                    if @reading?,
                      do:
                        month_path(@today, @query, @include_cancelled, @include_hidden, @source_query),
                      else:
                        date_path(@today, @query, @include_cancelled, @include_hidden, @source_query)
                  }
                  class="corr-text-link"
                >Today</.link>
              </nav>
            </div>
          </div>
        </.form>
      </header>

      <StillWeb.CorrespondenceExport.panel
        json={@json_export}
        label={@json_export_label || "Calendar events"}
        detail={
          if @reading?,
            do:
              "The export uses all active journals in this scope, regardless of the month, search, or Nearby filter."
        }
      />
      <CorrespondenceReadingPeriods.timeline
        :if={@reading?}
        model={@reading_periods}
        problem={@reading_periods_problem}
        searching={@query != ""}
      />
      <div :if={!@reading? && @view == "list"} class="corr-calendar-list-view">
        <p :if={!@funding?} class="corr-meta">
          One row per event or series. Recurring events show their next visible date.
        </p>
        <div
          class="corr-table-scroll"
          role="region"
          aria-label={if @funding?, do: "Funding dates table", else: "Calendar events table"}
          tabindex="0"
        >
          <table id="calendar-events-table" class="corr-table corr-calendar-events-table">
            <thead>
              <tr>
                <th scope="col">Date</th><th scope="col">
                  {if @funding?, do: "Funding", else: "Event"}
                </th><th scope="col">Time</th><th scope="col">
                  {if @funding?, do: "Funder", else: "Location"}
                </th><th scope="col">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={event <- @list_events}
                class={[
                  truthy?(value(event, :hidden)) && "is-hidden",
                  value(event, :highlighted) && "is-highlighted"
                ]}
              >
                <td>{event_date_label(event)}</td>
                <td>
                  <.link
                    patch={
                      date_path(
                        event_date(value(event, :date)),
                        @query,
                        @include_cancelled,
                        @include_hidden,
                        @source_query
                      )
                    }
                    class="corr-calendar-list-title"
                  >{value(event, :title)}</.link>
                  <span :if={value(event, :recurrence_label)} class="corr-calendar-recurrence">{value(
                    event,
                    :recurrence_label
                  )}</span>
                  <span
                    :if={value(event, :status) == "cancelled"}
                    class="corr-calendar-cancelled-label"
                  >Cancelled</span>
                  <span :if={truthy?(value(event, :hidden))} class="corr-calendar-hidden-label">Hidden</span>
                  <span :if={value(event, :highlighted)} class="corr-funding-highlight">Highlighted</span>
                </td>
                <td>
                  {event_time(event)}<span
                    :if={value(event, :timezone)}
                    class="corr-calendar-timezone"
                  >{value(
                    event,
                    :timezone
                  )}</span>
                </td>
                <td>
                  {[value(event, :venue), value(event, :address)]
                  |> Enum.reject(&(&1 in [nil, ""]))
                  |> Enum.join(" · ")}
                </td>
                <td :if={value(event, :funding_id)} class="corr-calendar-event-actions">
                  <.link patch={~p"/correspondence/funding/#{value(event, :funding_id)}"}>
                    View funding
                  </.link>
                </td>
                <td :if={!value(event, :funding_id)} class="corr-calendar-event-actions">
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
        </div>
        <p :if={@list_events == []} class="corr-calendar-empty">
          <%= if @funding? do %>
            No funding dates in this view. <.link patch={~p"/correspondence/funding"}>Open Funding</.link>.
          <% else %>
            No events in this view.
            <.link patch={~p"/correspondence/calendar/events/new"}>Add an event</.link>
            or <.link patch={~p"/correspondence/calendar/import"}>import events</.link>.
          <% end %>
        </p>
        <nav
          :if={@list_page_count > 1}
          class="corr-pagination corr-calendar-pagination"
          aria-label="Event list pages"
        >
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
                @list_page - 1,
                @source_query
              )
            }
          >Previous</.link>
          <span>Page {@list_page} of {@list_page_count} · {@list_total} {if @funding?,
            do: "dates",
            else: "events"}</span>
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
                @list_page + 1,
                @source_query
              )
            }
          >Next</.link>
        </nav>
        <p :if={@range != "all" && !@funding?} class="corr-calendar-range-note">
          Upcoming recurring dates are shown within the next year. Choose All events to include earlier events.
        </p>
        <section
          :if={!@funding? && @list_tasks != []}
          class="corr-calendar-tasks"
          aria-labelledby="calendar-tasks-heading"
        >
          <h2 id="calendar-tasks-heading">From Next</h2>
          <ul>
            <li :for={task <- @list_tasks}>
              <time datetime={value(task, :date)}>{task_date_label(task)}</time>
              <.link navigate={~p"/correspondence/next?#{%{edit: value(task, :id)}}"}>{value(
                task,
                :title
              )}</.link>
              <span class="corr-calendar-task-kind">{task_kind_label(task)}</span>
            </li>
          </ul>
        </section>
      </div>

      <div :if={!@reading? && @view == "calendar"} class="corr-calendar-layout">
        <div class="corr-calendar-grid" role="group" aria-label="Month dates">
          <div
            :for={weekday <- ~w(Sun Mon Tue Wed Thu Fri Sat)}
            class="corr-calendar-weekday"
          >
            {weekday}
          </div>
          <div
            :for={date <- @dates}
            class={day_classes(date, @month_start, @today, @selected_date)}
            data-date={Date.to_iso8601(date)}
          >
            <% day_tasks = Map.get(@tasks_by_day, date, [])
            day_events = events_on(@events, date)
            previews = if day_tasks != [] && day_events != [], do: 1, else: 2
            more = max(length(day_tasks) - previews, 0) + max(length(day_events) - previews, 0)
            entry_count = length(day_events) + length(day_tasks)
            date_label = Calendar.strftime(date, "%A, %B %-d, %Y")
            path = date_path(date, @query, @include_cancelled, @include_hidden, @source_query) %>
            <div class="corr-calendar-day-heading">
              <.link
                patch={path}
                class="corr-calendar-day-link"
                aria-label={
                  case entry_count do
                    0 -> date_label
                    1 -> "#{date_label}, 1 entry"
                    _ -> "#{date_label}, #{entry_count} entries"
                  end
                }
                aria-current={if date == (@selected_date || @today), do: "date"}
              >
                {date.day}
                <span
                  :if={entry_count > 0}
                  class="corr-calendar-day-dot"
                  aria-hidden="true"
                ></span>
              </.link>
              <.link
                :if={more > 0}
                patch={path}
                class="corr-calendar-more"
                aria-label={"#{more} more on #{Calendar.strftime(date, "%B %-d")}"}
              >+{more}</.link>
            </div>
            <div class="corr-calendar-day-events">
              <.link
                :for={event <- Enum.take(day_events, previews)}
                patch={path}
                title={value(event, :title)}
                class={[
                  "corr-calendar-day-event status-#{value(event, :status) || "scheduled"}",
                  value(event, :highlighted) && "is-highlighted"
                ]}
              >{value(event, :title)}</.link>
              <.link
                :for={task <- Enum.take(day_tasks, previews)}
                navigate={~p"/correspondence/next?#{%{edit: value(task, :id)}}"}
                title={value(task, :title)}
                class={["corr-calendar-task-chip", "kind-#{value(task, :kind)}"]}
              >{value(task, :title)}</.link>
            </div>
          </div>
        </div>

        <aside class="corr-calendar-agenda" aria-labelledby="calendar-agenda-heading">
          <header class={["corr-calendar-agenda-heading", @selected_date && "has-date"]}>
            <h2 id="calendar-agenda-heading" aria-live="polite">
              {if @selected_date,
                do: Calendar.strftime(@selected_date, "%A, %B %-d"),
                else: "Coming up"}
            </h2>
            <nav :if={@selected_date} class="corr-calendar-day-steps" aria-label="Change selected day">
              <.link
                :for={{step, label, arrow} <- [{-1, "Previous day", "←"}, {1, "Next day", "→"}]}
                patch={
                  date_path(
                    Date.add(@selected_date, step),
                    @query,
                    @include_cancelled,
                    @include_hidden,
                    @source_query
                  )
                }
                aria-label={label}
              >{arrow}</.link>
            </nav>
            <.link
              :if={@selected_date}
              patch={month_path(@today, @query, @include_cancelled, @include_hidden, @source_query)}
              class="corr-calendar-all-upcoming"
            >All upcoming dates</.link>
            <.link
              :if={@selected_date && !@funding?}
              navigate={~p"/correspondence/next?#{%{on: Date.to_iso8601(@selected_date)}}"}
              class="corr-calendar-add-task"
            >+ Add to Next</.link>
          </header>
          <div
            id="calendar-agenda-events"
            class="corr-calendar-agenda-events"
            tabindex="0"
            role="region"
            aria-label={if @funding?, do: "Funding dates", else: "Calendar events"}
          >
            <p :if={@agenda == []} class="corr-calendar-empty">
              <%= if @selected_date do %>
                {if @funding?,
                  do: "No funding dates on this day.",
                  else: "No events on this day."}
              <% else %>
                {if @funding?, do: "No upcoming funding dates.", else: "No upcoming events."}
              <% end %>
              <%= if !@selected_date && @funding? do %>
                <.link patch={~p"/correspondence/funding"}>Open Funding</.link>
              <% else %>
                <.link :if={!@selected_date} patch={~p"/correspondence/calendar/import"}>Import events</.link>
              <% end %>
            </p>
            <section :for={{date, events} <- @agenda} class="corr-calendar-agenda-day">
              <h3 :if={!@selected_date}>{Calendar.strftime(date, "%A, %B %-d")}</h3>
              <article
                :for={event <- events}
                class={[
                  "corr-calendar-event status-#{value(event, :status) || "scheduled"}",
                  value(event, :highlighted) && "is-highlighted"
                ]}
              >
                <p :if={event_range(event)} class="corr-calendar-event-range">{event_range(event)}</p>
                <span class="corr-calendar-event-time">{event_time(event)}</span>
                <span :if={value(event, :recurrence_label)} class="corr-calendar-recurrence">{value(
                  event,
                  :recurrence_label
                )}</span>
                <h4>{value(event, :title)}</h4>
                <span :if={value(event, :highlighted)} class="corr-funding-highlight">Highlighted</span>
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
                <.link
                  :if={value(event, :funding_id)}
                  patch={~p"/correspondence/funding/#{value(event, :funding_id)}"}
                >View funding</.link>
                <div :if={!value(event, :funding_id)} class="corr-calendar-event-actions">
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
            <section
              :if={!@funding? && (@selected_date || @agenda_tasks != [])}
              class="corr-calendar-day-tasks"
              aria-labelledby="calendar-day-tasks-heading"
            >
              <h3 id="calendar-day-tasks-heading">From Next</h3>
              <p :if={@agenda_tasks == []} class="corr-calendar-empty">Nothing due or planned.</p>
              <ul :if={@agenda_tasks != []}>
                <li :for={task <- @agenda_tasks}>
                  <time :if={!@selected_date} datetime={value(task, :date)}>{task_date_label(task)}</time>
                  <.link navigate={~p"/correspondence/next?#{%{edit: value(task, :id)}}"}>{value(
                    task,
                    :title
                  )}</.link>
                  <span class={["corr-calendar-task-kind", "kind-#{value(task, :kind)}"]}>{task_kind_label(
                    task
                  )}</span>
                </li>
              </ul>
            </section>
          </div>
        </aside>
      </div>
    </section>
    """
  end

  defp search_label("reading"), do: "Search reading periods"
  defp search_label("funding"), do: "Search funding dates"
  defp search_label(_), do: "Search events and items from Next"

  defp assign_event_views(assigns) do
    grid_start = Date.add(assigns.month_start, 1 - Date.day_of_week(assigns.month_start, :sunday))
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

    task_query = String.downcase(String.trim(assigns.query || ""))

    tasks =
      assigns.tasks
      |> Enum.filter(fn task ->
        valid_task?(task) &&
          String.contains?(String.downcase(value(task, :title)), task_query)
      end)
      |> Enum.sort_by(fn task ->
        {value(task, :date), task_kind_label(task), value(task, :title)}
      end)

    list_tasks =
      Enum.filter(tasks, fn task ->
        date = event_date(value(task, :date))
        assigns.range == "all" || Date.compare(date, assigns.today) != :lt
      end)

    tasks_by_day = Enum.group_by(tasks, &event_date(value(&1, :date)))

    agenda_tasks =
      if assigns.selected_date,
        do: Map.get(tasks_by_day, assigns.selected_date, []),
        else:
          tasks
          |> Enum.drop_while(&Date.before?(event_date(value(&1, :date)), assigns.today))
          |> Enum.take(5)

    list_page_count = max(1, ceil(length(matching_list_events) / 40))
    list_page = assigns.page |> normalize_page() |> min(list_page_count)
    list_events = Enum.slice(matching_list_events, (list_page - 1) * 40, 40)
    {agenda, agenda_more?} = agenda(events, assigns.today, assigns.selected_date)

    assign(assigns,
      events: events,
      tasks_by_day: tasks_by_day,
      list_tasks: list_tasks,
      agenda_tasks: agenda_tasks,
      list_events: list_events,
      list_page: list_page,
      list_page_count: list_page_count,
      list_total: length(matching_list_events),
      dates: dates,
      agenda: agenda,
      agenda_more?: agenda_more?
    )
  end

  defp source_query("reading", true), do: %{"show" => "reading", "nearby_windows" => "true"}
  defp source_query("events", _), do: %{}
  defp source_query(source, _), do: %{"show" => source}

  defp source_path(source, month, selected_date, view) do
    view_path(
      if(source == "reading", do: "calendar", else: view),
      month,
      selected_date,
      "",
      false,
      false,
      "upcoming",
      1,
      source_query(source, false)
    )
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

  defp valid_task?(task) do
    is_binary(value(task, :id)) and is_binary(value(task, :title)) and
      is_binary(value(task, :date)) and
      value(task, :kind) in ["planned", "due", "planned_and_due"] and
      not is_nil(event_date(value(task, :date)))
  end

  defp task_date_label(task) do
    case event_date(value(task, :date)) do
      %Date{} = date -> Calendar.strftime(date, "%a, %b %-d, %Y")
      _ -> "Date not provided"
    end
  end

  defp task_kind_label(task) do
    case value(task, :kind) do
      "due" -> "Due"
      "planned_and_due" -> "Planned and due"
      _ -> "Planned"
    end
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

  defp month_path(date, query, cancelled, hidden, windows),
    do:
      path(
        "month",
        Date.to_iso8601(date) |> String.slice(0, 7),
        query,
        cancelled,
        hidden,
        windows
      )

  defp date_path(date, query, cancelled, hidden, windows),
    do: path("date", Date.to_iso8601(date), query, cancelled, hidden, windows)

  defp view_path(view, month, selected_date, query, cancelled, hidden, range, page, windows) do
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

    ~p"/correspondence/calendar?#{Map.merge(params, windows)}"
  end

  defp normalize_page(page) when is_integer(page) and page > 0, do: page
  defp normalize_page(_), do: 1

  defp path(key, value, query, cancelled, hidden, windows) do
    params = %{"month" => String.slice(value, 0, 7), key => value, "q" => query}
    params = if cancelled, do: Map.put(params, "cancelled", "true"), else: params
    params = if hidden, do: Map.put(params, "hidden", "true"), else: params
    ~p"/correspondence/calendar?#{Map.merge(params, windows)}"
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
  defp category_label("funding_opening"), do: "Funding opening"
  defp category_label("funding_deadline"), do: "Funding deadline"
  defp category_label("other"), do: "Other"
  defp category_label(category), do: category

  defp matches_query?(_event, query) when query in [nil, ""], do: true

  defp matches_query?(event, query) do
    term = String.downcase(String.trim(query))
    fields = [:title, :venue, :address, :notes]

    texts = [category_label(value(event, :category)) | Enum.map(fields, &value(event, &1))]
    Enum.any?(texts, &(is_binary(&1) && String.contains?(String.downcase(&1), term)))
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_, _), do: nil
end
