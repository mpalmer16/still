defmodule StillWeb.ReaderPacket do
  @moduledoc "A packet chooser that leaves the reader and its URL in place."
  use StillWeb, :live_component

  alias Still.Correspondence
  alias Still.Correspondence.ReaderPackets

  @impl true
  def mount(socket) do
    {:ok, reset(socket)}
  end

  @impl true
  def update(assigns, socket) do
    changed? =
      socket.assigns[:source] != assigns.source ||
        socket.assigns[:location] != assigns.location

    socket = if changed?, do: reset(socket), else: socket
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("open", _, socket) do
    {:noreply, socket |> reset() |> assign(open?: true) |> load_drafts()}
  end

  def handle_event("close", _, socket), do: {:noreply, assign(socket, open?: false)}

  def handle_event("refresh", _, socket), do: {:noreply, load_drafts(socket)}

  def handle_event("choose", %{"packet" => params}, socket) do
    {:noreply,
     assign(socket,
       destination: Map.get(params, "destination", "new"),
       title: Map.get(params, "title", socket.assigns.title),
       problem: nil
     )}
  end

  def handle_event("add", _, %{assigns: %{saved: saved}} = socket) when not is_nil(saved),
    do: {:noreply, socket}

  def handle_event("add", %{"packet" => params}, socket) do
    destination = Map.get(params, "destination", "new")
    title = Map.get(params, "title", socket.assigns.title)
    socket = assign(socket, destination: destination, title: title)

    result =
      if destination == "new" do
        ReaderPackets.create(socket.assigns.location, socket.assigns.source, title)
      else
        case Enum.find(socket.assigns.drafts, &(&1.id == destination)) do
          nil ->
            {:error, "Choose one of these drafts, or start a new packet."}

          packet ->
            ReaderPackets.add(
              socket.assigns.location,
              socket.assigns.source,
              packet.id,
              packet.token
            )
        end
      end

    case result do
      {:ok, packet} ->
        send(self(), :reader_packet_added)
        {:noreply, assign(socket, saved: packet, problem: nil)}

      {:error, message} ->
        {:noreply, assign(socket, problem: message)}
    end
  end

  defp reset(socket),
    do:
      assign(socket,
        open?: false,
        drafts: [],
        destination: "new",
        title: "",
        problem: nil,
        saved: nil
      )

  defp load_drafts(socket) do
    case Correspondence.draft_packets(socket.assigns.location) do
      {:ok, drafts} ->
        destination =
          if Enum.any?(drafts, &(&1.id == socket.assigns.destination)),
            do: socket.assigns.destination,
            else: "new"

        assign(socket, drafts: drafts, destination: destination, problem: nil)

      {:error, message} ->
        assign(socket, drafts: [], problem: message)
    end
  end

  defp packet_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp packet_title(_), do: "Untitled packet"

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="reader-packet">
      <button
        id="add-to-packet"
        type="button"
        class="quiet-link"
        phx-click={JS.push_focus() |> JS.push("open", target: @myself)}
        aria-haspopup="dialog"
        aria-expanded={to_string(@open?)}
      >Add to packet…</button>
      <div
        :if={@open?}
        id="reader-packet-overlay"
        class="reader-packet-overlay"
        phx-mounted={JS.focus_first(to: "#reader-packet-dialog")}
        phx-remove={JS.pop_focus()}
      >
        <.focus_wrap
          id="reader-packet-dialog"
          class="reader-packet-dialog"
          role="dialog"
          aria-modal="true"
          aria-labelledby="reader-packet-heading"
          phx-window-keydown="close"
          phx-key="Escape"
          phx-target={@myself}
          phx-click-away={JS.push("close", target: @myself)}
        >
          <div class="reader-packet-heading">
            <h2 id="reader-packet-heading">Add to packet</h2>
            <button
              id="reader-packet-close"
              type="button"
              class="quiet-link"
              phx-click="close"
              phx-target={@myself}
            >Keep reading</button>
          </div>
          <%= if @saved do %>
            <p
              id="reader-packet-notice"
              role="status"
              phx-mounted={JS.focus(to: "#reader-packet-close")}
            >
              This piece is in “{packet_title(@saved)}”.
            </p>
            <.link
              id="reader-packet-open"
              navigate={~p"/correspondence/packets/#{@saved.id}"}
              class="quiet-link"
            >Open packet →</.link>
          <% else %>
            <p class="reader-packet-hint">
              Choose a draft or start one. The piece stays in its notebook or folder.
            </p>
            <p :if={ReaderPackets.historical?(@source)} class="reader-packet-hint">
              A saved copy will join the packet; the original List stays here.
            </p>
            <.form
              for={%{}}
              as={:packet}
              id="reader-packet-form"
              phx-change="choose"
              phx-submit="add"
              phx-target={@myself}
            >
              <label for="reader-packet-destination">Packet</label>
              <select id="reader-packet-destination" name="packet[destination]">
                <option value="new" selected={@destination == "new"}>New packet</option>
                <option
                  :for={packet <- @drafts}
                  value={packet.id}
                  selected={@destination == packet.id}
                >
                  {packet_title(packet)} · {packet.journal_name || "No destination"} · {length(
                    packet.piece_ids
                  )} {if length(packet.piece_ids) == 1, do: "piece", else: "pieces"}
                </option>
              </select>
              <label :if={@destination == "new"} for="reader-packet-title">Packet title
              <span>(optional)</span></label>
              <input
                :if={@destination == "new"}
                id="reader-packet-title"
                name="packet[title]"
                value={@title}
                type="text"
                autocomplete="off"
              />
              <p :if={@drafts == [] && is_nil(@problem)} class="reader-packet-hint">
                There are no existing drafts. You can choose a destination later.
              </p>
              <p :if={@problem} id="reader-packet-problem" role="alert">{@problem}</p>
              <div class="reader-packet-actions">
                <button type="submit" class="quiet-link" phx-disable-with="Adding…">{if @destination ==
                                                                                            "new",
                                                                                          do:
                                                                                            "Create packet & add",
                                                                                          else:
                                                                                            "Add to packet"}</button>
                <button
                  id="reader-packet-refresh"
                  type="button"
                  class="quiet-link"
                  phx-click="refresh"
                  phx-target={@myself}
                >Refresh drafts</button>
              </div>
            </.form>
          <% end %>
        </.focus_wrap>
      </div>
    </div>
    """
  end
end
