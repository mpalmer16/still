defmodule StillWeb.CalendarImport do
  @moduledoc "A reviewed import of local calendar events."
  use StillWeb, :html
  attr :upload, :any, required: true
  attr :plan, :any, default: nil
  attr :result, :any, default: nil

  @fields [
    {"title", "Title"},
    {"external_id", "External ID"},
    {"date", "Date"},
    {"start_time", "Starts"},
    {"end_date", "Through"},
    {"end_time", "Ends"},
    {"timezone", "Time zone"},
    {"venue", "Venue"},
    {"address", "Address"},
    {"category", "Category"},
    {"status", "Status"},
    {"url", "Link"},
    {"notes", "Notes"}
  ]

  def page(assigns) do
    assigns =
      assigns
      |> assign(:fields, @fields)

    ~H"""
    <section id="calendar-import" class="corr-place-import" aria-labelledby="calendar-import-heading">
      <.link patch={~p"/correspondence/calendar"} class="editorial-place-back">← Calendar</.link>
      <h1 id="calendar-import-heading">Import calendar events</h1>
      <p>
        Choose a JSON file and review the proposed additions and changes before importing.
      </p>
      <form
        id="calendar-import-form"
        phx-change="validate_calendar_upload"
        phx-submit="preview_calendar_import"
      >
        <label for={@upload.ref}>Calendar JSON file</label>
        <.live_file_input upload={@upload} />
        <p class="corr-meta">One .json file, up to 1 MB and 200 events.</p>
        <p :for={error <- upload_errors(@upload)} role="alert">{upload_error(error)}</p>
        <p :for={entry <- @upload.entries}>
          {entry.client_name}
          <span :for={error <- upload_errors(@upload, entry)} role="alert">{upload_error(error)}</span>
        </p>
        <button type="submit" class="corr-button" phx-disable-with="Reading…">Review events →</button>
      </form>

      <section :if={@plan} id="calendar-import-preview" class="corr-import-review">
        <h2>
          {length(@plan.new)} new · {length(@plan.updated)} changed · {length(@plan.unchanged)} unchanged
        </h2>
        <p>Unchanged events will be skipped. Review the complete set before committing it.</p>
        <h3 :if={@plan.new != []}>New events</h3>
        <ul>
          <li :for={event <- @plan.new}>
            <strong>{event.attrs["title"]}</strong>
            <.event_details attrs={event.attrs} fields={@fields} />
          </li>
        </ul>
        <h3 :if={@plan.updated != []}>Proposed changes</h3>
        <ul>
          <li :for={event <- @plan.updated}>
            <strong>{event.attrs["title"]}</strong>
            <h4>Previously saved</h4>
            <.event_details attrs={event.previous} fields={@fields} />
            <h4>Will become</h4>
            <.event_details attrs={event.attrs} fields={@fields} />
          </li>
        </ul>
        <h3 :if={@plan.unchanged != []}>Unchanged and skipped</h3>
        <ul>
          <li :for={event <- @plan.unchanged}>
            <strong>{event.attrs["title"]}</strong>
            <.event_details attrs={event.attrs} fields={@fields} />
          </li>
        </ul>
        <button
          :if={@plan.new != [] or @plan.updated != []}
          id="confirm-calendar-import"
          type="button"
          phx-click="import_calendar"
          class="corr-button"
          phx-disable-with="Importing…"
        >Import {length(@plan.new) + length(@plan.updated)} events →</button>
      </section>

      <section :if={@result} id="calendar-import-result" aria-live="polite" class="corr-import-review">
        <p :if={@result[:error]} role="alert">{@result[:error]}</p>
        <p :if={!@result[:error]}>
          Added {@result.added}, updated {@result.updated}, skipped {@result.unchanged} unchanged events.
        </p>
        <.link patch={~p"/correspondence/calendar"} class="corr-text-link">View calendar →</.link>
      </section>

      <details class="corr-import-example" open>
        <summary>JSON fields</summary>
        <p>
          The JSON Schema defines the complete format and validation rules. Download <a
            href="/correspondence/calendar/schema"
            download
            class="corr-text-link"
          >calendar-import.schema.json</a>.
          A calendar file is an array of event objects. Required fields are <code>external_id</code>, <code>title</code>, and <code>date</code>; every event has a stable external ID so another
          import can propose an update instead of creating a duplicate.
        </p>
        <table>
          <thead>
            <tr>
              <th>Field</th><th>Type</th><th>Meaning</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <th>external_id</th><td>string, required</td><td>
                Stable source identifier, up to 200 characters. Reuse it to update the same event.
              </td>
            </tr>
            <tr>
              <th>title</th><td>string, required</td><td>Event title, up to 300 characters.</td>
            </tr>
            <tr>
              <th>date</th><td>date string, required</td><td>YYYY-MM-DD anchor date.</td>
            </tr>
            <tr>
              <th>start_time</th><td>time string</td><td>
                Optional 24-hour HH:MM. Omission means unconfirmed, not all-day.
              </td>
            </tr>
            <tr>
              <th>end_time</th><td>time string</td><td>
                Optional 24-hour HH:MM; requires start_time and cannot be earlier on the same date.
              </td>
            </tr>
            <tr>
              <th>end_date</th><td>date string</td><td>
                Optional inclusive YYYY-MM-DD date on or after date; events can span up to 366 days.
              </td>
            </tr>
            <tr>
              <th>timezone</th><td>string</td><td>
                Optional display label, such as America/Chicago.
              </td>
            </tr>
            <tr>
              <th>venue</th><td>string</td><td>Optional venue name.</td>
            </tr>
            <tr>
              <th>address</th><td>string</td><td>Optional venue address.</td>
            </tr>
            <tr>
              <th>url</th><td>HTTP(S) URL string</td><td>Optional link. Still does not fetch it.</td>
            </tr>
            <tr>
              <th>notes</th><td>string</td><td>Optional private notes, up to 10,000 characters.</td>
            </tr>
            <tr>
              <th>category</th><td>enum string</td><td>
                Optional reading, workshop, deadline, or other (default other).
              </td>
            </tr>
            <tr>
              <th>status</th><td>enum string</td><td>
                Optional scheduled or cancelled (default scheduled).
              </td>
            </tr>
            <tr>
              <th>recurrence</th><td>object or null</td><td>
                Optional repeat rule; omit or use null for a one-time event.
              </td>
            </tr>
            <tr>
              <th>recurrence.frequency</th><td>enum string, required in rule</td><td>
                daily, weekly, monthly, or yearly.
              </td>
            </tr>
            <tr>
              <th>recurrence.interval</th><td>integer</td><td>
                Optional 1–100 repeat interval (default 1).
              </td>
            </tr>
            <tr>
              <th>recurrence.until</th><td>date string</td><td>
                Optional inclusive stop date, on or after the event date.
              </td>
            </tr>
            <tr>
              <th>recurrence.weekday</th><td>enum string</td><td>
                Optional monday through sunday; pair with week_of_month for a monthly weekday pattern.
              </td>
            </tr>
            <tr>
              <th>recurrence.week_of_month</th><td>integer</td><td>
                Optional -1 (last), or 1–5; pair with weekday. Monthly only; event date must match.
              </td>
            </tr>
            <tr>
              <th>recurrence.excluded_dates</th><td>array of date strings</td><td>
                Optional unique YYYY-MM-DD dates to skip, up to 500.
              </td>
            </tr>
          </tbody>
        </table>
        <p>
          Reusing an <code>external_id</code> proposes an update to that event, never a duplicate.
          Still previews changed values beside the saved values and skips unchanged events. The
          reviewed additions and updates are committed together.
        </p>
      </details>
    </section>
    """
  end

  attr :attrs, :map, required: true
  attr :fields, :list, required: true

  defp event_details(assigns) do
    ~H"""
    <dl>
      <div :for={{key, label} <- @fields}>
        <dt>{label}</dt>
        <dd>{display_value(key, @attrs[key])}</dd>
      </div>
      <div>
        <dt>Recurrence</dt>
        <dd :if={@attrs["recurrence"] in [nil, ""]}>Not set</dd>
        <dd :if={@attrs["recurrence"] not in [nil, ""]}>
          <code>{Jason.encode!(@attrs["recurrence"], pretty: true)}</code>
        </dd>
      </div>
    </dl>
    """
  end

  defp display_value(_key, value) when value in [nil, ""], do: "Not set"

  defp display_value(key, value) when key in ["start_time", "end_time"],
    do: StillWeb.CalendarTime.format(value)

  defp display_value(_key, value), do: value

  defp upload_error(:too_large), do: "The file is too large. Choose a file no larger than 1 MB."
  defp upload_error(:not_accepted), do: "Choose a .json file."
  defp upload_error(:too_many_files), do: "Choose one file at a time."
  defp upload_error(_), do: "The file could not be uploaded. Choose it again."
end
