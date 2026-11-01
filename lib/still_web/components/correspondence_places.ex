defmodule StillWeb.CorrespondencePlaces do
  @moduledoc "Editorial components for browsing and editing correspondence destinations."
  use StillWeb, :html
  alias Still.{Correspondence, Poems}

  attr :journals, :list, required: true
  attr :icons, :map, default: %{}

  def directory(assigns) do
    assigns =
      assigns
      |> assign(:active, Enum.filter(assigns.journals, &Correspondence.active_journal?/1))
      |> assign(:inactive, Enum.reject(assigns.journals, &Correspondence.active_journal?/1))
      |> assign(
        :shortlisted,
        Enum.filter(
          assigns.journals,
          &(Correspondence.active_journal?(&1) && truthy?(&1.shortlisted))
        )
      )

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

      <section
        :if={@shortlisted != []}
        class="editorial-place-shortlist"
        aria-labelledby="shortlist-heading"
      >
        <div class="editorial-place-section-head">
          <h2 id="shortlist-heading">On your shortlist</h2>
        </div>
        <ul class="editorial-place-shortcuts">
          <li :for={journal <- @shortlisted}>
            <.link patch={~p"/correspondence/journals/#{journal.id}"}>{journal.name}</.link>
            <span>Shortlisted</span>
          </li>
        </ul>
      </section>

      <section class="editorial-place-all" aria-labelledby="all-places-heading">
        <div class="editorial-place-section-head">
          <h2 id="all-places-heading">Active places</h2>
        </div>
        <div :if={@active != []} class="editorial-place-grid">
          <.journal_card
            :for={journal <- @active}
            journal={journal}
            icon={Map.get(@icons, journal.id)}
          />
        </div>
        <div :if={@active == []} class="editorial-place-empty">
          <p class="editorial-place-empty-title">The directory is open.</p>
          <p>
            Add a publication when one comes to mind. Its details and your notes can stay together here.
          </p>
          <.link patch={~p"/correspondence/journals/new"} class="corr-text-link">Add your first place
          <span>→</span></.link>
        </div>
      </section>
      <details :if={@inactive != []} id="inactive-places" class="corr-inactive-places">
        <summary>Inactive places ({length(@inactive)})</summary>
        <p>Notes and past submissions are kept. Open a place to reactivate it.</p>
        <ul>
          <li :for={journal <- @inactive}>
            <.link patch={~p"/correspondence/journals/#{journal.id}"}>{journal.name}</.link>
          </li>
        </ul>
      </details>
    </section>
    """
  end

  attr :journal, :map, required: true

  attr :icon, :string, default: nil

  defp journal_card(assigns) do
    assigns =
      assigns
      |> assign(:has_notes, has_text?(assigns.journal.notes))
      |> assign(:has_interests, has_text?(assigns.journal.interests))
      |> assign(:windows, known_or_unknown(assigns.journal.windows))
      |> assign(:policy, policy(assigns.journal.simultaneous_policy))
      |> assign(:verified, truthy?(assigns.journal.verified))

    ~H"""
    <article class="editorial-place-card">
      <div class="editorial-place-card-top">
        <span class="editorial-place-source">{if @verified,
          do: "You marked source checked",
          else: "Personal record"}</span>
      </div>
      <div class="place-name-with-icon">
        <.icon journal={@journal} src={@icon} />
        <h3><.link patch={~p"/correspondence/journals/#{@journal.id}"}>{@journal.name}</.link></h3>
      </div>
      <p :if={has_text?(value(@journal, :description))} class="place-description">
        {value(@journal, :description)}
      </p>
      <p :if={@has_interests} class="editorial-place-interest">{@journal.interests}</p>
      <p :if={@has_notes} class="editorial-place-note">{@journal.notes}</p>
      <p :if={has_text?(value(@journal, :keywords))} class="corr-meta">
        Keywords: {value(@journal, :keywords)}
      </p>
      <p class="corr-meta">Reach: {Correspondence.reach_label(value(@journal, :reach))}</p>
      <div class="editorial-place-facts">
        <span>Simultaneous: {@policy}</span>
        <span>Window: {@windows}</span>
      </div>
      <div class="corr-place-actions">
        <.link patch={~p"/correspondence/journals/#{@journal.id}"} class="editorial-place-open">Open place
        <span aria-hidden="true">→</span></.link>
        <button
          type="button"
          class="corr-text-link corr-desk-action"
          phx-click="toggle_shortlist"
          phx-value-id={@journal.id}
          aria-pressed={to_string(truthy?(@journal.shortlisted))}
        >{if truthy?(@journal.shortlisted), do: "Remove from shortlist", else: "Add to shortlist"}</button>
      </div>
    </article>
    """
  end

  attr :journal, :map, required: true
  attr :packets, :list, required: true
  attr :pieces, :list, required: true
  attr :form, :map, required: true

  attr :icon, :string, default: nil

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
      <.link patch={~p"/correspondence/journals"} class="editorial-place-back">← All places</.link>
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
        >{if truthy?(@journal.shortlisted), do: "Remove from shortlist", else: "Add to shortlist"}</button>
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
          /> Keep this place on my shortlist</label>
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
