defmodule StillWeb.CalendarEventEditor do
  @moduledoc "The local calendar event form."
  use StillWeb, :html

  attr :form, :map, required: true
  attr :event, :map, default: nil

  def page(assigns) do
    assigns = assign(assigns, :frequency, value(assigns.form, "repeat_frequency") || "none")

    ~H"""
    <section
      id="calendar-event-editor"
      class="corr-place-import"
      aria-labelledby="calendar-event-heading"
    >
      <.link patch={~p"/correspondence/calendar"} class="editorial-place-back">← Calendar</.link>
      <h1 id="calendar-event-heading">{if @event, do: "Edit event", else: "Add event"}</h1>
      <.form
        for={%{}}
        as={:event}
        id="calendar-event-form"
        phx-change="calendar_event_changed"
        phx-submit="save_calendar_event"
        class="editorial-place-form"
      >
        <label>Title<input name="event[title]" value={value(@form, "title")} required maxlength="300" /></label>
        <label>Date<input name="event[date]" type="date" value={value(@form, "date")} required /></label>
        <div>
          <label>Start time<input
            name="event[start_time]"
            type="time"
            value={value(@form, "start_time")}
          /></label>
          <p class="corr-meta">
            Leave blank when the time is unconfirmed.
          </p>
        </div>
        <label>End date<input name="event[end_date]" type="date" value={value(@form, "end_date")} /></label>
        <label>End time<input name="event[end_time]" type="time" value={value(@form, "end_time")} /></label>
        <label>Time zone label<input
          name="event[timezone]"
          value={value(@form, "timezone")}
          placeholder="America/Chicago"
          maxlength="500"
        /></label>
        <label>Venue<input name="event[venue]" value={value(@form, "venue")} maxlength="500" /></label>
        <label>Address<input name="event[address]" value={value(@form, "address")} maxlength="500" /></label>
        <label>Link<input
          name="event[url]"
          type="url"
          value={value(@form, "url")}
          placeholder="https://"
          maxlength="500"
        /></label>
        <label>
          Category
          <select name="event[category]">
            <option value="other" selected={value(@form, "category") in [nil, "", "other"]}>
              Other
            </option>
            <option value="reading" selected={value(@form, "category") == "reading"}>Reading</option>
            <option value="workshop" selected={value(@form, "category") == "workshop"}>
              Workshop
            </option>
            <option value="deadline" selected={value(@form, "category") == "deadline"}>
              Deadline
            </option>
          </select>
        </label>
        <label>
          Status
          <select name="event[status]">
            <option value="scheduled" selected={value(@form, "status") in [nil, "", "scheduled"]}>
              Scheduled
            </option>
            <option value="cancelled" selected={value(@form, "status") == "cancelled"}>
              Cancelled
            </option>
          </select>
        </label>
        <label class="is-wide">Notes<textarea name="event[notes]" rows="5" maxlength="10000">{value(@form, "notes")}</textarea></label>

        <fieldset class="is-wide">
          <legend>Repeat</legend>
          <label>
            Frequency
            <select name="event[repeat_frequency]">
              <option value="none" selected={@frequency == "none"}>Does not repeat</option>
              <option value="daily" selected={@frequency == "daily"}>Daily</option>
              <option value="weekly" selected={@frequency == "weekly"}>Weekly</option>
              <option value="monthly" selected={@frequency == "monthly"}>Monthly</option>
              <option value="yearly" selected={@frequency == "yearly"}>Yearly</option>
            </select>
          </label>
          <div :if={@frequency != "none"}>
            <label>Every<input
              name="event[repeat_interval]"
              type="number"
              min="1"
              max="100"
              value={value(@form, "repeat_interval") || "1"}
            /></label>
            <span>{case @frequency do
              "daily" -> "day(s)"
              "weekly" -> "week(s)"
              "monthly" -> "month(s)"
              _ -> "year(s)"
            end}</span>
            <label>Repeat through<input
              name="event[repeat_until]"
              type="date"
              value={value(@form, "repeat_until")}
            /></label>
            <label>Skip these dates<input
              name="event[repeat_excluded_dates]"
              value={value(@form, "repeat_excluded_dates")}
              placeholder="YYYY-MM-DD, YYYY-MM-DD"
            /></label>
            <p class="corr-meta">Enter excluded dates as comma-separated YYYY-MM-DD dates.</p>
          </div>
          <div :if={@frequency == "monthly"}>
            <label>
              Weekday
              <select name="event[repeat_weekday]">
                <option value="">Use the event date</option>
                <option
                  :for={day <- ~w(monday tuesday wednesday thursday friday saturday sunday)}
                  value={day}
                  selected={value(@form, "repeat_weekday") == day}
                >
                  {String.capitalize(day)}
                </option>
              </select>
            </label>
            <label>
              Week of month
              <select name="event[repeat_week_of_month]">
                <option value="">No weekday pattern</option>
                <option value="1" selected={value(@form, "repeat_week_of_month") == "1"}>
                  First
                </option>
                <option value="2" selected={value(@form, "repeat_week_of_month") == "2"}>
                  Second
                </option>
                <option value="3" selected={value(@form, "repeat_week_of_month") == "3"}>
                  Third
                </option>
                <option value="4" selected={value(@form, "repeat_week_of_month") == "4"}>
                  Fourth
                </option>
                <option value="5" selected={value(@form, "repeat_week_of_month") == "5"}>
                  Fifth
                </option>
                <option value="-1" selected={value(@form, "repeat_week_of_month") == "-1"}>
                  Last
                </option>
              </select>
            </label>
            <p class="corr-meta">
              Choose both a weekday and week to repeat by monthly pattern. The event date must match.
            </p>
          </div>
        </fieldset>

        <p :if={value(@form, "error")} class="corr-error" role="alert">{value(@form, "error")}</p>
        <div class="corr-button-row">
          <button type="submit" class="corr-button" phx-disable-with="Saving…">Save event</button>
          <.link patch={~p"/correspondence/calendar"} class="corr-text-link">Cancel</.link>
        </div>
      </.form>
    </section>
    """
  end

  defp value(form, key), do: Map.get(form, key) || Map.get(form, String.to_atom(key))
end
