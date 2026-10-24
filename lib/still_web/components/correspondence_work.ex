defmodule StillWeb.CorrespondenceWork do
  @moduledoc "Manuscript-centered presentation for a piece and its correspondence."
  use StillWeb, :html

  alias Still.Poems

  attr :piece, :map, default: nil
  attr :revisions, :list, default: []
  attr :history, :list, default: []

  def detail(assigns) do
    ~H"""
    <section :if={@piece} class="corr-page corr-piece-page editorial-work">
      <div class="corr-breadcrumb">
        <.link patch={~p"/correspondence/writing"}>Writing</.link>
      </div>

      <header class="editorial-work-heading">
        <div>
          <h1>{title(@piece)}</h1>
        </div>
        <div class="editorial-work-actions">
          <.link navigate={~p"/writing/#{value(@piece, :id)}/edit"} class="corr-text-link">
            Return to Now to revise <span aria-hidden="true">↗</span>
          </.link>
          <.link
            patch={~p"/correspondence/packets/new?piece=#{value(@piece, :id)}"}
            class="corr-button"
          >Prepare another submission <span aria-hidden="true">→</span></.link>
        </div>
      </header>

      <div class="editorial-work-layout">
        <article class="corr-manuscript editorial-work-manuscript" aria-label="Current manuscript">
          <div class="editorial-work-revision">
            Current revision · revised {date(value(@piece, :updated_at))}
          </div>
          <pre>{@piece.body}</pre>
        </article>

        <aside
          id="work-history"
          class="corr-history editorial-work-rail"
          aria-label="Manuscript history"
        >
          <section class="editorial-work-section" aria-labelledby="work-correspondence-title">
            <div class="editorial-work-section-heading">
              <h2 id="work-correspondence-title">Its correspondence</h2>
              <span>{length(@history)} {plural(length(@history), "record", "records")}</span>
            </div>
            <article
              :for={row <- @history}
              id={"piece-history-#{value(row.packet, :id)}"}
              class="editorial-work-event"
            >
              <div class="editorial-work-event-top">
                <span class={"editorial-work-status status-#{work_status(row.packet, value(@piece, :id))}"}>
                  {status_label(row.packet, value(@piece, :id))}
                </span>
                <span :if={row.snapshot} class="editorial-work-date">
                  Sent {date(value(value(row.packet, :snapshot), :date))}
                </span>
                <span :if={!row.snapshot} class="editorial-work-date">In preparation</span>
              </div>
              <h3>
                <.link patch={~p"/correspondence/packets/#{value(row.packet, :id)}"}>
                  {journal_name(row)}
                </.link>
              </h3>
              <p class="editorial-work-packet-title">{value(row.packet, :title)}</p>
              <.link
                :if={row.journal}
                patch={~p"/correspondence/journals/#{value(row.journal, :id)}"}
                class="editorial-work-link"
              >Journal details <span aria-hidden="true">→</span></.link>

              <div :for={event <- events(row.packet)} class="editorial-work-response">
                <span class="editorial-work-date">{date(value(event, :date))}</span>
                <p :if={value(event, :kind) == "response"}>
                  <strong>{event_label(event)}</strong><span :if={
                    value(event, :note) not in [nil, ""]
                  }>
                    · {value(event, :note)}
                  </span>
                  <span :if={accepted_piece?(event, value(@piece, :id))}>
                    · This piece was accepted.
                  </span>
                </p>
                <p :if={value(event, :kind) == "status"}>
                  {event_label(event)}
                </p>
              </div>

              <details :if={row.snapshot} class="editorial-work-snapshot">
                <summary>Read the exact version sent</summary>
                <pre>{row.snapshot.body}</pre>
              </details>
              <.link
                :if={value(row.packet, :status) in ["declined", "withdrawn"]}
                patch={~p"/correspondence/packets/new?from=#{value(row.packet, :id)}"}
                class="editorial-work-link"
              >Prepare another packet with these pieces <span aria-hidden="true">→</span></.link>
            </article>
            <p :if={@history == []} class="editorial-work-empty">This piece has not traveled yet.</p>
          </section>

          <section class="editorial-work-section" aria-labelledby="work-revisions-title">
            <div class="editorial-work-section-heading">
              <h2 id="work-revisions-title">Earlier versions</h2>
              <span>{length(@revisions)} {plural(
                length(@revisions),
                "saved revision",
                "saved revisions"
              )}</span>
            </div>
            <details :for={revision <- @revisions} class="corr-version editorial-work-version">
              <summary>
                {title(revision)} · revised {date(
                  value(revision, :updated_at) || value(revision, :created_at)
                )}
              </summary>
              <pre>{revision.body}</pre>
            </details>
            <p :if={@revisions == []} class="editorial-work-empty">No earlier versions are saved.</p>
          </section>
        </aside>
      </div>
    </section>
    """
  end

  defp title(piece), do: Poems.display_title(piece)

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default)) || default

  defp value(_, _, default), do: default

  defp date(nil), do: "date not recorded"
  defp date(%Date{} = date), do: Calendar.strftime(date, "%d %b %Y")
  defp date(%DateTime{} = date), do: Calendar.strftime(date, "%d %b %Y")

  defp date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        date(datetime)

      _ ->
        case Date.from_iso8601(value) do
          {:ok, parsed_date} -> date(parsed_date)
          _ -> value
        end
    end
  end

  defp date(value), do: to_string(value)

  defp plural(1, singular, _plural), do: singular
  defp plural(_, _singular, plural), do: plural

  defp events(packet) do
    packet
    |> value(:events, [])
    |> Enum.filter(&(value(&1, :kind) in ["status", "response"]))
    |> Enum.reverse()
  end

  defp status(packet), do: value(packet, :status, "preparing")

  defp work_status(packet, piece_id) do
    accepted_piece_ids = value(packet, :accepted_piece_ids, []) || []

    cond do
      piece_id in accepted_piece_ids -> "accepted"
      status(packet) == "accepted" -> "considering"
      true -> status(packet)
    end
  end

  defp status_label(packet, piece_id) do
    case work_status(packet, piece_id) do
      "awaiting" -> "Awaiting reply"
      "submitted" -> "Submitted"
      "declined" -> "Declined"
      "accepted" -> "Accepted"
      "considering" -> "Still under consideration"
      "withdrawn" -> "Withdrawn"
      _ -> "Preparing"
    end
  end

  defp event_label(event) do
    case value(event, :status) do
      "declined" -> "Declined"
      "accepted" -> "Accepted"
      "withdrawn" -> "Withdrawn"
      "awaiting" -> "Marked awaiting a reply"
      "submitted" -> "Marked submitted"
      other -> other || "Response recorded"
    end
  end

  defp accepted_piece?(event, piece_id) do
    value(event, :status) == "accepted" and
      piece_id in (value(event, :accepted_piece_ids, []) || [])
  end

  defp journal_name(row),
    do: value(row.journal, :name) || value(row.packet, :journal_name) || "Journal not recorded"
end
