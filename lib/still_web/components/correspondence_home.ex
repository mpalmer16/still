defmodule StillWeb.CorrespondenceHome do
  @moduledoc "The manuscript-led Correspondence home and its lightweight desk controls."
  use StillWeb, :html
  alias Still.Poems

  attr :overview, :map, required: true
  attr :desk, :map, required: true
  attr :icons, :map, default: %{}

  def home(assigns) do
    piece_id = value(assigns.desk, :piece_id)

    assigns =
      assigns
      |> assign(:desk_piece_id, piece_id)
      |> assign(:desk_piece, Enum.find(assigns.overview.pieces || [], &(&1.id == piece_id)))
      |> assign(:active_packets, active_packets(assigns.overview.packets || []))
      |> assign(:reply_packets, recent_replies(assigns.overview.packets || []))
      |> assign(:shortlisted, shortlisted(assigns.overview.journals || []))

    ~H"""
    <section
      id="correspondence-home"
      class="editorial-correspondence-home"
      aria-labelledby="desk-heading"
    >
      <div class="editorial-home-columns">
        <section id="on-the-desk" class="editorial-desk" aria-labelledby="desk-heading">
          <header class="editorial-home-heading">
            <h1 id="desk-heading">On the desk</h1>
          </header>

          <article :if={@desk_piece} class="editorial-desk-piece" aria-labelledby="desk-piece-title">
            <h2 id="desk-piece-title">
              <.link patch={~p"/correspondence/writing/#{@desk_piece.id}"}>{title(@desk_piece)}</.link>
            </h2>
            <pre class="editorial-desk-excerpt">{excerpt(@desk_piece.body, 8)}</pre>
            <p :if={line_count(@desk_piece.body) > 8} class="editorial-desk-continues">
              More in the saved work.
            </p>
            <div class="editorial-desk-actions">
              <.link patch={~p"/correspondence/writing/#{@desk_piece.id}"}>Read &amp; see its history</.link>
              <.link patch={~p"/correspondence/packets/new?piece=#{@desk_piece.id}"}>Prepare a packet</.link>
              <button type="button" phx-click="clear_desk">Clear the desk</button>
            </div>
          </article>

          <div :if={@desk_piece_id && !@desk_piece} class="editorial-desk-missing" role="status">
            <p>The work saved for this desk is no longer in the current Works collection.</p>
            <button type="button" phx-click="clear_desk">Clear the desk</button>
          </div>

          <div :if={!@desk_piece_id} class="editorial-desk-empty">
            <h2>Choose a work to keep in view.</h2>
            <p>Place a saved piece here while you consider where it might travel.</p>
            <.link patch={~p"/correspondence/writing"}>Browse Works</.link>
          </div>

          <details class="editorial-desk-chooser">
            <summary>
              {if @desk_piece, do: "Change the work on the desk", else: "Choose a saved work"}
            </summary>
            <ul :if={@overview.pieces != []}>
              <li :for={piece <- @overview.pieces}>
                <div>
                  <.link patch={~p"/correspondence/writing/#{piece.id}"}>{title(piece)}</.link>
                  <span :if={piece.id == @desk_piece_id}>On the desk</span>
                </div>
                <button
                  :if={piece.id != @desk_piece_id}
                  type="button"
                  phx-click="place_on_desk"
                  phx-value-id={piece.id}
                >Place on desk</button>
              </li>
            </ul>
            <p :if={@overview.pieces == []} class="editorial-home-empty-note">
              No works marked for Correspondence yet.
              <.link patch={~p"/correspondence/writing"}>Browse Works</.link>
            </p>
            <.link
              :if={@overview.pieces != []}
              patch={~p"/correspondence/writing"}
              class="editorial-desk-all-works"
            >Browse all Works</.link>
          </details>
          <section
            id="places-to-consider"
            class="editorial-home-places"
            aria-labelledby="places-to-consider-heading"
          >
            <header class="editorial-home-section-heading">
              <h2 id="places-to-consider-heading">Places to consider</h2>
              <.link patch={~p"/correspondence/journals"}>All places</.link>
            </header>
            <div :if={@shortlisted != []} class="editorial-home-place-grid">
              <article :for={journal <- @shortlisted} class="editorial-home-place">
                <StillWeb.CorrespondencePlaces.icon
                  journal={journal}
                  src={Map.get(@icons, journal.id)}
                />
                <p :if={has_text?(Map.get(journal, :description))} class="place-description">
                  {journal.description}
                </p>
                <h3>
                  <.link patch={~p"/correspondence/journals/#{journal.id}"}>{journal.name}</.link>
                </h3>
                <p :if={has_text?(journal.interests)}>{summary_text(journal.interests, 180)}</p>
                <p :if={has_text?(journal.notes)}>{summary_text(journal.notes, 180)}</p>
                <div :if={truthy?(journal.verified)} class="editorial-home-place-verified">
                  Details marked checked by you
                </div>
                <p
                  :if={truthy?(journal.verified) && has_text?(journal.windows)}
                  class="editorial-home-place-fact"
                >
                  Window: {journal.windows}
                </p>
                <p
                  :if={
                    truthy?(journal.verified) && has_text?(journal.simultaneous_policy) &&
                      journal.simultaneous_policy != "unknown"
                  }
                  class="editorial-home-place-fact"
                >
                  Simultaneous submissions: {place_policy(journal.simultaneous_policy)}
                </p>
                <div
                  :if={journal_packets(@overview.packets, journal.id) != []}
                  class="editorial-home-place-history"
                >
                  <span>{length(journal_packets(@overview.packets, journal.id))} {if length(
                                                                                       journal_packets(
                                                                                         @overview.packets,
                                                                                         journal.id
                                                                                       )
                                                                                     ) == 1,
                                                                                     do: "packet",
                                                                                     else: "packets"} recorded</span>
                  <.link
                    :for={packet <- Enum.take(journal_packets(@overview.packets, journal.id), 2)}
                    patch={~p"/correspondence/packets/#{packet.id}"}
                  >{packet.title}</.link>
                </div>
                <button type="button" phx-click="toggle_shortlist" phx-value-id={journal.id}>Remove from shortlist</button>
              </article>
            </div>
            <p :if={@overview.journals == []} class="editorial-home-empty-note">
              Keep a publication’s details and your own notes together here.
              <.link patch={~p"/correspondence/journals/new"}>Add a place</.link>
            </p>
            <p :if={@overview.journals != [] && @shortlisted == []} class="editorial-home-empty-note">
              No places are shortlisted yet.
              <.link patch={~p"/correspondence/journals"}>Browse Places</.link>
            </p>
          </section>
        </section>

        <aside class="editorial-home-activity" aria-label="Correspondence activity">
          <section id="out-in-world" aria-labelledby="out-heading">
            <header class="editorial-home-section-heading">
              <h2 id="out-heading">Out in the world</h2>
              <.link patch={~p"/correspondence/packets"}>All packets</.link>
            </header>
            <article :for={packet <- @active_packets} class="editorial-active-packet">
              <div class="editorial-home-meta">
                <span>{active_status(packet)}</span>
                <time>{packet_date(packet)}</time>
              </div>
              <h3>
                <.link
                  :if={journal_for(@overview.journals, packet.journal_id)}
                  patch={~p"/correspondence/journals/#{packet.journal_id}"}
                >{journal_name(@overview.journals, packet.journal_id)}</.link>
                <.link
                  :if={!journal_for(@overview.journals, packet.journal_id)}
                  patch={~p"/correspondence/packets/#{packet.id}"}
                >{journal_name(@overview.journals, packet.journal_id) || packet.title}</.link>
              </h3>
              <.link
                patch={~p"/correspondence/packets/#{packet.id}"}
                class="editorial-active-packet-link"
              >{packet.title} · Open packet</.link>
              <p class="editorial-home-piece-links">
                <span :for={
                  {piece, index} <-
                    Enum.with_index(
                      packet_pieces(packet, Map.get(@overview, :packet_pieces, @overview.pieces))
                    )
                }>
                  <span :if={index > 0} aria-hidden="true"> · </span>
                  <.link patch={~p"/correspondence/writing/#{piece.id}"}>{title(piece)}</.link>
                </span>
                <span :if={length(packet.piece_ids || []) > 3}> · {length(packet.piece_ids) - 3} more</span>
              </p>
            </article>
            <p :if={@active_packets == []} class="editorial-home-empty-note">
              Nothing is awaiting a reply just now.
            </p>
          </section>

          <section
            id="recent-replies"
            class="editorial-recent-replies"
            aria-labelledby="replies-heading"
          >
            <header class="editorial-home-section-heading">
              <h2 id="replies-heading">Recent replies</h2>
            </header>
            <article :for={{packet, event} <- @reply_packets} class="editorial-reply-row">
              <div class="editorial-home-meta">
                <span>{reply_status(packet, event)}</span>
                <time>{display_date(value(event, :date))}</time>
              </div>
              <p>
                <.link
                  :if={journal_for(@overview.journals, packet.journal_id)}
                  patch={~p"/correspondence/journals/#{packet.journal_id}"}
                >{journal_name(@overview.journals, packet.journal_id)}</.link>
                <span :if={!journal_for(@overview.journals, packet.journal_id)}>{journal_name(
                  @overview.journals,
                  packet.journal_id
                ) || packet.title}</span>
                <span> · </span>
                <.link patch={~p"/correspondence/packets/#{packet.id}"}>{packet.title}</.link>
              </p>
              <p :if={has_text?(value(event, :note))} class="editorial-reply-note">
                {summary_text(value(event, :note), 160)}
              </p>
              <.link patch={~p"/correspondence/packets/#{packet.id}"} class="editorial-reply-open">Open reply</.link>
            </article>
            <p :if={@reply_packets == []} class="editorial-home-empty-note">
              Replies will appear here when you record them.
            </p>
          </section>
        </aside>
      </div>
    </section>
    """
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default)) || default

  defp value(_, _, default), do: default

  defp title(piece), do: Poems.display_title(piece)

  defp excerpt(body, max_lines) when is_binary(body) do
    body
    |> String.split(~r/\r\n|\r|\n/, trim: false)
    |> Enum.take(max_lines)
    |> Enum.join("\n")
  end

  defp excerpt(_, _), do: ""

  defp line_count(body) when is_binary(body),
    do: length(String.split(body, ~r/\r\n|\r|\n/, trim: false))

  defp line_count(_), do: 0

  defp active_packets(packets) do
    packets
    |> Enum.filter(fn packet ->
      value(packet, :status) in ["submitted", "awaiting"] or partial_acceptance?(packet)
    end)
    |> Enum.sort_by(&sort_date(&1, :updated_at), :desc)
    |> Enum.take(3)
  end

  defp recent_replies(packets) do
    packets
    |> Enum.map(fn packet -> {packet, last_response(packet)} end)
    |> Enum.reject(fn {_packet, event} -> is_nil(event) end)
    |> Enum.sort_by(fn {_packet, event} -> value(event, :date, "") end, :desc)
    |> Enum.take(2)
  end

  defp last_response(packet) do
    packet
    |> value(:events, [])
    |> Enum.reverse()
    |> Enum.find(&(value(&1, :kind) == "response"))
  end

  defp partial_acceptance?(packet) do
    value(packet, :status) == "accepted" and
      length(value(packet, :accepted_piece_ids, []) || []) <
        length(value(packet, :piece_ids, []) || [])
  end

  defp active_status(packet) do
    cond do
      partial_acceptance?(packet) -> "Partly accepted · awaiting reply"
      value(packet, :status) == "submitted" -> "Submitted"
      value(packet, :status) == "awaiting" -> "Awaiting reply"
      true -> "Awaiting reply"
    end
  end

  defp reply_status(packet, event) do
    status = value(event, :status, value(packet, :status))

    cond do
      status == "accepted" and partial_acceptance?(packet) -> "Partly accepted"
      status == "accepted" -> "Accepted"
      status == "declined" -> "Declined"
      status == "withdrawn" -> "Withdrawn"
      true -> "Reply recorded"
    end
  end

  defp shortlisted(journals),
    do:
      journals
      |> Enum.filter(&(Still.Correspondence.active_journal?(&1) && truthy?(&1.shortlisted)))
      |> Enum.take(3)

  defp journal_packets(packets, id) do
    packets
    |> Enum.filter(&(value(&1, :journal_id) == id))
    |> Enum.sort_by(&sort_date(&1, :updated_at), :desc)
  end

  defp journal_for(journals, id), do: Enum.find(journals, &(value(&1, :id) == id))

  defp journal_name(journals, id) do
    case journal_for(journals, id) do
      nil -> nil
      journal -> value(journal, :name)
    end
  end

  defp packet_pieces(packet, pieces) do
    packet
    |> value(:piece_ids, [])
    |> Enum.map(fn id -> Enum.find(pieces, &(value(&1, :id) == id)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(3)
  end

  defp packet_date(packet) do
    snapshot = value(packet, :snapshot, %{}) || %{}
    display_date(value(snapshot, :date, value(packet, :updated_at)))
  end

  defp sort_date(packet, key), do: value(packet, key, "") |> to_string()

  defp display_date(nil), do: "Date not recorded"

  defp display_date(%Date{} = date),
    do: Calendar.strftime(date, "%d %b %Y") |> String.replace_prefix("0", "")

  defp display_date(%DateTime{} = date),
    do: date |> DateTime.to_date() |> display_date()

  defp display_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        display_date(date)

      _ ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> display_date(datetime)
          _ -> value
        end
    end
  end

  defp display_date(_), do: "Date not recorded"

  defp summary_text(value, max_length) when is_binary(value) do
    value = String.trim(value)

    if String.length(value) > max_length do
      String.slice(value, 0, max_length - 1) <> "…"
    else
      value
    end
  end

  defp summary_text(_, _), do: ""

  defp place_policy("allowed"), do: "Allowed"
  defp place_policy("not_allowed"), do: "Not allowed"
  defp place_policy(value), do: value

  defp has_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp has_text?(_), do: false

  defp truthy?(value), do: value in [true, "true", "on", 1]
end
