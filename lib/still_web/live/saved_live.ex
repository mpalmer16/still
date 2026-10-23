defmodule StillWeb.SavedLive do
  use StillWeb, :live_view
  alias Still.{Desk, Poems, Storage}

  @impl true
  def mount(_, _, socket), do: {:ok, assign(socket, confirmation: nil, notice: nil)}
  @impl true
  def handle_params(params, _, socket), do: {:noreply, load(socket, params["trash"] == "1")}
  @impl true
  def handle_event("refresh_writing", _, socket),
    do: {:noreply, load(socket, socket.assigns.trash?)}

  def handle_event("restore_file", %{"id" => id}, socket) do
    case Poems.restore(socket.assigns.location, id) do
      {:ok, _} -> {:noreply, socket |> assign(:notice, "Writing restored.") |> load(true)}
      {:error, message} -> {:noreply, socket |> load(true) |> assign(:problem, message)}
    end
  end

  def handle_event("request_purge", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.pieces, &(&1.id == id)) do
      nil -> {:noreply, load(socket, true)}
      piece -> {:noreply, assign(socket, confirmation: piece)}
    end
  end

  def handle_event("cancel_purge", _, socket), do: {:noreply, assign(socket, confirmation: nil)}

  def handle_event(
        "confirm_purge",
        _,
        %{assigns: %{confirmation: %{id: id, token: token}}} = socket
      ) do
    case Poems.purge(socket.assigns.location, id, token, true) do
      :ok ->
        _ = Desk.clear(socket.assigns.location, id)

        {:noreply,
         socket
         |> assign(confirmation: nil, notice: "Writing permanently deleted.")
         |> load(true)}

      {:ok, _} ->
        _ = Desk.clear(socket.assigns.location, id)

        {:noreply,
         socket
         |> assign(confirmation: nil, notice: "Writing permanently deleted.")
         |> load(true)}

      {:error, message} ->
        {:noreply,
         socket |> assign(:confirmation, nil) |> load(true) |> assign(:problem, message)}
    end
  end

  def handle_event("confirm_purge", _, socket), do: {:noreply, socket}

  defp load(socket, trash?) do
    location = Storage.collection_location()

    result =
      cond do
        !location.available -> {:ok, []}
        trash? -> Poems.list_trash(location)
        true -> Poems.list(location)
      end

    {pieces, problem} =
      case result do
        {:ok, pieces} -> {pieces, location.error}
        {:error, message} -> {[], message}
      end

    assign(socket,
      confirmation: nil,
      page_title: if(trash?, do: "Trash", else: "Saved writing"),
      location: location,
      pieces: pieces,
      problem: problem,
      trash?: trash?
    )
  end

  defp opening(body),
    do:
      body
      |> String.split("\n")
      |> Enum.drop_while(&(String.trim(&1) == ""))
      |> Enum.take(3)
      |> Enum.join("\n")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active="saved"
      room_light={@room_light}
      light_open={@light_open}
      room_letters={@room_letters}
      letters_open={@letters_open}
      landscape_open={@landscape_open}
      places={@places}
      place={@place}
    >
      <div class="file-library">
        <header class="file-heading">
          <span class="section-whisper">{if @trash?,
            do: "Earlier pages, set aside",
            else: "The pages you have kept"}</span>
          <h1>{if @trash?, do: "Trash.", else: "Saved writing."}</h1>
          <.link id="new-writing" navigate={~p"/?new=1"} class="file-link">A blank page</.link>
        </header>
        <p :if={!@location.configured} id="writing-local-only" class="file-note">
          No collection folder is chosen. You can draft in Now;
          <.link navigate={~p"/storage"}>choose a folder</.link>
          before saving as a file.
        </p>
        <p :if={@problem} id="writing-problem" role="alert" class="file-note">{@problem}</p>
        <p :if={@notice} role="status" class="file-note">{@notice}</p>
        <section
          :if={@confirmation}
          id="purge-confirmation"
          class="recovery-note"
          role="alertdialog"
          aria-label="Permanently delete writing?"
        >
          <p>
            Permanently delete <strong>{Poems.display_title(@confirmation)}</strong>
            and all its earlier words? This cannot be undone in Still.
          </p>
          <button id="confirm-purge-file" phx-click="confirm_purge" class="quiet-link">Delete permanently</button>
          <button phx-click="cancel_purge" class="quiet-link">Cancel</button>
        </section>
        <div id="writing-shelf" class="file-shelf">
          <article :for={piece <- @pieces} id={"saved-#{piece.id}"} class="file-piece">
            <.link :if={!@trash?} navigate={~p"/writing/#{piece.id}"}>
              <span class="file-piece-title">{Poems.display_title(piece)}</span>
              <span class="file-opening">{opening(piece.body)}</span>
            </.link>
            <div :if={@trash?}>
              <span class="file-piece-title">{Poems.display_title(piece)}</span>
              <span class="file-opening">{opening(piece.body)}</span>
              <div class="file-trash-actions">
                <button phx-click="restore_file" phx-value-id={piece.id} class="quiet-link">Restore</button>
                <button phx-click="request_purge" phx-value-id={piece.id} class="quiet-link">Delete permanently…</button>
              </div>
            </div>
          </article>
        </div>
        <p :if={@pieces == [] && !@problem} id="writing-empty" class="file-empty">
          {if @trash?, do: "Nothing in Trash.", else: "The page can begin whenever you are ready."}
        </p>
        <footer class="file-collection-note">
          <.link :if={!@trash?} id="open-trash" patch={~p"/writing?trash=1"} class="quiet-link">Trash</.link>
          <.link :if={@trash?} id="back-saved" patch={~p"/writing"} class="quiet-link">Saved writing</.link>
          <.link navigate={~p"/"} class="quiet-link">Return to Now</.link>
          <button id="refresh-writing" phx-click="refresh_writing" class="quiet-link">Refresh collection</button>
          <.link navigate={~p"/storage"} class="quiet-link">Storage &amp; Backups</.link>
          <p>Now also lets you return to this browser or Mac profile’s local draft.</p>
          <details :if={@location.configured}>
            <summary>Collection folder</summary><code>{Path.join(@location.folder, "poems")}</code><p>
              Writing is kept as ordinary text files, separate from the historical Lists.
            </p>
          </details>
        </footer>
      </div>
    </Layouts.app>
    """
  end
end
