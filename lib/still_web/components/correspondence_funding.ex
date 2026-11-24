defmodule StillWeb.CorrespondenceFunding do
  @moduledoc "Editorial components for browsing, editing, and importing funding opportunities."
  use StillWeb, :html

  alias Still.Correspondence.{Funding, FundingApplications, FundingDirectory, FundingImport}

  attr :opportunities, :list, required: true
  attr :filters, :map, default: %{}
  attr :today, :any, required: true
  attr :json_export, :string, default: nil

  def directory(assigns) do
    directory = FundingDirectory.build(assigns.opportunities, assigns.filters, assigns.today)
    assigns = assign(assigns, :directory, directory)

    ~H"""
    <section
      id="funding-directory"
      class="editorial-place-directory corr-directory"
      aria-labelledby="funding-heading"
    >
      <header class="corr-directory-heading">
        <h1 id="funding-heading">Funding</h1>
        <details class="corr-popover places-menu">
          <summary aria-label="Funding menu">
            Funding menu <span aria-hidden="true">⌄</span>
          </summary>
          <div class="corr-popover-panel">
            <.link patch={~p"/correspondence/funding/new"}>Add funding opportunity</.link>
            <.link patch={~p"/correspondence/funding/import"}>Import Funding</.link>
            <button type="button" class="corr-menu-action" phx-click="export_json">Export JSON</button>
          </div>
        </details>
      </header>
      <.funding_views current={:opportunities} />
      <div class="places-toolbar">
        <.form
          for={%{}}
          id="funding-filters"
          class="places-filters"
          phx-change="filter_funding"
          phx-submit="filter_funding"
        >
          <div class="places-search corr-directory-search">
            <label for="funding-query" class="sr-only">Search funding</label>
            <input
              id="funding-query"
              type="search"
              name="funding[q]"
              value={@directory.filters["q"]}
              placeholder="Search funding"
              phx-debounce="250"
              autocomplete="off"
            />
          </div>
          <label class="corr-meta" for="funding-deadline">Deadline</label>
          <select id="funding-deadline" name="funding[deadline]">
            <option
              :for={
                {label, value} <- [
                  {"All dates", "all"},
                  {"Upcoming", "upcoming"},
                  {"Past", "past"},
                  {"No deadline", "undated"}
                ]
              }
              value={value}
              selected={@directory.filters["deadline"] == value}
            >
              {label}
            </option>
          </select>
          <label class="corr-meta" for="funding-kind">Kind</label>
          <select id="funding-kind" name="funding[kind]">
            <option value="all" selected={@directory.filters["kind"] == "all"}>All kinds</option>
            <option
              :for={{label, value} <- Funding.kinds()}
              value={value}
              selected={@directory.filters["kind"] == value}
            >
              {label}
            </option>
          </select>
          <.link patch={~p"/correspondence/funding"} class="corr-text-link">Reset</.link>
        </.form>
        <p class="places-result-count corr-result-count" role="status" aria-live="polite">
          <%= if @directory.matched > 0 do %>
            {(@directory.page - 1) * @directory.per_page + 1}–{min(
              @directory.page * @directory.per_page,
              @directory.matched
            )} of {@directory.matched} opportunities
          <% else %>
            No opportunities match this view
          <% end %>
          <span> · {@directory.total} total</span>
        </p>
      </div>
      <StillWeb.CorrespondenceExport.panel json={@json_export} label="Funding" />
      <div
        :if={@directory.rows != []}
        class="places-table-scroll corr-table-scroll"
        role="region"
        aria-label="Funding opportunities"
        tabindex="0"
      >
        <table id="funding-table" class="places-table corr-table">
          <caption class="sr-only">Funding opportunities and their deadlines</caption>
          <thead>
            <tr>
              <th scope="col">Opportunity</th><th scope="col">Funder</th><th scope="col">Kind</th><th scope="col">
                Amount
              </th><th scope="col">Dates</th><th scope="col">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={opportunity <- @directory.rows}
              id={"funding-row-#{field(opportunity, :id)}"}
              class={if truthy?(field(opportunity, :highlighted)), do: "is-highlighted", else: nil}
            >
              <% highlighted = truthy?(field(opportunity, :highlighted)) %>
              <td>
                <div class="funding-opportunity-name">
                  <button
                    type="button"
                    class="funding-highlight-toggle"
                    aria-label={"Highlight #{field(opportunity, :name)}"}
                    aria-pressed={to_string(highlighted)}
                    title={if highlighted, do: "Remove highlight", else: "Highlight opportunity"}
                    phx-click="set_funding_highlight"
                    phx-value-id={field(opportunity, :id)}
                    phx-value-highlighted={to_string(!highlighted)}
                  >
                    <span aria-hidden="true">{if highlighted, do: "★", else: "☆"}</span>
                  </button>
                  <div>
                    <.link
                      patch={~p"/correspondence/funding/#{field(opportunity, :id)}"}
                      class="places-name"
                    >{field(opportunity, :name)}</.link>
                    <p :if={field(opportunity, :priority)} class="places-secondary">
                      {Enum.find_value(Funding.priorities(), fn {label, key} ->
                        if key == field(opportunity, :priority), do: label
                      end)}
                    </p>
                    <p :if={present?(field(opportunity, :cycle))} class="places-secondary">
                      {field(opportunity, :cycle)}
                    </p>
                    <p :if={present?(field(opportunity, :eligibility))} class="places-description">
                      {excerpt(field(opportunity, :eligibility), 130)}
                    </p>
                  </div>
                </div>
              </td>
              <td>{field(opportunity, :funder) || "—"}</td>
              <td>{kind_label(field(opportunity, :kind))}</td>
              <td>{field(opportunity, :amount) || "—"}</td>
              <td>
                <.date_link
                  :if={present?(field(opportunity, :opens_on))}
                  date={field(opportunity, :opens_on)}
                  label={
                    if same_date?(field(opportunity, :opens_on), field(opportunity, :deadline)),
                      do: "Deadline",
                      else: "Opens"
                  }
                  today={@today}
                /><.date_link
                  :if={different_dates?(field(opportunity, :opens_on), field(opportunity, :deadline))}
                  date={field(opportunity, :deadline)}
                  label="Deadline"
                  today={@today}
                /><span :if={
                  !present?(field(opportunity, :opens_on)) and
                    !present?(field(opportunity, :deadline))
                }>Not recorded</span><p
                  :if={present?(field(opportunity, :deadline_time))}
                  class="places-secondary"
                >
                  By {field(opportunity, :deadline_time)}{if present?(field(opportunity, :timezone)),
                    do: " #{field(opportunity, :timezone)}",
                    else: ""}
                </p>
              </td>
              <td class="funding-row-actions">
                <.link navigate={
                  ~p"/correspondence/funding/applications/new/#{field(opportunity, :id)}"
                }>Prepare application</.link>
                <a
                  :if={safe_url(field(opportunity, :application_url))}
                  href={field(opportunity, :application_url)}
                  target="_blank"
                  rel="noopener noreferrer"
                >Apply <span aria-hidden="true">↗</span></a><a
                  :if={safe_url(field(opportunity, :source_url))}
                  href={field(opportunity, :source_url)}
                  target="_blank"
                  rel="noopener noreferrer"
                >Official source <span aria-hidden="true">↗</span></a>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <nav :if={@directory.pages > 1} class="corr-pagination" aria-label="Funding pages">
        <.link :if={@directory.page > 1} patch={page_path(@directory.filters, @directory.page - 1)}>← Previous</.link>
        <span>Page {@directory.page} of {@directory.pages}</span>
        <.link
          :if={@directory.page < @directory.pages}
          patch={page_path(@directory.filters, @directory.page + 1)}
        >Next →</.link>
      </nav>
    </section>
    """
  end

  attr :applications, :list, required: true
  attr :filter, :string, required: true

  def applications(assigns) do
    ~H"""
    <section id="funding-applications" class="editorial-place-directory corr-directory">
      <header class="corr-directory-heading">
        <h1>Funding</h1>
      </header>
      <.funding_views current={:applications} />
      <nav class="funding-views" aria-label="Application status">
        <.link
          :for={{label, value} <- [{"All", "all"}, {"Submitted", "sent"}, {"Drafts", "drafts"}]}
          patch={~p"/correspondence/funding/applications?#{%{status: value}}"}
          aria-current={if @filter == value, do: "true"}
        >{label}</.link>
      </nav>
      <p :if={@applications == []} class="corr-meta">
        {case @filter do
          "sent" -> "No submitted applications recorded."
          "drafts" -> "No applications in preparation."
          _ -> "No applications yet. Choose Prepare application on an opportunity to start."
        end}
      </p>
      <div
        :if={@applications != []}
        class="places-table-scroll corr-table-scroll"
        role="region"
        aria-label="Funding applications"
        tabindex="0"
      >
        <table id="funding-applications-table" class="places-table corr-table">
          <caption class="sr-only">Funding applications and outcomes</caption>
          <thead>
            <tr>
              <th scope="col">Application</th><th scope="col">Funder</th><th scope="col">Status</th>
              <th scope="col">Deadline</th><th scope="col">Submitted</th><th scope="col">Decision</th>
              <th scope="col">Award</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={application <- @applications}
              id={"funding-application-row-#{application["id"]}"}
            >
              <td>
                <.link
                  class="places-name"
                  navigate={~p"/correspondence/funding/applications/#{application["id"]}"}
                >{application["title"]}</.link>
              </td>
              <td>{application["funder"] || "—"}</td>
              <td>{FundingApplications.status_label(application["status"])}</td>
              <td>{application_date(application["deadline"])}</td>
              <td>{application_date(application["submitted_on"])}</td>
              <td>{application_date(application["decision_on"])}</td>
              <td>{if present?(application["award"]), do: application["award"], else: "—"}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :current, :atom, required: true

  defp funding_views(assigns) do
    ~H"""
    <nav class="funding-views funding-view-switch" aria-label="Funding view">
      <.link
        patch={~p"/correspondence/funding"}
        aria-current={if @current == :opportunities, do: "page"}
      >Opportunities</.link>
      <.link
        patch={~p"/correspondence/funding/applications"}
        aria-current={if @current == :applications, do: "page"}
      >Applications</.link>
    </nav>
    """
  end

  defp application_date(nil), do: "—"
  defp application_date(value), do: date_text(value)

  attr :applications, :list, default: []
  attr :opportunity, :map, default: nil
  attr :form, :map, required: true
  attr :today, :any, required: true

  def editor(assigns) do
    ~H"""
    <section class="editorial-place-editor" aria-labelledby="funding-editor-title">
      <.link patch={~p"/correspondence/funding"} class="editorial-place-back">← All funding</.link>
      <h1 id="funding-editor-title">
        {if @opportunity, do: "Edit #{@opportunity.name}", else: "Add funding opportunity"}
      </h1>
      <p :if={@opportunity} class="editorial-place-actions">
        <a
          :if={safe_url(field(@opportunity, :application_url))}
          href={field(@opportunity, :application_url)}
          target="_blank"
          rel="noopener noreferrer"
        >Application page ↗</a>
        <a
          :if={safe_url(field(@opportunity, :source_url))}
          href={field(@opportunity, :source_url)}
          target="_blank"
          rel="noopener noreferrer"
        >Official source ↗</a>
        <span :if={present?(field(@opportunity, :checked_on))} class="corr-meta">Checked {date_text(
          field(@opportunity, :checked_on)
        )}</span>
      </p>
      <section
        :if={@opportunity}
        id="funding-opportunity-applications"
        aria-labelledby="funding-applications-heading"
      >
        <h2 id="funding-applications-heading">Applications</h2>
        <.link navigate={~p"/correspondence/funding/applications/new/#{@opportunity.id}"}>Prepare application</.link>
        <ul :if={@applications != []}>
          <li :for={application <- @applications}>
            <.link navigate={~p"/correspondence/funding/applications/#{application["id"]}"}>
              {Still.Correspondence.FundingApplications.status_label(application["status"])}
              <span :if={application["submitted_on"]}> · {application["submitted_on"]}</span>
            </.link>
          </li>
        </ul>
      </section>
      <div :if={@opportunity} class="funding-editor-dates">
        <.date_link
          :if={@opportunity.opens_on && @opportunity.opens_on != @opportunity.deadline}
          date={@opportunity.opens_on}
          label="Opens"
          today={@today}
        />
        <.date_link
          :if={@opportunity.deadline}
          date={@opportunity.deadline}
          label="Deadline"
          today={@today}
        />
      </div>
      <.form
        id="funding-form"
        for={@form}
        phx-submit="save_funding"
        phx-change="validate_funding"
        class="editorial-place-form"
      >
        <div class="editorial-place-fields">
          <label class="editorial-place-field is-wide">Name<input
            name="funding[name]"
            value={form_value(@form, :name)}
            required
            maxlength="300"
          /></label>
          <label>Funder<input
            name="funding[funder]"
            value={form_value(@form, :funder)}
            maxlength="300"
            required
          /></label>
          <label>Kind<select name="funding[kind]" required><option
            :for={{label, value} <- Funding.kinds()}
            value={value}
            selected={form_value(@form, :kind) == value}
          >
            {label}
          </option></select></label>
          <label :for={
            {field, label, choices} <- [
              {:priority, "Priority", Funding.priorities()},
              {:eligibility_status, "Eligibility assessment", Funding.eligibility_statuses()},
              {:benefit, "Primary benefit", Funding.benefits()}
            ]
          }>
            {label}
            <select name={"funding[#{field}]"}>
              <option value="">Unspecified</option>
              <option
                :for={{text, value} <- choices}
                value={value}
                selected={form_value(@form, field) == value}
              >
                {text}
              </option>
            </select>
          </label>
          <label>Start preparing<input
            type="date"
            name="funding[prepare_on]"
            value={form_value(@form, :prepare_on)}
          /></label>
          <label :for={
            {field, label} <- [
              {:fit, "Artistic fit"},
              {:effort, "Application effort"},
              {:fee, "Application fee"},
              {:travel, "Travel or residency requirements"},
              {:anticipated_window, "Anticipated window"}
            ]
          }>
            {label}
            <input name={"funding[#{field}]"} value={form_value(@form, field)} maxlength="5000" />
          </label>
          <label class="editorial-place-field is-wide funding-notes-field">
            Notes
            <span class="funding-notes-content">
              <% notes = form_value(@form, :notes) %>
              <span class="funding-notes-measure" aria-hidden="true" phx-no-format>{notes}{" "}</span>
              <textarea name="funding[notes]" rows="5" phx-no-format>{notes}</textarea>
            </span>
          </label>
          <label>Cycle<input name="funding[cycle]" value={form_value(@form, :cycle)} /></label>
          <label>Amount<input name="funding[amount]" value={form_value(@form, :amount)} /></label>
          <label class="editorial-place-field is-wide">Eligibility<textarea
            name="funding[eligibility]"
            rows="3"
          >{form_value(@form, :eligibility)}</textarea></label>
          <label class="editorial-place-field is-wide">Description<textarea
            name="funding[description]"
            rows="5"
          >{form_value(@form, :description)}</textarea></label>
          <label>Opens on<input
            type="date"
            name="funding[opens_on]"
            value={form_value(@form, :opens_on)}
          /></label>
          <label>Deadline<input
            type="date"
            name="funding[deadline]"
            value={form_value(@form, :deadline)}
          /></label>
          <label>Deadline time<input
            type="time"
            name="funding[deadline_time]"
            value={form_value(@form, :deadline_time)}
          /></label>
          <label>Time zone<input
            name="funding[timezone]"
            value={form_value(@form, :timezone)}
            placeholder="America/Chicago"
          /></label>
          <label class="editorial-place-field is-wide">Application URL<input
            type="url"
            name="funding[application_url]"
            value={form_value(@form, :application_url)}
          /></label>
          <label class="editorial-place-field is-wide">Official source URL<input
            type="url"
            name="funding[source_url]"
            value={form_value(@form, :source_url)}
          /></label>
          <label>Checked on<input
            type="date"
            name="funding[checked_on]"
            value={form_value(@form, :checked_on)}
          /></label>
          <label class="editorial-place-field is-wide funding-highlight-field"><input
            type="hidden"
            name="funding[highlighted]"
            value="false"
          /><input
            type="checkbox"
            name="funding[highlighted]"
            value="true"
            checked={truthy?(form_value(@form, :highlighted))}
          /> Highlight this opportunity</label>
        </div>
        <div class="editorial-place-form-actions funding-form-actions">
          <button type="submit" class="corr-button corr-button-primary" phx-disable-with="Saving…">Save opportunity
          <span aria-hidden="true">→</span></button>
          <.link
            patch={~p"/correspondence/funding"}
            class="corr-text-link"
          >Cancel</.link>
        </div>
      </.form>
    </section>
    """
  end

  attr :upload, :any, required: true
  attr :plan, :any, default: nil
  attr :result, :any, default: nil

  def import_page(assigns) do
    ~H"""
    <section id="funding-import" class="corr-place-import" aria-labelledby="funding-import-heading">
      <.link patch={~p"/correspondence/funding"} class="editorial-place-back">← Funding</.link>
      <h1 id="funding-import-heading">Import funding opportunities</h1>
      <p>Choose a JSON file, review what it contains, then add the opportunities you want to keep.</p>
      <form
        id="funding-import-form"
        phx-change="validate_funding_upload"
        phx-submit="preview_funding_import"
      >
        <label for={@upload.ref}>Funding JSON file</label><.live_file_input upload={@upload} />
        <p class="corr-meta">One .json file, up to 1 MB and 200 opportunities.</p>
        <p :for={error <- upload_errors(@upload)} role="alert">{upload_error(error)}</p>
        <p :for={entry <- @upload.entries}>
          {entry.client_name}<span :for={error <- upload_errors(@upload, entry)} role="alert">{upload_error(
            error
          )}</span>
        </p>
        <button type="submit" class="corr-button" phx-disable-with="Reading…">Review import →</button>
      </form>
      <section :if={@plan} id="funding-import-preview" class="corr-import-review">
        <h2>
          {length(@plan.opportunities)} opportunities · {length(@plan.skipped)} duplicates skipped
        </h2>
        <p>Review the proposed additions and skipped names before committing.</p>
        <h3 :if={@plan.opportunities != []}>To add</h3>
        <ul>
          <li :for={opportunity <- @plan.opportunities}>
            <span :if={truthy?(field(opportunity, :highlighted))} class="corr-funding-highlight">Highlighted · </span><strong>{field(
              opportunity,
              :name
            )}</strong><span :if={present?(field(opportunity, :funder))}> · {field(
              opportunity,
              :funder
            )}</span><span :if={present?(field(opportunity, :deadline))}> · Deadline {date_text(
              field(opportunity, :deadline)
            )}</span>
          </li>
        </ul>
        <h3 :if={@plan.skipped != []}>Duplicates · skipped</h3>
        <ul>
          <li :for={row <- @plan.skipped}>
            <strong>{field(row, :name)}</strong><span :if={present?(field(row, :reason))}> · {field(
              row,
              :reason
            )}</span>
          </li>
        </ul>
        <button
          :if={@plan.opportunities != []}
          id="confirm-funding-import"
          type="button"
          phx-click="import_funding"
          class="corr-button"
          phx-disable-with="Importing…"
        >Import {length(@plan.opportunities)} opportunities →</button>
      </section>
      <section :if={@result} id="funding-import-result" class="corr-import-review" aria-live="polite">
        <p>Imported {length(@result.imported)} · skipped {length(@result.skipped)} duplicates.</p>
        <ul :if={@result.imported != []}>
          <li :for={name <- @result.imported}>{name}</li>
        </ul>
        <p :if={@result.skipped != []}>Skipped: {Enum.join(@result.skipped, ", ")}</p>
        <.link patch={~p"/correspondence/funding"} class="corr-text-link">View funding →</.link>
      </section>
      <details class="corr-import-example">
        <summary>JSON format and example</summary>
        <p>
          <a href="/correspondence/funding/schema" download class="corr-text-link">Download funding-import.schema.json</a>
        </p>
        <pre id="funding-import-example"><code>{FundingImport.example()}</code></pre>
        <StillWeb.CopyText.copy_text
          id="copy-funding-example"
          body={FundingImport.example()}
          label="Copy example JSON"
        />
        <p>
          Dates use YYYY-MM-DD. Opportunities with the same name, funder, and cycle are skipped.
        </p>
      </details>
    </section>
    """
  end

  defp date_link(assigns) do
    ~H"""
    <span :if={present?(@date)} class="funding-date-link">
      <.link patch={calendar_path(@date)} class={deadline_class(@date, @today)}>{@label} {date_text(
        @date
      )}</.link>
      <span :if={@label == "Deadline" and date_compare(@date, @today) == :lt} class="places-state">Past</span>
      <span
        :if={@label == "Deadline" and date_compare(@date, @today) == :eq}
        class="places-window-open"
      >Due today</span>
    </span>
    """
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_, _), do: nil
  defp form_value(form, key), do: Phoenix.HTML.Form.input_value(form, key) || ""
  defp present?(value), do: value not in [nil, ""]
  defp truthy?(value), do: value in [true, "true", "on", 1]

  defp kind_label(kind) do
    case Enum.find(Funding.kinds(), fn {_label, value} -> value == kind end) do
      {label, _} -> label
      _ -> "Other"
    end
  end

  defp excerpt(nil, _limit), do: ""

  defp excerpt(value, limit),
    do:
      value
      |> to_string()
      |> String.slice(0, limit)
      |> then(&(&1 <> if(String.length(to_string(value)) > limit, do: "…", else: "")))

  defp different_dates?(opens, deadline),
    do: present?(deadline) and date_text(opens) != date_text(deadline)

  defp same_date?(opens, deadline),
    do: present?(opens) and present?(deadline) and date_text(opens) == date_text(deadline)

  defp date_text(%Date{} = date), do: Calendar.strftime(date, "%b %-d, %Y")

  defp date_text(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date_text(date)
      _ -> value
    end
  end

  defp date_text(_), do: ""

  defp date_compare(date, today) do
    with {:ok, parsed} <- date_result(date), %Date{} <- today do
      Date.compare(parsed, today)
    else
      _ -> :gt
    end
  end

  defp date_result(%Date{} = date), do: {:ok, date}
  defp date_result(value) when is_binary(value), do: Date.from_iso8601(value)
  defp date_result(_), do: :error

  defp deadline_class(date, today),
    do: if(date_compare(date, today) == :lt, do: "is-past", else: "")

  defp calendar_path(date) do
    case date_result(date) do
      {:ok, parsed} ->
        ~p"/correspondence/calendar?#{[show: "funding", date: Date.to_iso8601(parsed), month: Calendar.strftime(parsed, "%Y-%m")]}"

      _ ->
        ~p"/correspondence/calendar"
    end
  end

  def safe_url(value) when is_binary(value),
    do: String.starts_with?(String.downcase(value), ["https://", "http://"])

  def safe_url(_), do: false

  defp page_path(filters, page) do
    params = [q: filters["q"], kind: filters["kind"], deadline: filters["deadline"], page: page]
    ~p"/correspondence/funding?#{params}"
  end

  defp upload_error(:too_large), do: "File is too large."
  defp upload_error(:too_many_files), do: "Choose one JSON file."
  defp upload_error(:not_accepted), do: "Choose a .json file."
  defp upload_error(_), do: "The file could not be uploaded. Choose it again."
end
