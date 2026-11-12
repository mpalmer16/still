defmodule StillWeb.CorrespondenceDirectories do
  @moduledoc "Compact browse tables for correspondence works and packets."
  use StillWeb, :html

  attr :works, :map, required: true

  def works(assigns) do
    ~H"""
    <section id="works-directory" class="corr-directory" aria-labelledby="works-heading">
      <header class="corr-directory-heading">
        <h1 id="works-heading">Works</h1>
      </header>
      <.form
        for={%{}}
        id="works-filters"
        class="corr-directory-toolbar"
        phx-change="filter_works"
        phx-submit="filter_works"
      >
        <label for="works-query" class="sr-only">Search works</label>
        <label class="corr-directory-search">
          <input
            id="works-query"
            type="search"
            name="works[q]"
            value={@works.filters["q"]}
            placeholder="Title, notebook, or words"
            phx-debounce="250"
            autocomplete="off"
          />
        </label>
        <details class="corr-directory-filters corr-popover">
          <summary>{filter_summary(@works.filters, [:status, :notebook])}</summary>
          <div class="corr-popover-panel">
            <label>
              Notebook
              <select name="works[notebook]">
                <option value="all" selected={@works.filters["notebook"] == "all"}>
                  All notebooks
                </option>
                <option
                  :for={notebook <- @works.notebook_options}
                  value={notebook}
                  selected={notebook == @works.filters["notebook"]}
                >
                  {notebook}
                </option>
              </select>
            </label>
            <label>
              Status
              <select name="works[status]"><option
                :for={
                  {label, value} <- [
                    {"Any status", "all"},
                    {"Ready", "ready"},
                    {"Preparing", "preparing"},
                    {"Submitted", "submitted"},
                    {"Awaiting", "awaiting"},
                    {"Accepted", "accepted"},
                    {"Declined", "declined"},
                    {"Withdrawn", "withdrawn"}
                  ]
                }
                value={value}
                selected={value == @works.filters["status"]}
              >
                {label}
              </option></select>
            </label>
            <label>
              Sort
              <select name="works[sort]"><option
                :for={
                  {label, value} <- [
                    {"Notebook order", "notebook"},
                    {"Title", "title"},
                    {"Recent packet", "activity"}
                  ]
                }
                value={value}
                selected={value == @works.filters["sort"]}
              >
                {label}
              </option></select>
            </label>
            <label>
              Sort
              <select name="works[direction]"><option
                value="asc"
                selected={@works.filters["direction"] == "asc"}
              >
                Ascending
              </option><option value="desc" selected={@works.filters["direction"] == "desc"}>
                Descending
              </option></select>
            </label>
            <.link patch={~p"/correspondence/writing"} class="corr-text-link">Reset view</.link>
          </div>
        </details>
      </.form>
      <p class="corr-result-count" role="status" aria-live="polite">
        {@works.matched} {plural(@works.matched, "work", "works")}
      </p>
      <div
        :if={@works.rows != []}
        class="corr-table-scroll"
        role="region"
        aria-label="Works table"
        tabindex="0"
      >
        <table class="corr-table">
          <caption class="sr-only">Works ready for or involved in correspondence</caption>
          <thead>
            <tr>
              <th scope="col">Work</th><th scope="col">Notebook / List</th><th scope="col">
                Correspondence
              </th><th scope="col">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @works.rows} id={"work-directory-row-#{row.piece.id}"}>
              <th scope="row">
                <.link patch={~p"/correspondence/writing/#{row.piece.id}"}>{row.title}</.link>
              </th>
              <td>
                {value(row.piece, :notebook) || "No notebook"}<span :if={
                  value(row.piece, :list_label)
                }> · List {value(row.piece, :list_label)}</span>
              </td>
              <td>
                <span class={"editorial-work-status status-#{row.status}"}>{status_label(row.status)}</span><span :if={
                  row.packet_count > 0
                }> · {row.packet_count} {plural(row.packet_count, "packet", "packets")}</span>
                <p :if={state_summary(row.status_counts, row.status) != ""} class="corr-meta">
                  Also {state_summary(row.status_counts, row.status)}
                </p>
              </td>
              <td class="corr-directory-actions">
                <.link patch={~p"/correspondence/writing/#{row.piece.id}"}>Open</.link><.link patch={
                  ~p"/correspondence/packets/new?piece=#{row.piece.id}"
                }>Prepare packet</.link><.link
                  :if={row.latest_packet}
                  patch={~p"/correspondence/packets/#{row.latest_packet.id}"}
                >Latest packet</.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p :if={@works.rows == []} class="corr-directory-empty">No works match this view.</p>
      <.pagination directory={@works} event="works_page" />
    </section>
    """
  end

  attr :packets, :map, required: true

  def packets(assigns) do
    ~H"""
    <section id="packets-directory" class="corr-directory" aria-labelledby="packets-heading">
      <header class="corr-directory-heading">
        <h1 id="packets-heading">Packets</h1><.link
          patch={~p"/correspondence/packets/new"}
          class="corr-button"
        >Prepare a packet <span>+</span></.link>
      </header>
      <.form
        for={%{}}
        id="packets-filters"
        class="corr-directory-toolbar"
        phx-change="filter_packets"
        phx-submit="filter_packets"
      >
        <label for="packets-query" class="sr-only">Search packets</label>
        <label class="corr-directory-search">
          <input
            id="packets-query"
            type="search"
            name="packets[q]"
            value={@packets.filters["q"]}
            placeholder="Title, destination, or work"
            phx-debounce="250"
            autocomplete="off"
          />
        </label>
        <details class="corr-directory-filters corr-popover">
          <summary>{filter_summary(@packets.filters, [:status, :destination])}</summary>
          <div class="corr-popover-panel">
            <label>
              Status
              <select name="packets[status]"><option
                :for={
                  {label, value} <- [
                    {"Any status", "all"},
                    {"Preparing", "preparing"},
                    {"Submitted", "submitted"},
                    {"Awaiting", "awaiting"},
                    {"Declined", "declined"},
                    {"Accepted", "accepted"},
                    {"Withdrawn", "withdrawn"}
                  ]
                }
                value={value}
                selected={value == @packets.filters["status"]}
              >
                {label}
              </option></select>
            </label>
            <label>
              Destination
              <select name="packets[destination]"><option
                value="all"
                selected={@packets.filters["destination"] == "all"}
              >
                Any destination
              </option><option value="chosen" selected={@packets.filters["destination"] == "chosen"}>
                Chosen
              </option><option
                value="unchosen"
                selected={@packets.filters["destination"] == "unchosen"}
              >
                Not chosen
              </option></select>
            </label>
            <label>
              Order
              <select name="packets[sort]"><option
                value="recent"
                selected={@packets.filters["sort"] == "recent"}
              >
                Recent activity
              </option><option value="title" selected={@packets.filters["sort"] == "title"}>
                Title
              </option><option
                value="destination"
                selected={@packets.filters["sort"] == "destination"}
              >
                Destination
              </option><option value="sent_date" selected={@packets.filters["sort"] == "sent_date"}>
                Sent date
              </option></select>
            </label>
            <label>
              Direction
              <select name="packets[direction]"><option
                value="desc"
                selected={@packets.filters["direction"] == "desc"}
              >
                Newest first
              </option><option value="asc" selected={@packets.filters["direction"] == "asc"}>
                Oldest first
              </option></select>
            </label>
            <.link patch={~p"/correspondence/packets"} class="corr-text-link">Reset view</.link>
          </div>
        </details>
      </.form>
      <p class="corr-result-count" role="status" aria-live="polite">
        {@packets.matched} {plural(@packets.matched, "packet", "packets")}
      </p>
      <div
        :if={@packets.rows != []}
        class="corr-table-scroll"
        role="region"
        aria-label="Packets table"
        tabindex="0"
      >
        <table class="corr-table">
          <caption class="sr-only">
            Correspondence packets with destination, contents, status, and date
          </caption>
          <thead>
            <tr>
              <th scope="col">Packet</th><th scope="col">Destination</th><th scope="col">Contents</th><th scope="col">
                Status
              </th><th scope="col">Sent</th><th scope="col">Open</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @packets.rows} id={"packet-directory-row-#{row.packet.id}"}>
              <th scope="row">
                <.link patch={~p"/correspondence/packets/#{row.packet.id}"}>{value(row.packet, :title) ||
                  "Untitled packet"}</.link>
              </th>
              <td>{row.destination_name}</td>
              <td>
                <span :for={{piece, index} <- Enum.with_index(row.pieces)}><span :if={index > 0}> · </span>{Still.Poems.display_title(
                  piece
                )}</span><span :if={row.piece_count > length(row.pieces)}> · {row.piece_count} total</span><span :if={
                  row.piece_count == 0
                }>No works</span>
              </td>
              <td>
                <span class={"editorial-work-status status-#{value(row.packet,:status)}"}>{status_label(
                  value(row.packet, :status)
                )}</span>
                <p :if={value(row.packet, :accepted_piece_ids) not in [nil, []]}>
                  {length(value(row.packet, :accepted_piece_ids))} of {row.piece_count} accepted
                </p>
              </td>
              <td>{date(row.date)}</td><td>
                <.link patch={~p"/correspondence/packets/#{row.packet.id}"}>Open packet →</.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p :if={@packets.rows == []} class="corr-directory-empty">No packets match this view.</p>
      <.pagination directory={@packets} event="packets_page" />
    </section>
    """
  end

  attr :directory, :map, required: true
  attr :event, :string, required: true

  defp pagination(assigns) do
    ~H"""
    <nav :if={@directory.pages > 1} class="corr-pagination" aria-label="Directory pages">
      <button
        type="button"
        phx-click={@event}
        phx-value-page={@directory.page - 1}
        disabled={@directory.page == 1}
      >Previous</button>
      <span>Page {@directory.page} of {@directory.pages}</span>
      <button
        type="button"
        phx-click={@event}
        phx-value-page={@directory.page + 1}
        disabled={@directory.page == @directory.pages}
      >Next</button>
    </nav>
    """
  end

  defp value(m, k) when is_map(m), do: Map.get(m, k, Map.get(m, to_string(k)))
  defp value(_, _), do: nil
  defp plural(1, one, _), do: one
  defp plural(_, _, many), do: many
  defp status_label("ready"), do: "Ready"
  defp status_label("preparing"), do: "Preparing"
  defp status_label("submitted"), do: "Submitted"
  defp status_label("awaiting"), do: "Awaiting"
  defp status_label("accepted"), do: "Accepted"
  defp status_label("declined"), do: "Declined"
  defp status_label("withdrawn"), do: "Withdrawn"
  defp status_label(_), do: "Unknown"

  defp filter_summary(filters, keys) do
    count = Enum.count(keys, &(Map.get(filters, Atom.to_string(&1)) not in [nil, "all"]))
    if count == 0, do: "Filters", else: "Filters (#{count})"
  end

  defp state_summary(counts, primary) do
    counts
    |> Enum.reject(fn {state, count} -> state == primary or count == 0 end)
    |> Enum.sort_by(fn {state, _} -> state end)
    |> Enum.map_join(" · ", fn {state, count} ->
      "#{count} #{status_label(state) |> String.downcase()}"
    end)
  end

  defp date(nil), do: "Not sent"
  defp date(%Date{} = d), do: Calendar.strftime(d, "%d %b %Y")
  defp date(%DateTime{} = d), do: Calendar.strftime(d, "%d %b %Y")

  defp date(v) when is_binary(v) do
    case Date.from_iso8601(String.slice(v, 0, 10)) do
      {:ok, d} -> date(d)
      _ -> v
    end
  end

  defp date(_), do: "Not dated"
end
