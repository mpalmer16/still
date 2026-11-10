defmodule StillWeb.WritingLive do
  use StillWeb, :live_view
  alias Still.{Correspondence, Desk, Poems, Storage, Writing}
  alias Still.Writing.Attention
  alias StillWeb.ReadingLinks

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
       resume_active: false,
       reading_echo: nil,
       echo_attention: nil,
       listening_line: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    Writing.with_collection_snapshot(fn -> load_params(params, socket) end, recover: true)
  end

  defp load_params(params, socket) do
    location = Storage.collection_location()
    discovery_problem = Still.Writing.Discovery.problem(location)
    {result, resume?, beside} = opening(socket.assigns.live_action, params, location)
    if socket.assigns.gravity_timer, do: Process.cancel_timer(socket.assigns.gravity_timer)

    case result do
      {:ok, piece} ->
        # A save patch acknowledges the submitted words without replacing newer typing.
        same_editor? =
          socket.assigns[:piece] && socket.assigns.piece.id == piece.id &&
            socket.assigns.live_action == :edit && socket.assigns[:editing]

        editing = socket.assigns.live_action != :show
        reading_echo = if editing, do: nil, else: Writing.saved_echo(piece)
        history = if piece.token, do: Poems.revisions(location, piece.id), else: {:ok, []}

        {revisions, problem} =
          case history do
            {:ok, values} -> {values, nil}
            {:error, message} -> {[], message}
          end

        status = Correspondence.writing_status(location)
        cursor_problem = if editing && connected?(socket), do: remember(location, piece, beside)

        {:noreply,
         socket
         |> assign(
           piece: piece,
           submission_focus: Map.get(status.focused, piece.id, false),
           submitted: MapSet.member?(status.submitted, piece.id),
           draft: words(piece),
           location: location,
           save_location: Still.Writing.Files.save_location(location, piece.relative_path),
           editing: editing,
           wander_return:
             if(
               socket.assigns.live_action == :edit && params["from"] == "wander" && piece.entry_id,
               do: ReadingLinks.wander(piece.entry_id)
             ),
           notebooks: Writing.notebooks(),
           draft_key: draft_key(location, piece),
           dirty: false,
           problem: problem || cursor_problem || discovery_problem,
           revisions: revisions,
           notice: nil,
           recovery_waiting: false,
           resume_active: resume?,
           reading_echo: reading_echo,
           echo_attention: if(same_editor?, do: socket.assigns.echo_attention),
           listening_line: nil,
           beside: beside,
           page_title: if(editing, do: "Write", else: Poems.display_title(piece)),
           delete_confirm: false
         )
         |> maybe_reset_field(same_editor?)
         |> settle(piece.body)}

      {:error, message} ->
        {:noreply,
         assign(socket,
           piece: nil,
           location: location,
           problem: message || discovery_problem,
           page_title: "Write",
           gravity_field: [],
           reading_echo: nil,
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
  def handle_event(
        "toggle_submission_focus",
        _,
        %{assigns: %{piece: %{token: token} = piece}} = socket
      )
      when is_binary(token) do
    marked? = !socket.assigns.submission_focus

    case Correspondence.set_focus(socket.assigns.location, piece.id, marked?) do
      :ok -> {:noreply, assign(socket, submission_focus: marked?)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("writing_changed", %{"writing" => attrs}, socket) do
    draft = draft_words(attrs, socket.assigns.piece)

    socket =
      if is_nil(socket.assigns.piece.token) &&
           draft.relative_path != socket.assigns.draft.relative_path do
        assign(
          socket,
          :save_location,
          Still.Writing.Files.save_location(socket.assigns.location, draft.relative_path)
        )
      else
        socket
      end

    {:noreply,
     socket
     |> assign(draft: draft, dirty: draft != words(socket.assigns.piece), notice: nil)
     |> then(fn updated ->
       if draft.body != socket.assigns.draft.body, do: settle(updated, draft.body), else: updated
     end)}
  end

  def handle_event(
        "echo_attention",
        %{"id" => id, "body" => body, "start" => first, "end" => last},
        socket
      ) do
    piece = socket.assigns.piece

    if socket.assigns.editing && piece && id == piece.id do
      case Attention.locate(body, first, last) do
        {:ok, focus} ->
          {:noreply,
           socket
           |> assign(
             echo_attention: %{body: body, focus: focus},
             field_transition: nil,
             field_waiting: []
           )
           |> settle(socket.assigns.draft.body)}

        _ ->
          {:noreply,
           socket
           |> assign(echo_attention: nil, field_transition: nil, field_waiting: [])
           |> settle(socket.assigns.draft.body)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("echo_attention", _, socket), do: {:noreply, socket}

  def handle_event("focus_passage", %{"id" => id, "line" => value}, socket) do
    piece = socket.assigns.piece

    with false <- socket.assigns.editing,
         %{id: ^id} <- piece,
         true <- is_binary(value),
         {line, ""} <- Integer.parse(value),
         true <- line != socket.assigns.listening_line,
         passage when not is_nil(passage) <-
           Enum.find(
             Attention.passages(piece.body),
             &(&1.kind == :passage && &1.first_line == line)
           ) do
      previous = Enum.reject(socket.assigns.gravity_field, & &1.departing)
      field = Writing.saved_field(piece, passage.text, previous: previous)

      {:noreply,
       assign(socket,
         listening_line: line,
         gravity_field: StillWeb.Echoes.immediate(field),
         field_waiting: [],
         field_transition: nil
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("focus_passage", _, socket), do: {:noreply, socket}

  def handle_event("clear_passage_focus", _, socket) do
    if socket.assigns.editing do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket,
         listening_line: nil,
         gravity_field: [],
         field_waiting: [],
         field_transition: nil
       )}
    end
  end

  def handle_event("save_file", %{"writing" => attrs} = params, socket) do
    draft = draft_words(attrs, socket.assigns.piece)
    location = socket.assigns.location

    source_key =
      if is_binary(params["draft_key"]) &&
           String.starts_with?(params["draft_key"], "still:poem-draft:"),
         do: params["draft_key"],
         else: socket.assigns.draft_key

    save =
      if params["scratch"] in [true, "true"],
        do: &Still.Writing.Files.save_to_scratch/3,
        else: &Poems.save/3

    with :ok <- validate_position(draft.source_order),
         {:ok, piece} <-
           save.(
             location,
             socket.assigns.piece,
             Map.put(save_attrs(draft), :notebook_from_path, is_nil(socket.assigns.piece.token))
           ) do
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
         title: "",
         title_line: piece.title_line,
         relative_path: piece.relative_path,
         notebook_id: piece.notebook_id,
         list_label: piece.list_label,
         source_order: piece.source_order,
         source_key: source_key,
         target_key: target_key
       })
       |> finish_save(piece, params["read"] in [true, "true"])}
    else
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
       save_location:
         Still.Writing.Files.save_location(location, socket.assigns.draft.relative_path),
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

  def handle_event(
        "rename_file",
        %{"file" => %{"name" => name}},
        %{assigns: %{editing: false}} = socket
      ) do
    case Poems.rename(socket.assigns.location, socket.assigns.piece, name) do
      {:ok, piece} ->
        {:noreply,
         assign(socket, piece: piece, draft: words(piece), problem: nil, notice: "File renamed")}

      {:error, message} ->
        {:noreply, assign(socket, problem: message)}
    end
  end

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

  defp finish_save(socket, piece, true),
    do: push_navigate(socket, to: socket.assigns.wander_return || ~p"/writing/#{piece.id}")

  defp finish_save(%{assigns: %{wander_return: path}} = socket, piece, false)
       when is_binary(path),
       do: push_patch(socket, to: ~p"/writing/#{piece.id}/edit?from=wander", replace: true)

  defp finish_save(socket, piece, false),
    do: push_patch(socket, to: ~p"/writing/#{piece.id}/edit", replace: true)

  @impl true
  def handle_info({:settle_before, id, body}, socket) do
    if socket.assigns.editing && socket.assigns.piece.id == id &&
         socket.assigns.draft.body == body do
      previous = Enum.reject(socket.assigns.gravity_field, & &1.departing)

      attention = socket.assigns.echo_attention
      focused = attention && attention.body == String.replace(body, ~r/\r\n?/, "\n")
      query = if focused, do: attention.focus.text, else: body

      field =
        Writing.gravity_field(query,
          previous: previous,
          historical_only: true,
          title: if(focused, do: nil, else: socket.assigns.draft.title),
          selection: focused && attention.focus.kind == :selection,
          list: true,
          exclude_ids:
            Writing.historical_source_ids(socket.assigns.piece) ++
              List.wrap(Map.get(socket.assigns.piece, :entry_id)) ++
              if(socket.assigns.beside, do: [socket.assigns.beside.id], else: [])
        )

      {:noreply, socket |> assign(:gravity_timer, nil) |> move_field(field, id, body)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:release_before, id, body, transition}, socket) do
    if socket.assigns.field_transition == transition && socket.assigns.piece &&
         socket.assigns.piece.id == id &&
         if(socket.assigns.editing,
           do: socket.assigns.draft.body,
           else: socket.assigns.piece.body
         ) == body do
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

  defp words(piece) do
    %{
      body: piece.body,
      title: "",
      title_line:
        if(Map.get(piece, :title_needs_review),
          do: "",
          else: to_string(Map.get(piece, :title_line) || "")
        ),
      relative_path: Map.get(piece, :relative_path) || "",
      notebook_id: to_string(draft_notebook_id(piece) || ""),
      list_label: Map.get(piece, :list_label) || "",
      source_order: to_string(Map.get(piece, :source_order) || "")
    }
  end

  defp draft_notebook_id(piece) do
    case {Map.get(piece, :notebook_id), Map.get(piece, :token)} do
      {id, _token} when is_integer(id) ->
        id

      {_, nil} ->
        case Writing.current_notebook() do
          %{id: id} -> id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp validate_position(value) do
    position = integer_or_nil(value)

    if value in [nil, ""] or
         (is_integer(position) and position >= 0 and position <= 9_223_372_036_854_775_807),
       do: :ok,
       else: {:error, "Enter a whole number of zero or more for the notebook position."}
  end

  defp save_attrs(draft) do
    %{
      body: draft.body,
      title_line: integer_or_nil(draft.title_line),
      relative_path: blank_nil(draft.relative_path),
      notebook_id: integer_or_nil(draft.notebook_id),
      list_label: blank_nil(draft.list_label),
      source_order: integer_or_nil(draft.source_order)
    }
  end

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value

  defp integer_or_nil(value) when is_integer(value), do: value

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp integer_or_nil(_), do: nil

  defp draft_words(attrs, piece) do
    body = Map.get(attrs, "body", piece.body)

    body =
      if is_binary(body) && String.replace(piece.body, ~r/\r\n?/, "\n") == body,
        do: piece.body,
        else: body

    Map.merge(words(piece), %{
      body: body,
      title: "",
      title_line: Map.get(attrs, "title_line", Map.get(words(piece), :title_line, "")),
      relative_path: Map.get(attrs, "relative_path", Map.get(words(piece), :relative_path, "")),
      notebook_id: Map.get(attrs, "notebook_id", Map.get(words(piece), :notebook_id, "")),
      list_label: Map.get(attrs, "list_label", Map.get(words(piece), :list_label, "")),
      source_order: Map.get(attrs, "source_order", Map.get(words(piece), :source_order, ""))
    })
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
      writing_controls={@editing}
      writing_menu_open={@writing_menu_open}
      room_width={@room_width}
      width_open={@width_open}
      landscape_open={@landscape_open}
      places={@places}
      place={@place}
    >
      <:writing_menu>
        <p :if={@problem} id="writing-menu-problem" class="file-note" role="alert">{@problem}</p>
        <footer class="writing-footer file-writing-footer">
          <StillWeb.CopyText.copy_text
            id="copy-file-edit"
            body={@piece.body}
            title={Poems.explicit_title(@piece)}
            title_source={Map.get(@piece, :title_source) || "first_line"}
            title_in_body
            editing
            body_selector="#file-writing-body"
          />
          <span id="file-save-status" role="status" class="save-message">{cond do
            @notice -> @notice
            @dirty -> "Local draft · Save keeps these changes"
            @piece.token -> "Saved on this Mac"
            true -> "Local draft · not saved as a file"
          end}</span>
          <div class="footer-actions">
            <.link
              :if={@wander_return}
              id="back-to-wander"
              navigate={@wander_return}
              class="quiet-link"
            >Back to Wander</.link>
            <button form="file-writing-form" id="save-file" type="submit" class="quiet-link">{if @submitted &&
                                                                                                   @dirty,
                                                                                                 do:
                                                                                                   "Save new version",
                                                                                                 else:
                                                                                                   "Save"}</button>
            <button form="file-writing-form" id="new-file" type="button" class="quiet-link">New</button>
            <button
              :if={is_nil(@piece.token)}
              form="file-writing-form"
              id="save-scratch"
              type="submit"
              name="scratch"
              value="true"
              class="quiet-link"
            >Save to scratch</button>
            <.link id="open-saved-writing" navigate={~p"/writing"} class="quiet-link">Saved writing</.link>
            <button
              :if={@piece.token}
              form="file-writing-form"
              id="read-file"
              type="submit"
              name="read"
              value="true"
              class="quiet-link"
            >{if @wander_return, do: "Save & return to Wander", else: "Read"}</button>
          </div>
        </footer>
        <details
          id="file-page-details"
          class="file-location file-writing-details"
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary>Save location &amp; file name</summary>
          <p :if={is_nil(@piece.token)} id="next-list-destination" class="file-note">
            <%= if @save_location.notebook do %>
              <strong>{@save_location.notebook}</strong> → {@save_location.section}
              <span :if={@save_location.number}> · Next List <strong>{@save_location.number}</strong></span>
              <span :if={!@save_location.number}> · Unnumbered</span>
            <% else %>
              No notebook · Unnumbered
            <% end %>
          </p>
          <p id="file-save-destination" class="file-note">
            Inside <code>{@location.folder || "No writing folder chosen"}</code>
          </p>
          <label for="file-relative-path">File path</label>
          <input
            form="file-writing-form"
            id="file-relative-path"
            name="writing[relative_path]"
            value={@draft.relative_path}
            placeholder={Still.Writing.Files.proposed_path(@save_location, @draft.body)}
            autocomplete="off"
            phx-debounce="400"
            readonly={not is_nil(@piece.token)}
          />
          <p :if={is_nil(@piece.token)} class="file-note">
            Leave blank to use the proposed name above. Change the path to save in another folder.
            The next List number is confirmed when you save.
          </p>
          <p :if={@piece.token} class="file-note">
            Move this file in Finder to change its notebook, then reopen it in Still.
          </p>
          <input
            form="file-writing-form"
            id="file-title-line"
            type="hidden"
            name="writing[title_line]"
            value={@draft.title_line}
          />
          <input
            form="file-writing-form"
            type="hidden"
            name="writing[notebook_id]"
            value={@draft.notebook_id}
          />
          <input
            form="file-writing-form"
            type="hidden"
            name="writing[list_label]"
            value={@draft.list_label}
          />
          <input
            form="file-writing-form"
            type="hidden"
            name="writing[source_order]"
            value={@draft.source_order}
          />
          <.link navigate={~p"/storage"} class="quiet-link">Storage &amp; Backups</.link>
          <button
            :if={is_nil(@piece.token)}
            form="file-writing-form"
            id="refresh-file-folder"
            type="button"
            phx-click="refresh_file_folder"
            class="quiet-link"
          >Refresh folder choice</button>
        </details>
        <.submission_mark
          :if={@piece.token}
          marked={@submission_focus}
          piece_id={@piece.id}
          submitted={@submitted}
        />
        <p :if={!@location.configured} id="file-local-only" class="file-note file-storage-note">
          This page is kept only in this browser or Mac profile.
          <.link navigate={~p"/storage"}>Choose a collection folder</.link>
          before saving it as a file.
        </p>
        <p :if={@location.error && @location.error != @problem} class="file-note" role="alert">
          {@location.error}
        </p>
      </:writing_menu>
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
            else: "Write"}</span>
        </div>
        <p :if={@submitted} id="submitted-writing-note" class="file-note" role="status">
          This piece has been sent. Saving edits creates a new version. The exact words sent are kept in <.link navigate={
            ~p"/correspondence/writing/#{@piece.id}"
          }>Correspondence</.link>.
        </p>
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
            <input id="file-writing-title" name="writing[title]" type="hidden" value="" />
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
            Tab indents. Shift+Tab removes an indent. Enter continues indentation, returning to the margin after two indented lines. Shift+Enter keeps the indentation. Escape leaves the editor for the page controls. Command or Control+S saves; Command or Control+Enter saves and reads.
          </p>
        </.form>

        <aside :if={@beside} class="beside-room">
          <p class="section-whisper">Written beside</p><.link
            navigate={~p"/w/#{@beside.id}?read=1"}
            class="beside-title"
          >{Writing.opening(@beside)}</.link>
        </aside>
      </div>
      <StillWeb.Echoes.field :if={@piece && @editing} fragments={@gravity_field} />
      <article :if={@piece && !@editing} class="reading-room file-reading">
        <h1 class="sr-only">Saved writing</h1>
        <div id="file-text" class="file-lines">
          <StillWeb.Echoes.reading
            body={@piece.body}
            document_id={@piece.id}
            id_prefix="file-passage"
            active_line={@listening_line}
          />
        </div>
        <StillWeb.Echoes.field :if={@listening_line} fragments={@gravity_field} responsive />
        <p :if={@piece.body == ""} id="file-empty" class="file-note">An empty page, kept here.</p>
        <.submission_mark marked={@submission_focus} piece_id={@piece.id} submitted={@submitted} />
        <div class="file-reading-actions">
          <StillWeb.CopyText.copy_text
            id="copy-file-reading"
            body={@piece.body}
            title={@piece.title}
            title_source={Map.get(@piece, :title_source) || "first_line"}
            title_in_body
          />
          <.link id="edit-file" navigate={~p"/writing/#{@piece.id}/edit"} class="quiet-link">Change these words</.link>
          <.link navigate={~p"/writing"} class="quiet-link">Saved writing</.link>
          <button id="delete-file" phx-click="request_delete" class="quiet-link">Delete</button>
          <.link
            id="follow-file-words"
            navigate={~p"/threads?from=#{"file:#{@piece.id}"}"}
            class="quiet-link"
          >Follow a word</.link>
        </div>
        <aside
          :if={@reading_echo && !@listening_line}
          id="reading-company"
          class="drift-room"
          aria-label="Earlier words"
        >
          <p class="section-whisper">In the company of earlier words</p>
          <div class="echo-door">
            <span class="echo-phrase">{@reading_echo.line}</span>
            <.link navigate={~p"/w/#{@reading_echo.entry.id}?read=1"} class="door-title">
              {Writing.opening(@reading_echo.entry)}
            </.link>
          </div>
        </aside>
        <section
          :if={@delete_confirm}
          id="delete-confirmation"
          class="recovery-note"
          role="alertdialog"
          aria-label="Move writing to Trash?"
          aria-describedby="delete-confirmation-description"
          phx-mounted={JS.focus(to: "#cancel-delete-file")}
        >
          <p id="delete-confirmation-description">
            Move this writing to Trash? Its earlier words will stay with it, and you can restore it.
          </p>
          <button id="confirm-delete-file" phx-click="confirm_delete" class="quiet-link">Move to Trash</button>
          <button
            id="cancel-delete-file"
            phx-click={JS.push("cancel_delete") |> JS.focus(to: "#delete-file")}
            class="quiet-link"
          >Cancel</button>
        </section>
        <p :if={@problem} id="file-problem" class="file-note" role="alert">{@problem}</p>
        <details id="file-title-meaning" class="file-location">
          <summary>Text file and title meaning</summary><code>{@piece.path}</code>
          <.form for={%{}} as={:file} id="rename-file-form" phx-submit="rename_file">
            <label for="rename-file-name">File name</label>
            <input
              id="rename-file-name"
              name="file[name]"
              value={Path.basename(@piece.relative_path)}
              required
            />
            <button id="rename-file" type="submit" class="quiet-link">Rename file</button>
            <p>
              The name changes within this folder. Your words, List number, and earlier versions stay with it.
            </p>
          </.form>
          <p :if={@notice} role="status">{@notice}</p>
          <p :if={@piece.title_line && !@piece.title_needs_review}>
            Line {@piece.title_line} in the text is marked as its title. The line remains in the writing.
          </p>
          <p :if={@piece.title_line && @piece.title_needs_review}>
            The text at line {@piece.title_line} changed outside Still. Review the line number and save its title meaning again.
          </p>
          <p :if={!@piece.title_line}>No line is marked as the title.</p>
          <p :if={@piece.historical_source} id="historical-writing-source">
            {historical_source_label(@piece.historical_source)}. The original is preserved separately.
          </p>
        </details>
        <section :if={@revisions != []} id="file-revisions" class="file-history">
          <h2>Earlier words</h2>
          <details :for={revision <- @revisions} id={"file-revision-#{revision.id}"}>
            <summary>{date(revision.created_at)}</summary>
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
      if(source["notebook"],
        do:
          Writing.Geography.reference_label(
            Writing.geography(%{origin: "before", notebook: source["notebook"]}),
            source["source_number"]
          )
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end
end
