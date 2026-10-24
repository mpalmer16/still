defmodule StillWeb.WritingLive do
  use StillWeb, :live_view
  alias Still.{Desk, Poems, Storage, Writing}

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       recovery_waiting: false,
       recovery_problem: nil,
       gravity_field: [],
       field_waiting: [],
       field_transition: nil,
       gravity_timer: nil,
       resume_active: false
     )}
  end

  @impl true
  def handle_params(params, _, socket) do
    location = Storage.collection_location()
    {result, resume?, beside} = opening(socket.assigns.live_action, params, location)
    if socket.assigns.gravity_timer, do: Process.cancel_timer(socket.assigns.gravity_timer)

    case result do
      {:ok, piece} ->
        # A save patch acknowledges the submitted words without replacing newer typing.
        same_editor? =
          socket.assigns[:piece] && socket.assigns.piece.id == piece.id &&
            socket.assigns.live_action == :edit && socket.assigns[:editing]

        editing = socket.assigns.live_action != :show
        history = if piece.token, do: Poems.revisions(location, piece.id), else: {:ok, []}

        {revisions, problem} =
          case history do
            {:ok, values} -> {values, nil}
            {:error, message} -> {[], message}
          end

        cursor_problem = if editing && connected?(socket), do: remember(location, piece, beside)

        {:noreply,
         socket
         |> assign(
           piece: piece,
           draft: words(piece),
           location: location,
           editing: editing,
           draft_key: draft_key(location, piece),
           dirty: false,
           problem: problem || cursor_problem,
           revisions: revisions,
           notice: nil,
           recovery_waiting: false,
           resume_active: resume?,
           beside: beside,
           page_title: if(editing, do: "Now", else: Poems.display_title(piece)),
           delete_confirm: false
         )
         |> maybe_reset_field(same_editor?)
         |> settle(piece.body)}

      {:error, message} ->
        {:noreply,
         assign(socket,
           piece: nil,
           location: location,
           problem: message,
           page_title: "Now",
           gravity_field: [],
           editing: false
         )}
    end
  end

  defp opening(:now, %{"new" => "1"} = params, location),
    do: {{:ok, Poems.new(location)}, false, historical_beside(params["beside"])}

  defp opening(:new, params, location),
    do: {{:ok, Poems.new(location)}, false, historical_beside(params["beside"])}

  defp opening(:now, %{"beside" => id}, location),
    do: {{:ok, Poems.new(location)}, false, historical_beside(id)}

  defp opening(:now, _, location) do
    case Desk.current(location) do
      {:ok, %{saved: true, id: id, beside: beside}} ->
        {Poems.get(location, id), true, historical_beside(beside)}

      {:ok, %{saved: false, id: id, beside: beside}} ->
        {{:ok, %{Poems.new(location) | id: id}}, true, historical_beside(beside)}

      {:ok, nil} ->
        {{:ok, Poems.new(location)}, true, nil}

      {:error, message} ->
        {{:error, message}, false, nil}
    end
  end

  defp opening(_, params, location) do
    requested_id = params["id"]

    beside =
      case Desk.current(location) do
        {:ok, %{id: id, beside: beside}} when id == requested_id -> historical_beside(beside)
        _ -> nil
      end

    {Poems.get(location, params["id"]), true, beside}
  end

  defp historical_beside(id) when is_binary(id) do
    case Integer.parse(id) do
      {number, ""} -> historical_beside(number)
      _ -> nil
    end
  end

  defp historical_beside(id) when is_integer(id) do
    case Writing.get_entry(id) do
      %{origin: "before"} = entry -> entry
      _ -> nil
    end
  end

  defp historical_beside(_), do: nil

  defp remember(location, piece, beside) do
    case Desk.remember(location, %{
           id: piece.id,
           saved: piece.token != nil,
           beside: beside && beside.id
         }) do
      :ok -> nil
      {:error, message} -> message
    end
  end

  @impl true
  def handle_event("writing_changed", %{"writing" => attrs}, socket) do
    draft = draft_words(attrs, socket.assigns.piece)

    {:noreply,
     socket
     |> assign(draft: draft, dirty: draft != words(socket.assigns.piece), notice: nil)
     |> settle(draft.body)}
  end

  def handle_event("save_file", %{"writing" => attrs} = params, socket) do
    draft = draft_words(attrs, socket.assigns.piece)
    location = socket.assigns.location

    source_key =
      if is_binary(params["draft_key"]) &&
           String.starts_with?(params["draft_key"], "still:poem-draft:"),
         do: params["draft_key"],
         else: socket.assigns.draft_key

    case Poems.save(location, socket.assigns.piece, %{
           body: draft.body,
           title: blank_title(draft.title)
         }) do
      {:ok, piece} ->
        target_key = draft_key(location, piece)
        problem = remember(location, piece, socket.assigns.beside)

        {:noreply,
         socket
         |> assign(
           piece: piece,
           draft: words(piece),
           dirty: false,
           problem: problem,
           notice: "Saved on this Mac",
           draft_key: target_key
         )
         |> push_event("file-saved", %{
           id: piece.id,
           token: piece.token,
           body: piece.body,
           title: Poems.explicit_title(piece) || "",
           source_key: source_key,
           target_key: target_key
         })
         |> finish_save(piece, params["read"] in [true, "true"])}

      {:error, message} ->
        {:noreply,
         assign(socket,
           draft: draft,
           dirty: draft != words(socket.assigns.piece),
           problem: message,
           notice: nil
         )}
    end
  end

  def handle_event("new_file", %{"writing" => attrs}, socket) do
    draft = draft_words(attrs, socket.assigns.piece)

    if draft == words(socket.assigns.piece) do
      {:noreply, push_navigate(socket, to: ~p"/?new=1")}
    else
      {:noreply,
       assign(socket,
         draft: draft,
         dirty: true,
         notice: "Save these words before starting a new page. They are still here."
       )}
    end
  end

  def handle_event("refresh_file_folder", _, %{assigns: %{piece: %{token: nil}}} = socket) do
    location = Storage.collection_location()
    piece = %{socket.assigns.piece | scope: location.scope}

    {:noreply,
     assign(socket,
       location: location,
       piece: piece,
       problem: location.error || remember(location, piece, socket.assigns.beside),
       notice: nil
     )}
  end

  def handle_event("refresh_file_folder", _, socket), do: {:noreply, socket}

  def handle_event("file_recovery_status", %{"waiting" => waiting}, socket),
    do: {:noreply, assign(socket, recovery_waiting: waiting == true)}

  def handle_event("file_recovery_unavailable", _, socket),
    do:
      {:noreply,
       assign(socket,
         recovery_problem:
           "This browser cannot keep a local recovery copy. Keep this page open and save your words to the chosen collection or copy them somewhere safe."
       )}

  def handle_event("file_recovery_available", _, socket),
    do: {:noreply, assign(socket, recovery_problem: nil)}

  def handle_event("restore_file_local", _, socket),
    do: {:noreply, push_event(socket, "file-restore-local", %{})}

  def handle_event("keep_file", _, socket),
    do: {:noreply, push_event(socket, "file-keep-saved", %{})}

  def handle_event("request_delete", _, socket),
    do: {:noreply, assign(socket, delete_confirm: true)}

  def handle_event("cancel_delete", _, socket),
    do: {:noreply, assign(socket, delete_confirm: false)}

  def handle_event("confirm_delete", _, %{assigns: %{delete_confirm: true}} = socket) do
    case Poems.trash(socket.assigns.location, socket.assigns.piece) do
      {:ok, _} ->
        case Desk.clear(socket.assigns.location, socket.assigns.piece.id) do
          :ok ->
            {:noreply,
             socket
             |> push_event("file-trashed", %{key: socket.assigns.draft_key})
             |> push_navigate(to: ~p"/writing?trash=1")}

          {:error, message} ->
            {:noreply, assign(socket, problem: "Writing moved to Trash. " <> message)}
        end

      {:error, message} ->
        {:noreply, assign(socket, problem: message, delete_confirm: false)}
    end
  end

  def handle_event("confirm_delete", _, socket), do: {:noreply, socket}

  defp finish_save(socket, piece, true), do: push_navigate(socket, to: ~p"/writing/#{piece.id}")

  defp finish_save(socket, piece, false),
    do: push_patch(socket, to: ~p"/writing/#{piece.id}/edit", replace: true)

  @impl true
  def handle_info({:settle_before, id, body}, socket) do
    if socket.assigns.editing && socket.assigns.piece.id == id &&
         socket.assigns.draft.body == body do
      previous = Enum.reject(socket.assigns.gravity_field, & &1.departing)

      field =
        Writing.gravity_field(body,
          previous: previous,
          historical_only: true,
          title: socket.assigns.draft.title,
          list: true,
          exclude_ids: if(socket.assigns.beside, do: [socket.assigns.beside.id], else: [])
        )

      {:noreply, socket |> assign(:gravity_timer, nil) |> move_field(field, id, body)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:release_before, id, body, transition}, socket) do
    if socket.assigns.field_transition == transition && socket.assigns.editing &&
         socket.assigns.piece.id == id && socket.assigns.draft.body == body do
      {:noreply,
       assign(socket,
         gravity_field: socket.assigns.field_waiting,
         field_waiting: [],
         field_transition: nil
       )}
    else
      {:noreply, socket}
    end
  end

  defp settle(socket, body) do
    if socket.assigns.gravity_timer, do: Process.cancel_timer(socket.assigns.gravity_timer)

    if connected?(socket) && socket.assigns.editing do
      assign(
        socket,
        :gravity_timer,
        Process.send_after(self(), {:settle_before, socket.assigns.piece.id, body}, 1100)
      )
    else
      assign(socket, :gravity_timer, nil)
    end
  end

  defp maybe_reset_field(socket, true), do: socket

  defp maybe_reset_field(socket, _),
    do: assign(socket, gravity_field: [], field_waiting: [], field_transition: nil)

  defp move_field(socket, next, id, body) do
    existing = socket.assigns.gravity_field

    next =
      next
      |> Enum.with_index()
      |> Enum.map(fn {fragment, index} ->
        old = Enum.find(existing, &(&1.entry.id == fragment.entry.id))
        Map.merge(fragment, %{departing: false, delay: if(old, do: old.delay, else: index * 900)})
      end)

    leaving = Enum.reject(existing, fn old -> Enum.any?(next, &(&1.entry.id == old.entry.id)) end)

    if leaving == [] do
      assign(socket, gravity_field: next, field_waiting: [], field_transition: nil)
    else
      transition = make_ref()

      visible =
        Enum.map(existing, fn old ->
          Enum.find(next, &(&1.entry.id == old.entry.id)) || %{old | departing: true}
        end)

      Process.send_after(self(), {:release_before, id, body, transition}, 1900)
      assign(socket, gravity_field: visible, field_waiting: next, field_transition: transition)
    end
  end

  defp words(piece), do: %{body: piece.body, title: Poems.explicit_title(piece) || ""}
  defp blank_title(""), do: nil
  defp blank_title(title), do: title

  defp draft_words(attrs, piece) do
    body = Map.get(attrs, "body", piece.body)

    body =
      if is_binary(body) && String.replace(piece.body, ~r/\r\n?/, "\n") == body,
        do: piece.body,
        else: body

    %{body: body, title: Map.get(attrs, "title", Poems.explicit_title(piece) || "")}
  end

  defp draft_key(location, %{token: nil}), do: "still:poem-draft:#{location.draft_scope}:new"
  defp draft_key(location, piece), do: "still:poem-draft:#{location.scope}:#{piece.id}"

  defp date(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> Calendar.strftime(time, "%B %d, %Y · %H:%M UTC")
      _ -> value
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={if @editing, do: "write", else: "saved"}
      room_light={@room_light}
      light_open={@light_open}
      room_letters={@room_letters}
      letters_open={@letters_open}
      landscape_open={@landscape_open}
      places={@places}
      place={@place}
    >
      <div :if={is_nil(@piece)} class="writing-room">
        <p id="file-problem" role="alert" class="file-note">{@problem}</p>
        <p class="file-note">Your files and recovery copies have been left in place.</p>
        <.link navigate={~p"/storage"} class="quiet-link">Storage &amp; Backups</.link>
        <.link navigate={~p"/writing"} class="quiet-link">Saved writing</.link>
        <.link navigate={~p"/?new=1"} class="quiet-link">A blank page</.link>
      </div>
      <div :if={@piece && @editing} class="writing-room file-now">
        <h1 class="sr-only">Write now</h1>
        <div class="room-intro">
          <span class="room-line" aria-hidden="true"></span><span>{if @beside,
            do: "Alongside these words",
            else: "Now"}</span>
        </div>
        <p :if={@problem} id="file-problem" role="alert" class="file-note">{@problem}</p>
        <p :if={@recovery_problem} id="file-recovery-problem" role="alert" class="file-note">
          {@recovery_problem}
        </p>
        <aside :if={@recovery_waiting} id="file-recovery" class="recovery-note">
          <p>
            A local recovery copy is waiting. Bringing it back changes this page; Save updates the file.
          </p>
          <div class="recovery-actions">
            <button id="restore-file-local" phx-click="restore_file_local">Bring it back</button>
            <button
              id="keep-file"
              phx-click="keep_file"
              data-confirm="Discard this local recovery copy? The saved file stays unchanged."
            >Keep the file version</button>
          </div>
        </aside>
        <.form
          for={%{}}
          as={:writing}
          id="file-writing-form"
          phx-change="writing_changed"
          phx-submit="save_file"
          class="editor-form"
          data-authoritative={to_string(@piece.token != nil)}
          data-unsaved={to_string(@dirty)}
          data-save-blocked={to_string(@problem != nil)}
          data-recovery-safe="false"
          phx-mounted={JS.ignore_attributes(["data-unsaved", "data-recovery-safe"])}
        >
          <div
            id={"file-fields-#{@piece.id}"}
            phx-update="ignore"
            phx-hook="WritingFocus"
            class="file-page"
          >
            <label for="file-writing-title" class="sr-only">Title (optional)</label>
            <input
              id="file-writing-title"
              name="writing[title]"
              value={@draft.title}
              class="title-input"
              placeholder={
                if @draft.body == "",
                  do: "A title, if you like.",
                  else: Poems.display_title(%{title: nil, body: @draft.body})
              }
              title="Add a title, or leave this empty to use the first line."
              autocomplete="off"
              phx-debounce="700"
            />
            <label for="file-writing-body" class="sr-only">Writing</label>
            <textarea
              id="file-writing-body"
              name="writing[body]"
              class="writing-input file-editor"
              aria-describedby="file-keyboard-hint"
              phx-hook="FileRecovery"
              data-draft-key={@draft_key}
              data-persisted={Jason.encode!(words(@piece))}
              data-base-token={@piece.token || ""}
              data-resume-active={to_string(@resume_active)}
              data-document-id={@piece.id}
              spellcheck="true"
              autocapitalize="off"
              autocorrect="off"
              wrap="soft"
              placeholder="Begin anywhere."
              autofocus
              phx-debounce="700"
            >{"\n" <> @draft.body}</textarea>
          </div>
          <p id="file-keyboard-hint" class="sr-only">
            Tab indents. Shift+Tab removes an indent. Escape leaves the editor for the page controls. Command or Control+S saves; Command or Control+Enter saves and reads.
          </p>
          <footer class="writing-footer file-writing-footer">
            <span id="file-save-status" role="status" class="save-message">{cond do
              @notice -> @notice
              @dirty -> "Local draft · Save keeps these changes"
              @piece.token -> "Saved on this Mac"
              true -> "Local draft · not saved as a file"
            end}</span>
            <div class="footer-actions">
              <button id="save-file" type="submit" class="quiet-link">Save</button>
              <button id="new-file" type="button" class="quiet-link">New</button>
              <.link id="open-saved-writing" navigate={~p"/writing"} class="quiet-link">Saved writing</.link>
              <button
                :if={@piece.token}
                id="read-file"
                type="submit"
                name="read"
                value="true"
                class="quiet-link"
              >Read</button>
            </div>
          </footer>
        </.form>
        <p :if={!@location.configured} id="file-local-only" class="file-note file-storage-note">
          This page is kept only in this browser or Mac profile.
          <.link navigate={~p"/storage"}>Choose a collection folder</.link>
          before saving it as a file.
        </p>
        <p :if={@location.error && @location.error != @problem} class="file-note" role="alert">
          {@location.error}
        </p>
        <details class="file-location" id="file-save-destination">
          <summary>Save location</summary>
          <p :if={@location.configured}>
            <code :if={@piece.path}>{@piece.path}</code><span :if={!@piece.path}>The writing will be saved in a folder named for its title inside <code>{Path.join(@location.folder, "poems")}</code>.</span>
          </p>
          <p :if={!@location.configured}>No collection folder is chosen.</p>
          <.link navigate={~p"/storage"} class="quiet-link">Storage &amp; Backups</.link>
          <button
            :if={is_nil(@piece.token)}
            id="refresh-file-folder"
            phx-click="refresh_file_folder"
            class="quiet-link"
          >Refresh folder choice</button>
        </details>
        <aside :if={@beside} class="beside-room">
          <p class="section-whisper">Written beside</p><.link
            navigate={~p"/w/#{@beside.id}?read=1"}
            class="beside-title"
          >{Writing.opening(@beside)}</.link>
        </aside>
      </div>
      <StillWeb.Echoes.field :if={@piece && @editing} fragments={@gravity_field} />
      <article :if={@piece && !@editing} class="reading-room file-reading">
        <h1 class="file-title">{Poems.display_title(@piece)}</h1>
        <div id="file-text" class="file-lines">{@piece.body}</div>
        <p :if={@piece.body == ""} id="file-empty" class="file-note">An empty page, kept here.</p>
        <div class="file-reading-actions">
          <.link id="edit-file" navigate={~p"/writing/#{@piece.id}/edit"} class="quiet-link">Change these words</.link>
          <.link navigate={~p"/writing"} class="quiet-link">Saved writing</.link>
          <button id="delete-file" phx-click="request_delete" class="quiet-link">Delete</button>
        </div>
        <section
          :if={@delete_confirm}
          id="delete-confirmation"
          class="recovery-note"
          role="alertdialog"
          aria-label="Move writing to Trash?"
        >
          <p>
            Move this writing to Trash? Its earlier words will stay with it, and you can restore it.
          </p>
          <button id="confirm-delete-file" phx-click="confirm_delete" class="quiet-link">Move to Trash</button>
          <button phx-click="cancel_delete" class="quiet-link">Cancel</button>
        </section>
        <p :if={@problem} id="file-problem" class="file-note" role="alert">{@problem}</p>
        <details class="file-location">
          <summary>Text file</summary><code>{@piece.path}</code>
          <p :if={@piece.historical_source} id="historical-writing-source">
            {historical_source_label(@piece.historical_source)}. The original is preserved separately.
          </p>
        </details>
        <section :if={@revisions != []} id="file-revisions" class="file-history">
          <h2>Earlier words</h2>
          <details :for={revision <- @revisions} id={"file-revision-#{revision.id}"}>
            <summary>{date(revision.created_at)}</summary><h3 :if={revision.title}>
              {revision.title}
            </h3>
            <div class="file-lines">{revision.body}</div>
          </details>
        </section>
      </article>
    </Layouts.app>
    """
  end

  defp historical_source_label(source) do
    [
      "From the historical List “#{source["title"] || "Untitled"}”",
      if(source["notebook"], do: String.replace(source["notebook"], "/", " · ")),
      if(source["source_number"], do: "source " <> source["source_number"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end
end
