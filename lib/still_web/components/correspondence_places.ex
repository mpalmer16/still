defmodule StillWeb.CorrespondencePlaces do
  @moduledoc "Editorial components for browsing and editing correspondence destinations."
  use StillWeb, :html
  alias Still.{Correspondence, Poems}

  attr :directory, :map, required: true
  attr :icons, :map, default: %{}

  def directory(assigns) do
    ~H"""
    <section id="places-directory" class="editorial-place-directory" aria-labelledby="places-heading">
      <header class="editorial-place-intro">
        <h1 id="places-heading">Places</h1>
        <div class="corr-place-directory-actions">
          <.link patch={~p"/correspondence/journals/new"} class="corr-button editorial-place-add">Add a place
          <span>+</span></.link>
          <.link patch={~p"/correspondence/journals/import"} class="corr-text-link">Import Places</.link>
        </div>
      </header>

      <.form
        for={%{}}
        id="places-filters"
        class="places-filters"
        phx-change="filter_places"
        phx-submit="filter_places"
      >
        <div class="places-search-row">
          <div class="places-search">
            <label for="places-query">Search places</label>
            <input
              id="places-query"
              type="search"
              name="places[q]"
              value={@directory.filters["q"]}
              placeholder="Name, keywords, or notes"
              phx-debounce="250"
              autocomplete="off"
            />
            <small>Search includes descriptions, guidelines, submission details, and your notes.</small>
          </div>
          <.link id="reset-places" patch={~p"/correspondence/journals"} class="corr-text-link">Reset view</.link>
        </div>
        <div class="places-filter-row">
          <.directory_filter
            id="places-status"
            label="Status"
            name="status"
            value={@directory.filters["status"]}
            options={[
              {"Active places", "active"},
              {"All places", "all"},
              {"Inactive places", "inactive"}
            ]}
          />
          <.directory_filter
            id="places-nearby"
            label="Kept nearby"
            name="nearby"
            value={@directory.filters["nearby"]}
            options={[{"All", "all"}, {"Kept nearby", "nearby"}, {"Not kept nearby", "not_nearby"}]}
          />
          <.directory_filter
            id="places-reach"
            label="Reach · your impression"
            name="reach"
            value={@directory.filters["reach"]}
            options={[
              {"Any reach", "all"},
              {"Approachable", "approachable"},
              {"A stretch", "stretch"},
              {"A long shot", "long_shot"},
              {"Unknown", "unknown"}
            ]}
          />
          <.directory_filter
            id="places-simultaneous"
            label="Simultaneous submissions"
            name="simultaneous"
            value={@directory.filters["simultaneous"]}
            options={[
              {"Any policy", "all"},
              {"Allowed", "allowed"},
              {"Not allowed", "not_allowed"},
              {"Unknown", "unknown"}
            ]}
          />
          <.directory_filter
            id="places-history"
            label="Submission history"
            name="history"
            value={@directory.filters["history"]}
            options={[
              {"Any history", "all"},
              {"Never sent", "never_sent"},
              {"Awaiting reply", "awaiting"},
              {"Sent before", "sent"}
            ]}
          />
        </div>
      </.form>

      <p id="places-result-count" class="places-result-count" role="status" aria-live="polite">
        <%= if @directory.matched > 0 do %>
          {(@directory.page - 1) * @directory.per_page + 1}–{(@directory.page - 1) *
            @directory.per_page + length(@directory.rows)} of {@directory.matched} {if @directory.matched ==
                                                                                         1,
                                                                                       do: "place",
                                                                                       else: "places"}
        <% else %>
          No places match this view
        <% end %>
        <span> · {@directory.total} total</span>
      </p>

      <div
        :if={@directory.rows != []}
        class="places-table-scroll"
        role="region"
        aria-label="Places table"
        tabindex="0"
      >
        <table id="places-table" class="places-table">
          <caption class="sr-only">Places and the submission details you have recorded</caption>
          <thead>
            <tr>
              <.sort_header
                field="name"
                label="Place"
                filters={@directory.filters}
                class="places-col-name"
              />
              <.sort_header
                field="reach"
                label="Reach"
                filters={@directory.filters}
                class="places-col-reach"
              />
              <th scope="col" class="places-col-simultaneous">Simultaneous</th>
              <.sort_header
                field="window"
                label="Submission window"
                filters={@directory.filters}
                class="places-col-window"
              />
              <.sort_header
                field="last_sent"
                label="History"
                filters={@directory.filters}
                class="places-col-history"
              />
              <th scope="col" class="places-col-nearby">Keep nearby</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @directory.rows} id={"place-row-#{row.journal.id}"}>
              <td class="places-name-cell">
                <div class="place-name-with-icon">
                  <.icon journal={row.journal} src={Map.get(@icons, row.journal.id)} />
                  <.link patch={~p"/correspondence/journals/#{row.journal.id}"} class="places-name">{row.journal.name}</.link>
                </div>
                <span :if={truthy?(value(row.journal, :verified))} class="places-state">Source checked by you</span>
                <span :if={!Correspondence.active_journal?(row.journal)} class="places-state">Inactive</span>
                <p :if={has_text?(value(row.journal, :description))} class="places-description">
                  {excerpt(value(row.journal, :description), 150)}
                </p>
                <p :if={has_text?(row.journal.notes)} class="places-notes">
                  <span>Notes:</span> {excerpt(row.journal.notes, 150)}
                </p>
                <p :if={has_text?(value(row.journal, :keywords))} class="places-secondary">
                  {excerpt(value(row.journal, :keywords), 100)}
                </p>
              </td>
              <td>{Correspondence.reach_label(value(row.journal, :reach))}</td>
              <td>{policy(row.journal.simultaneous_policy)}</td>
              <td>
                <div>{known_or_unknown(row.journal.windows)}</div>
                <p :if={has_text?(row.journal.fee)} class="places-secondary">
                  Fee: {excerpt(row.journal.fee, 90)}
                </p>
              </td>
              <td class="places-history">
                <%= cond do %>
                  <% row.sent_count == 0 -> %>
                    <span>Never sent</span>
                  <% row.last_sent_at -> %>
                    <span>Last sent
                    <time datetime={String.slice(row.last_sent_at, 0, 10)}>{display_date(
                      row.last_sent_at
                    )}</time></span>
                  <% true -> %>
                    <span>Sent · date not recorded</span>
                <% end %>
                <p :if={row.awaiting_count > 0} class="places-secondary">
                  {row.awaiting_count} awaiting reply
                </p>
                <p :if={row.packet_count > 0} class="places-secondary">
                  {row.packet_count} {if row.packet_count == 1, do: "packet", else: "packets"}
                </p>
              </td>
              <td>
                <button
                  type="button"
                  class="places-nearby"
                  phx-click="toggle_shortlist"
                  phx-value-id={row.journal.id}
                  aria-label={"#{if truthy?(row.journal.shortlisted), do: "Stop keeping", else: "Keep"} #{row.journal.name} nearby"}
                  aria-pressed={to_string(truthy?(row.journal.shortlisted))}
                  phx-disable-with="Saving…"
                >{if truthy?(row.journal.shortlisted), do: "Kept nearby", else: "Keep nearby"}</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div :if={@directory.total == 0} class="editorial-place-empty">
        <p class="editorial-place-empty-title">The directory is open.</p>
        <p>
          Add a publication when one comes to mind. Its details and your notes can stay together here.
        </p>
        <.link patch={~p"/correspondence/journals/new"} class="corr-text-link">Add your first place →</.link>
      </div>
      <p :if={@directory.total > 0 && @directory.matched == 0} class="editorial-place-empty-note">
        Try another search or reset the view. Inactive places are available under Status.
      </p>
      <nav :if={@directory.pages > 1} class="places-pagination" aria-label="Places pages">
        <button
          type="button"
          phx-click="places_page"
          phx-value-page={@directory.page - 1}
          disabled={@directory.page == 1}
          class="corr-text-link"
        >Previous page</button>
        <span>Page {@directory.page} of {@directory.pages}</span>
        <button
          type="button"
          phx-click="places_page"
          phx-value-page={@directory.page + 1}
          disabled={@directory.page == @directory.pages}
          class="corr-text-link"
        >Next page</button>
      </nav>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :options, :list, required: true

  defp directory_filter(assigns) do
    ~H"""
    <div class="places-filter">
      <label for={@id}>{@label}</label>
      <select id={@id} name={"places[#{@name}]"}>
        <option :for={{label, value} <- @options} value={value} selected={value == @value}>
          {label}
        </option>
      </select>
    </div>
    """
  end

  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :filters, :map, required: true
  attr :class, :string, default: nil

  defp sort_header(assigns) do
    assigns =
      assigns
      |> assign(:selected, assigns.filters["sort"] == assigns.field)
      |> assign(
        :sort_label,
        case assigns.field do
          "last_sent" -> "Sort by last sent date"
          "window" -> "Sort by recorded submission window text"
          _ -> "Sort by " <> assigns.label
        end
      )

    ~H"""
    <th
      scope="col"
      class={@class}
      aria-sort={
        if @selected,
          do: if(@filters["direction"] == "desc", do: "descending", else: "ascending"),
          else: "none"
      }
    >
      <button
        type="button"
        class="places-sort"
        phx-click="sort_places"
        phx-value-column={@field}
        aria-label={@sort_label}
        title={@sort_label}
      >
        {@label}<span aria-hidden="true">{if @selected,
          do: if(@filters["direction"] == "desc", do: "↓", else: "↑"),
          else: "↕"}</span>
      </button>
    </th>
    """
  end

  defp excerpt(text, limit) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()
    if String.length(text) > limit, do: String.slice(text, 0, limit) <> "…", else: text
  end

  defp display_date(value) do
    case Date.from_iso8601(String.slice(value, 0, 10)) do
      {:ok, date} -> Calendar.strftime(date, "%b %-d, %Y")
      _ -> "date not recorded"
    end
  end

  attr :journal, :map, required: true
  attr :packets, :list, required: true
  attr :pieces, :list, required: true
  attr :form, :map, required: true

  attr :icon, :string, default: nil
  attr :directory_path, :string, default: "/correspondence/journals"

  def details(assigns) do
    assigns =
      assigns
      |> assign(
        :possibilities,
        Correspondence.pieces_to_consider(assigns.journal, assigns.pieces)
      )
      |> assign(:inactive, !Correspondence.active_journal?(assigns.journal))
      |> assign(:website_href, safe_web_url(value(assigns.journal, :website)))
      |> assign(:submission_href, safe_web_url(value(assigns.journal, :submission_url)))
      |> assign(:packets, Enum.sort_by(assigns.packets, &packet_sort_key/1, :desc))

    ~H"""
    <section class="editorial-place-detail" aria-labelledby="place-title">
      <.link patch={@directory_path} class="editorial-place-back">← All places</.link>
      <header class="editorial-place-profile-head">
        <div>
          <div class="place-name-with-icon is-profile">
            <.icon journal={@journal} src={@icon} />
            <h1 id="place-title">{@journal.name}</h1>
          </div>
          <p :if={has_text?(value(@journal, :description))} class="place-description">
            {value(@journal, :description)}
          </p>
        </div>
        <button
          type="button"
          class="corr-text-link corr-desk-action"
          phx-click="toggle_shortlist"
          phx-value-id={@journal.id}
          aria-pressed={to_string(truthy?(@journal.shortlisted))}
        >{if truthy?(@journal.shortlisted), do: "Stop keeping nearby", else: "Keep nearby"}</button>
      </header>

      <div class="corr-place-status">
        <p :if={@inactive}>
          Inactive · Notes and past submissions are preserved. Reactivate this place to prepare or send another packet.
        </p>
        <button
          id="toggle-place-active"
          type="button"
          class="corr-text-link"
          phx-click="toggle_place_active"
          phx-value-id={@journal.id}
          phx-disable-with="Saving…"
        >{if @inactive, do: "Reactivate place", else: "Deactivate place"}</button>
      </div>
      <div class="editorial-place-profile-grid">
        <div class="editorial-place-main">
          <section class="editorial-place-profile-section">
            <span class="corr-kicker">YOUR NOTES</span>
            <p class="editorial-place-prose">{present(@journal.notes)}</p>
          </section>
          <section class="editorial-place-profile-section">
            <span class="corr-kicker">EDITORIAL INTERESTS</span>
            <p class="editorial-place-prose">{present(@journal.interests)}</p>
          </section>
          <section class="editorial-place-profile-section">
            <span class="corr-kicker">GUIDELINES YOU RECORDED</span>
            <p class="editorial-place-prose">{present(@journal.guidelines)}</p>
          </section>

          <section
            id="place-possibilities"
            class="editorial-place-profile-section"
            aria-labelledby="possibilities-title"
          >
            <h2 id="possibilities-title">Pieces to consider</h2>
            <p class="corr-meta">Keywords: {present(value(@journal, :keywords))}</p>
            <p class="corr-meta">
              Word and phrase echoes in current saved titles and text are starting points for reading, not judgments of editorial fit.
            </p>
            <article :for={match <- @possibilities} class="editorial-place-packet">
              <h3>
                <.link patch={~p"/correspondence/writing/#{match.piece.id}"}>{Poems.display_title(
                  match.piece
                )}</.link>
              </h3>
              <p :if={match.keywords != []}>Shares: {Enum.join(match.keywords, ", ")}</p>
              <p :if={match.manual}>Kept by you as a possibility.</p>
              <button
                :if={match.manual}
                type="button"
                phx-click="remove_possible_piece"
                phx-value-id={match.piece.id}
                class="corr-text-link"
              >Remove personal connection</button>
              <form :if={!match.manual} phx-submit="keep_possible_piece">
                <input type="hidden" name="possibility[piece_id]" value={match.piece.id} />
                <button type="submit" class="corr-text-link">Keep as a possibility</button>
              </form>
            </article>
            <p :if={@possibilities == []}>
              No connections yet. Add keywords or choose a saved piece yourself.
            </p>
            <form :if={@pieces != []} id="keep-possible-piece" phx-submit="keep_possible_piece">
              <label for="possible-piece">Choose a piece yourself</label>
              <select id="possible-piece" name="possibility[piece_id]" required>
                <option value="">Choose saved writing…</option>
                <option :for={piece <- @pieces} value={piece.id}>{Poems.display_title(piece)}</option>
              </select>
              <button type="submit" class="corr-button">Keep as a possibility</button>
            </form>
          </section>
          <section
            class="corr-history editorial-place-correspondence"
            aria-labelledby="place-packets-heading"
          >
            <div class="editorial-place-section-head">
              <div>
                <span class="corr-kicker">YOUR HISTORY HERE</span><h2 id="place-packets-heading">
                  Packets and pieces
                </h2>
              </div>
              <span>{@packets |> length()} {if length(@packets) == 1, do: "packet", else: "packets"}</span>
            </div>
            <article :for={packet <- @packets} class="editorial-place-packet">
              <div class="editorial-place-packet-head">
                <div>
                  <span class="editorial-place-status">{status_label(packet)}</span>
                  <h3>
                    <.link patch={~p"/correspondence/packets/#{packet.id}"}>{packet.title}</.link>
                  </h3>
                </div>
                <.link
                  patch={~p"/correspondence/packets/#{packet.id}"}
                  class="editorial-place-packet-open"
                >Open packet →</.link>
              </div>
              <p :if={packet.piece_ids == []} class="editorial-place-piece-links">
                No pieces recorded in this packet.
              </p>
              <p :if={packet.piece_ids != []} class="editorial-place-piece-links">
                <span :for={{piece_id, index} <- Enum.with_index(packet.piece_ids)}>
                  <span :if={index > 0} aria-hidden="true"> · </span>
                  <.link patch={~p"/correspondence/writing/#{piece_id}"}>{piece_title(
                    @pieces,
                    piece_id
                  )}</.link>
                </span>
              </p>
            </article>
            <p :if={@packets == []} class="editorial-place-empty-note">
              No packets have been recorded for this place yet.
            </p>
          </section>
        </div>

        <aside class="editorial-place-facts-panel" aria-label="Submission details">
          <span class="corr-kicker">SUBMISSION DETAILS</span>
          <dl>
            <div>
              <dt>Reach · your impression</dt><dd>
                {Correspondence.reach_label(value(@journal, :reach))}
              </dd>
            </div>
            <div :if={has_text?(value(@journal, :reach_note))}>
              <dt>Why it feels that way</dt><dd>{value(@journal, :reach_note)}</dd>
            </div>
            <div>
              <dt>Website</dt><dd>
                <.external_link :if={@website_href} href={@website_href} label={@journal.website} /><span :if={
                  !@website_href
                }>Not recorded</span>
              </dd>
            </div>
            <div>
              <dt>Submission guidelines</dt><dd>
                <.external_link
                  :if={@submission_href}
                  href={@submission_href}
                  label="Open submission page"
                /><span :if={!@submission_href}>Not recorded</span>
              </dd>
            </div>
            <div>
              <dt>Window</dt><dd>{known_or_unknown(@journal.windows)}</dd>
            </div>
            <div>
              <dt>Fee</dt><dd>{known_or_unknown(@journal.fee)}</dd>
            </div>
            <div>
              <dt>Simultaneous submissions</dt><dd>{policy(@journal.simultaneous_policy)}</dd>
            </div>
            <div>
              <dt>Response expectations</dt><dd>{known_or_unknown(@journal.response_expectation)}</dd>
            </div>
            <div>
              <dt>Details checked</dt><dd>
                {if truthy?(@journal.verified),
                  do: "Marked checked by you",
                  else: "Not marked checked by you"}
              </dd>
            </div>
          </dl>
          <.link
            :if={!@inactive}
            patch={~p"/correspondence/packets/new?journal=#{@journal.id}"}
            class="corr-button editorial-place-prepare"
          >Prepare a packet <span>→</span></.link>
        </aside>
      </div>

      <details class="editorial-place-edit">
        <summary>Edit place details</summary>
        <.editor_form journal={@journal} form={@form} />
      </details>
    </section>
    """
  end

  attr :journal, :map, default: nil
  attr :form, :map, required: true

  def editor(assigns) do
    ~H"""
    <section class="editorial-place-editor" aria-labelledby="place-editor-title">
      <.link patch={~p"/correspondence/journals"} class="editorial-place-back">← All places</.link>
      <header>
        <h1 id="place-editor-title">
          {if @journal, do: "Edit place details", else: "Add a place"}
        </h1>
      </header>
      <.editor_form journal={@journal} form={@form} />
    </section>
    """
  end

  attr :journal, :map, default: nil
  attr :form, :map, required: true

  defp editor_form(assigns) do
    ~H"""
    <.form
      id="journal-form"
      for={%{}}
      as={:journal}
      phx-submit="save_journal"
      phx-change="validate_journal"
      class="editorial-place-form"
    >
      <div class="editorial-place-form-section">
        <div class="editorial-place-form-heading">
          <span>01</span><div>
            <h2>The publication</h2><p>Name and useful paths back to the source.</p>
          </div>
        </div>
        <div class="editorial-place-fields">
          <label class="editorial-place-field is-wide">Name<input
            name="journal[name]"
            value={value(@form, :name)}
            required
          /></label>
          <label>Website<input
            name="journal[website]"
            type="url"
            value={value(@form, :website)}
            autocomplete="url"
          /></label>
          <label>Submission page<input
            name="journal[submission_url]"
            type="url"
            value={value(@form, :submission_url)}
          /></label>
          <label class="editorial-place-field is-wide">Short description<textarea
            name="journal[description]"
            rows="3"
            placeholder="A few words about the publication"
          >{value(@form, :description)}</textarea></label>
          <label class="editorial-place-field is-wide">Icon or logo URL<input
            type="url"
            name="journal[icon_url]"
            value={value(@form, :icon_url)}
            placeholder="Optional — otherwise try the website’s favicon"
          /><span class="corr-meta">A PNG, JPEG, GIF, WebP, or ICO image. Still saves a local copy automatically.</span></label>
          <label class="editorial-place-field is-wide">Keywords or phrases<input
            name="journal[keywords]"
            value={value(@form, :keywords)}
            placeholder="landscape, memory, rural life"
          /><span class="corr-meta">Separate with commas. These find literal echoes in saved writing.</span></label>
          <label class="editorial-place-field is-wide">What they publish<input
            name="journal[interests]"
            value={value(@form, :interests)}
          /></label>
        </div>
      </div>
      <div class="editorial-place-form-section">
        <div class="editorial-place-form-heading">
          <span>02</span><div>
            <h2>Requirements and timing</h2><p>
              Leave a detail blank or unknown until you have checked it.
            </p>
          </div>
        </div>
        <div class="editorial-place-fields">
          <label class="editorial-place-field is-wide">Submission guidelines<textarea
            name="journal[guidelines]"
            rows="5"
          >{value(@form, :guidelines)}</textarea></label>
          <label>Reading or submission windows<input
            name="journal[windows]"
            value={value(@form, :windows)}
            placeholder="Unknown if not recorded"
          /></label>
          <label>Fee<input
            name="journal[fee]"
            value={value(@form, :fee)}
            placeholder="Unknown if not recorded"
          /></label>
          <label>Simultaneous submissions<select name="journal[simultaneous_policy]"><option
            value="unknown"
            selected={value(@form, :simultaneous_policy) in ["", "unknown"]}
          >
            Unknown
          </option><option value="allowed" selected={value(@form, :simultaneous_policy) == "allowed"}>
            Allowed
          </option><option
            value="not_allowed"
            selected={value(@form, :simultaneous_policy) == "not_allowed"}
          >
            Not allowed
          </option></select></label>
          <label>Response expectations<input
            name="journal[response_expectation]"
            value={value(@form, :response_expectation)}
            placeholder="Unknown if not recorded"
          /></label>
        </div>
      </div>
      <div class="editorial-place-form-section">
        <div class="editorial-place-form-heading">
          <span>03</span><div>
            <h2>Your record</h2><p>Private notes for your future self.</p>
          </div>
        </div>
        <div class="editorial-place-fields">
          <label>Reach · your impression<select name="journal[reach]">
            <option
              :for={
                {key, label} <- [
                  {"unknown", "Unknown"},
                  {"approachable", "Approachable"},
                  {"stretch", "A stretch"},
                  {"long_shot", "A long shot"}
                ]
              }
              value={key}
              selected={value(@form, :reach, "unknown") == key}
            >
              {label}
            </option>
          </select></label>
          <label class="editorial-place-field is-wide">Why it feels that way<textarea
            name="journal[reach_note]"
            rows="2"
          >{value(@form, :reach_note)}</textarea><span class="corr-meta">Your sense of reach, separate from the publication’s age or the effort of submitting.</span></label>
          <label class="editorial-place-field is-wide">Your notes<textarea
            name="journal[notes]"
            rows="4"
          >{value(@form, :notes)}</textarea></label>
        </div>
        <div class="editorial-place-checks">
          <label><input
            type="checkbox"
            name="journal[verified]"
            value="true"
            checked={truthy?(value(@form, :verified))}
          /> I checked these details at the publication’s own source</label>
          <label><input
            type="checkbox"
            name="journal[shortlisted]"
            value="true"
            checked={truthy?(value(@form, :shortlisted))}
          /> Keep nearby
          <span class="corr-meta">A personal marker for places you’d like to return to.</span></label>
        </div>
      </div>
      <div class="editorial-place-form-actions">
        <button class="corr-button" type="submit">Save place <span>→</span></button>
        <.link patch={~p"/correspondence/journals"} class="corr-text-link">Cancel</.link>
      </div>
    </.form>
    """
  end

  attr :journal, :map, required: true
  attr :src, :string, default: nil

  def icon(assigns) do
    assigns =
      assign(
        assigns,
        :initial,
        assigns.journal.name
        |> String.trim()
        |> String.first()
        |> then(&(&1 || "?"))
        |> String.upcase()
      )

    ~H"""
    <span class="place-icon" aria-hidden="true">
      <img :if={@src} src={@src} alt="" width="48" height="48" decoding="async" />
      <span :if={!@src}>{@initial}</span>
    </span>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true

  defp external_link(assigns) do
    ~H"""
    <a href={@href} target="_blank" rel="noopener noreferrer">{@label}<span aria-hidden="true"> ↗</span></a>
    """
  end

  defp value(map, key), do: value(map, key, "")

  defp value(map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default)) || default

  defp present(value) when is_binary(value) and byte_size(value) > 0, do: value
  defp present(_), do: "Not recorded."

  defp known_or_unknown(value) when is_binary(value) and byte_size(value) > 0, do: value
  defp known_or_unknown(_), do: "Unknown"

  defp policy("allowed"), do: "Allowed"
  defp policy("not_allowed"), do: "Not allowed"
  defp policy(_), do: "Unknown"

  defp truthy?(value), do: value in [true, "true", "on", 1]

  defp has_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp has_text?(_), do: false

  defp safe_web_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        value

      _ ->
        nil
    end
  end

  defp safe_web_url(_), do: nil

  defp piece_title(pieces, id) do
    case Enum.find(pieces, &(&1.id == id)) do
      nil -> "Saved piece unavailable"
      piece -> Poems.display_title(piece)
    end
  end

  defp packet_sort_key(packet),
    do: Map.get(packet, :updated_at) || Map.get(packet, "updated_at") || ""

  defp status_label(%{status: "accepted"} = packet) do
    if length(packet.accepted_piece_ids || []) < length(packet.piece_ids || []),
      do: "Partly accepted · awaiting",
      else: "Accepted"
  end

  defp status_label(%{status: status}), do: status_label(status)
  defp status_label("preparing"), do: "In preparation"
  defp status_label("submitted"), do: "Submitted"
  defp status_label("awaiting"), do: "Awaiting reply"
  defp status_label("declined"), do: "Declined"
  defp status_label("accepted"), do: "Accepted"
  defp status_label("withdrawn"), do: "Withdrawn"
  defp status_label(_), do: "Status unknown"
end
