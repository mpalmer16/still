defmodule StillWeb.CorrespondenceHome do
  @moduledoc "The quiet overview for correspondence packets and their history."
  use StillWeb, :html

  attr :overview, :map, required: true
  attr :desk, :map, default: %{}
  attr :icons, :map, default: %{}

  def home(assigns) do
    packets = assigns.overview.packets || []
    pieces = Map.get(assigns.overview, :pieces, []) || []
    journals = Map.get(assigns.overview, :journals, []) || []
    preparing = preparing_packets(packets)
    awaiting = awaiting_packets(packets)
    responses = recent_responses(packets)

    assigns =
      assigns
      |> assign(:pieces, pieces)
      |> assign(:journals, journals)
      |> assign(:preparing_packets, preparing)
      |> assign(:awaiting_packets, awaiting)
      |> assign(:recent_responses, responses)
      |> assign(:packet_count, length(packets))

    ~H"""
    <section id="correspondence-home" class="corr-home" aria-labelledby="home-heading">
      <header class="corr-home-header">
        <h1 id="home-heading">Home</h1>
        <.link patch={~p"/correspondence/packets/new"} class="corr-home-primary-action">Prepare a packet</.link>
      </header>

      <nav class="corr-home-overview" aria-label="Correspondence collection">
        <.link patch={~p"/correspondence/writing"} class="corr-home-summary">
          <strong>{length(@pieces)}</strong><span>Works</span>
        </.link>
        <.link patch={~p"/correspondence/journals"} class="corr-home-summary">
          <strong>{length(@journals)}</strong><span>Places</span>
        </.link>
        <.link patch={~p"/correspondence/packets"} class="corr-home-summary">
          <strong>{@packet_count}</strong><span>Packets</span>
        </.link>
      </nav>

      <div class="corr-home-columns">
        <section class="corr-home-section corr-home-preparing" aria-labelledby="preparing-heading">
          <header class="corr-home-section-heading">
            <h2 id="preparing-heading">Preparing</h2>
            <.link patch={~p"/correspondence/packets"}>All packets</.link>
          </header>
          <article :for={packet <- @preparing_packets} class="corr-home-packet">
            <div class="corr-home-meta"><span>In preparation</span></div>
            <h3>
              <.link patch={~p"/correspondence/packets/#{packet.id}"}>{packet_title(packet)}</.link>
            </h3>
            <p class="corr-home-destination">
              {journal_name(@journals, value(packet, :journal_id)) || "No destination chosen"}
            </p>
            <p
              :if={packet_pieces(packet, Map.get(@overview, :packet_pieces, @pieces)) != []}
              class="corr-home-piece-links"
            >
              <span :for={
                {piece, index} <-
                  Enum.with_index(packet_pieces(packet, Map.get(@overview, :packet_pieces, @pieces)))
              }>
                <span :if={index > 0} aria-hidden="true"> · </span>
                <.link patch={~p"/correspondence/writing/#{piece.id}"}>{piece_title(piece)}</.link>
              </span>
            </p>
            <div class="corr-home-actions">
              <.link patch={~p"/correspondence/packets/#{packet.id}"}>Continue</.link>
            </div>
          </article>
          <p :if={@preparing_packets == []} class="corr-home-empty">No packets are being prepared.</p>
          <.link patch={~p"/correspondence/packets/new"} class="corr-home-create-link">Prepare a packet</.link>
        </section>

        <section class="corr-home-section corr-home-awaiting" aria-labelledby="awaiting-heading">
          <header class="corr-home-section-heading">
            <h2 id="awaiting-heading">Awaiting replies</h2>
            <.link patch={~p"/correspondence/packets"}>All packets</.link>
          </header>
          <article :for={packet <- @awaiting_packets} class="corr-home-packet">
            <div class="corr-home-meta">
              <span>{active_status(packet)}</span><time>{submitted_date(packet)}</time>
            </div>
            <h3>
              <.link patch={~p"/correspondence/packets/#{packet.id}"}>{journal_name(
                @journals,
                value(packet, :journal_id)
              ) || packet_title(packet)}</.link>
            </h3>
            <p
              :if={journal_name(@journals, value(packet, :journal_id))}
              class="corr-home-packet-title"
            >
              <.link patch={~p"/correspondence/packets/#{packet.id}"}>{packet_title(packet)}</.link>
            </p>
            <p class="corr-home-piece-links">
              <span :for={
                {piece, index} <-
                  Enum.with_index(packet_pieces(packet, Map.get(@overview, :packet_pieces, @pieces)))
              }>
                <span :if={index > 0} aria-hidden="true"> · </span>
                <.link patch={~p"/correspondence/writing/#{piece.id}"}>{piece_title(piece)}</.link>
              </span>
            </p>
          </article>
          <p :if={@awaiting_packets == []} class="corr-home-empty">
            Nothing is awaiting a reply just now.
          </p>
        </section>
      </div>

      <section class="corr-home-section corr-home-history" aria-labelledby="history-heading">
        <header class="corr-home-section-heading">
          <h2 id="history-heading">Recent responses</h2>
          <.link patch={~p"/correspondence/packets"}>Packet history</.link>
        </header>
        <article
          :for={{packet, event} <- @recent_responses}
          class="corr-home-packet corr-home-response"
        >
          <div class="corr-home-meta">
            <span>{reply_status(packet, event)}</span><time>{display_date(value(event, :date))}</time>
          </div>
          <p>
            <span>{journal_name(@journals, value(packet, :journal_id)) || packet_title(packet)}</span>
            <span aria-hidden="true"> · </span>
            <.link patch={~p"/correspondence/packets/#{packet.id}"}>{packet_title(packet)}</.link>
          </p>
          <p :if={has_text?(value(event, :note))} class="corr-home-response-note">
            {summary_text(value(event, :note), 160)}
          </p>
        </article>
        <p :if={@recent_responses == []} class="corr-home-empty">
          Recorded responses will appear here.
        </p>
      </section>
    </section>
    """
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default)) || default

  defp value(_, _, default), do: default

  defp preparing_packets(packets) do
    packets
    |> Enum.filter(&(value(&1, :status) == "preparing"))
    |> Enum.sort_by(&sort_date(&1), :desc)
    |> Enum.take(4)
  end

  defp awaiting_packets(packets) do
    packets
    |> Enum.filter(fn packet ->
      value(packet, :status) in ["submitted", "awaiting"] or partial_acceptance?(packet)
    end)
    |> Enum.sort_by(&submitted_sort_date/1, :desc)
    |> Enum.take(5)
  end

  defp recent_responses(packets) do
    packets
    |> Enum.flat_map(fn packet ->
      packet
      |> value(:events, [])
      |> Enum.filter(&(value(&1, :kind) == "response"))
      |> Enum.map(&{packet, &1})
    end)
    |> Enum.sort_by(fn {_packet, event} -> value(event, :date, "") end, :desc)
    |> Enum.take(5)
  end

  defp partial_acceptance?(packet) do
    value(packet, :status) == "accepted" and
      length(value(packet, :accepted_piece_ids, []) || []) <
        length(value(packet, :piece_ids, []) || [])
  end

  defp active_status(packet),
    do:
      if(partial_acceptance?(packet),
        do: "Partly accepted · awaiting reply",
        else: "Awaiting reply"
      )

  defp reply_status(packet, event) do
    status = value(event, :status, value(packet, :status))

    cond do
      status == "accepted" and partial_acceptance?(packet) -> "Partly accepted"
      status == "accepted" -> "Accepted"
      status == "declined" -> "Declined"
      status == "withdrawn" -> "Withdrawn"
      true -> "Response recorded"
    end
  end

  defp packet_pieces(packet, pieces) do
    packet
    |> value(:piece_ids, [])
    |> Enum.map(fn id -> Enum.find(pieces, &(value(&1, :id) == id)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(3)
  end

  defp piece_title(piece), do: Still.Poems.display_title(piece)
  defp packet_title(packet), do: value(packet, :title) || "Untitled packet"

  defp journal_name(journals, id) do
    case Enum.find(journals, &(value(&1, :id) == id)) do
      nil -> nil
      journal -> value(journal, :name)
    end
  end

  defp submitted_date(packet) do
    packet
    |> value(:events, [])
    |> Enum.find(&(value(&1, :kind) == "submitted"))
    |> case do
      nil -> "Date not recorded"
      event -> display_date(value(event, :date))
    end
  end

  defp submitted_sort_date(packet) do
    packet
    |> value(:events, [])
    |> Enum.find(&(value(&1, :kind) == "submitted"))
    |> case do
      nil -> ""
      event -> value(event, :date, "")
    end
  end

  defp sort_date(packet), do: value(packet, :updated_at, "") |> to_string()

  defp display_date(nil), do: "Date not recorded"

  defp display_date(%Date{} = date),
    do: Calendar.strftime(date, "%d %b %Y") |> String.replace_prefix("0", "")

  defp display_date(%DateTime{} = date), do: date |> DateTime.to_date() |> display_date()

  defp display_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        display_date(date)

      _ ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _} -> display_date(datetime)
          _ -> value
        end
    end
  end

  defp display_date(_), do: "Date not recorded"

  defp summary_text(value, max_length) when is_binary(value) do
    value = String.trim(value)

    if String.length(value) > max_length,
      do: String.slice(value, 0, max_length - 1) <> "…",
      else: value
  end

  defp summary_text(_, _), do: ""
  defp has_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp has_text?(_), do: false
end
