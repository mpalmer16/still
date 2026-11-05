defmodule StillWeb.SavedLive do
  use StillWeb, :live_view
  alias Still.{Desk, Poems, Storage}

  @impl true
  def mount(_, _, socket),
    do:
      {:ok,
       assign(socket,
         confirmation: nil,
         notice: nil,
         reconciliation: %{missing: [], ambiguous: []}
       )}

  @impl true
  def handle_params(params, _, socket), do: {:noreply, load(socket, params["trash"] == "1")}
  @impl true
  def handle_event("refresh_writing", _, socket),
    do: {:noreply, load(socket, socket.assigns.trash?)}

  def handle_event("relink_file", %{"piece_id" => id, "path" => path}, socket) do
    case Poems.relink(socket.assigns.location, id, path) do
      {:ok, _piece} ->
        {:noreply, socket |> assign(:notice, "Writing location updated.") |> load(false)}

      {:error, message} ->
        {:noreply, socket |> load(false) |> assign(:problem, message)}
    end
  end

  def handle_event("adopt_file", %{"path" => path}, socket) do
    case Poems.adopt(socket.assigns.location, path) do
      {:ok, _piece} ->
        {:noreply, socket |> assign(:notice, "Text file added to Saved writing.") |> load(false)}

      {:error, message} ->
        {:noreply, socket |> load(false) |> assign(:problem, message)}
    end
  end

  def handle_event("resolve_file_conflict", %{"piece_id" => id, "choice" => choice}, socket)
      when choice in ["keep_file", "use_proposed"] do
    case Poems.resolve_pending(socket.assigns.location, id, choice) do
      {:ok, _result} ->
        {:noreply, socket |> assign(:notice, "Writing conflict resolved.") |> load(false)}

      :ok ->
        {:noreply, socket |> assign(:notice, "Writing conflict resolved.") |> load(false)}

      {:error, message} ->
        {:noreply, socket |> load(false) |> assign(:problem, message)}
    end
  end

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

    {reconciliation, reconciliation_problem} =
      if location.available and not trash? do
        case Poems.reconciliation(location) do
          {:ok, result} -> {result, nil}
          {:error, message} -> {%{missing: [], ambiguous: []}, message}
        end
      else
        {%{missing: [], ambiguous: []}, nil}
      end

    pending_reviews =
      if location.available and not trash? do
        case Poems.pending_recovery(location) do
          {:ok, reviews} -> reviews
          _ -> []
        end
      else
        []
      end

    assign(socket,
      confirmation: nil,
      page_title: if(trash?, do: "Trash", else: "Saved writing"),
      location: location,
      pieces: pieces,
      submission_focus: Still.Correspondence.writing_status(location).focused,
      problem: problem || reconciliation_problem,
      reconciliation: reconciliation,
      pending_reviews: pending_reviews,
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
          No collection folder is chosen. You can draft in Write;
          <.link navigate={~p"/storage"}>choose a folder</.link>
          before saving as a file.
        </p>
        <p :if={@problem} id="writing-problem" role="alert" class="file-note">{@problem}</p>
        <p :if={@notice} role="status" class="file-note">{@notice}</p>
        <section :if={@pending_reviews != []} id="file-conflict-review" class="recovery-note">
          <h2>Writing changed in two places</h2>
          <p>
            Review both versions before choosing which words belong in the file. The other version will remain in Earlier words.
          </p>
          <article :for={review <- @pending_reviews} id={"pending-review-#{review.id}"}>
            <h3>{review.path}</h3>
            <p :if={review.problem} role="alert">{review.problem}</p>
            <div class="file-conflict-versions">
              <section>
                <h4>Words now in the file</h4>
                <pre>{review.current_body}</pre>
              </section>
              <section>
                <h4>Words Still was ready to save</h4>
                <pre>{review.proposed_body}</pre>
              </section>
            </div>
            <button
              phx-click="resolve_file_conflict"
              phx-value-piece_id={review.id}
              phx-value-choice="keep_file"
              class="quiet-link"
            >Keep the file version</button>
            <button
              phx-click="resolve_file_conflict"
              phx-value-piece_id={review.id}
              phx-value-choice="use_proposed"
              class="quiet-link"
            >Use Still's saved words</button>
          </article>
        </section>
        <section :if={!@trash? && @location.available} id="file-reconciliation" class="recovery-note">
          <h2>File locations</h2>
          <p :if={@reconciliation.missing != [] || @reconciliation.ambiguous != []}>
            Some saved writing needs a location choice.
          </p>
          <p :if={@reconciliation.missing == [] && @reconciliation.ambiguous == []}>
            Add a readable text file when you want Still to keep its place here.
          </p>
          <ul>
            <li :for={missing <- @reconciliation.missing} id={"missing-file-#{missing.id}"}>
              <span>{Map.get(missing, :path) || Map.get(missing, :relative_path) || "Unknown location"}</span><span>File not found.</span>
              <form phx-submit="relink_file">
                <input type="hidden" name="piece_id" value={missing.id} />
                <label>
                  Enter its new relative path
                  <input name="path" required autocomplete="off" placeholder="Notebook 3/12" />
                </label>
                <button type="submit" class="quiet-link">Use this file</button>
              </form>
            </li>
            <li :for={item <- @reconciliation.ambiguous} id={"ambiguous-file-#{item.id}"}>
              <span>{item.relative_path}</span>
              <form phx-submit="relink_file">
                <input type="hidden" name="piece_id" value={item.id} />
                <label>
                  Choose its location
                  <select name="path" required>
                    <option :for={path <- item.candidates} value={path}>{path}</option>
                  </select>
                </label>
                <button type="submit" class="quiet-link">Use this file</button>
              </form>
            </li>
          </ul>
          <form id="adopt-text-file" phx-submit="adopt_file">
            <label>
              Recognize another text file by its relative path
              <input name="path" required autocomplete="off" placeholder="Notebook 2/12" />
            </label>
            <button type="submit" class="quiet-link">Add this file</button>
          </form>
        </section>
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
              <span :if={@submission_focus[piece.id]} class="submission-indicator">Correspondence</span>
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
          <.link navigate={~p"/"} class="quiet-link">Return to Write</.link>
          <button id="refresh-writing" phx-click="refresh_writing" class="quiet-link">Refresh collection</button>
          <.link navigate={~p"/storage"} class="quiet-link">Storage &amp; Backups</.link>
          <p>Write also lets you return to this browser or Mac profile’s local draft.</p>
          <details :if={@location.configured}>
            <summary>Collection folder</summary><code>{@location.folder}</code><p>
              Writing is kept as ordinary text files in the selected folder.
            </p>
          </details>
        </footer>
      </div>
    </Layouts.app>
    """
  end
end
