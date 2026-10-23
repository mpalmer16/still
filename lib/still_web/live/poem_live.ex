defmodule StillWeb.PoemLive do
  use StillWeb, :live_view
  alias Still.{Poems, Storage}

  @impl true
  def mount(_, _, socket),
    do: {:ok, assign(socket, recovery_waiting: false, recovery_problem: nil)}

  @impl true
  def handle_params(params, _, socket) do
    location = Storage.collection_location()

    result =
      if socket.assigns.live_action == :new,
        do: {:ok, Poems.new(location)},
        else: Poems.get(location, params["id"])

    case result do
      {:ok, poem} ->
        history = if poem.token, do: Poems.revisions(location, poem.id), else: {:ok, []}

        {revisions, problem} =
          case history do
            {:ok, values} -> {values, nil}
            {:error, message} -> {[], message}
          end

        {:noreply,
         assign(socket,
           poem: poem,
           draft: words(poem),
           location: location,
           draft_key: draft_key(location, poem),
           dirty: false,
           problem: problem,
           revisions: revisions,
           notice: nil,
           recovery_waiting: false,
           page_title: poem.title || "Poem"
         )}

      {:error, message} ->
        {:noreply,
         assign(socket, poem: nil, location: location, problem: message, page_title: "Poem")}
    end
  end

  @impl true
  def handle_event("poem_changed", %{"poem" => attrs}, socket) do
    draft = draft_words(attrs, socket.assigns.poem)

    {:noreply,
     assign(socket, draft: draft, dirty: draft != words(socket.assigns.poem), notice: nil)}
  end

  def handle_event("save_poem", %{"poem" => attrs} = params, socket) do
    draft = draft_words(attrs, socket.assigns.poem)
    location = socket.assigns.location

    source_key =
      if is_binary(params["draft_key"]) and
           String.starts_with?(params["draft_key"], "still:poem-draft:"),
         do: params["draft_key"],
         else: socket.assigns.draft_key

    case Poems.save(location, socket.assigns.poem, %{
           body: draft.body,
           title: if(draft.title == "", do: nil, else: draft.title)
         }) do
      {:ok, poem} ->
        target_key = draft_key(location, poem)

        {:noreply,
         socket
         |> assign(
           poem: poem,
           draft: words(poem),
           dirty: false,
           problem: nil,
           notice: "Saved to your collection.",
           draft_key: target_key
         )
         |> push_event("poem-saved", %{
           id: poem.id,
           body: poem.body,
           title: poem.title || "",
           source_key: source_key,
           target_key: target_key
         })
         |> push_patch(to: ~p"/poems/#{poem.id}/edit")}

      {:error, message} ->
        {:noreply,
         assign(socket,
           draft: draft,
           dirty: draft != words(socket.assigns.poem),
           problem: message,
           notice: nil
         )}
    end
  end

  def handle_event("refresh_poem_folder", _, %{assigns: %{poem: %{token: nil}}} = socket) do
    location = Storage.collection_location()

    {:noreply,
     assign(socket,
       location: location,
       poem: %{socket.assigns.poem | scope: location.scope},
       problem: location.error,
       notice: nil
     )}
  end

  def handle_event("refresh_poem_folder", _, socket), do: {:noreply, socket}

  def handle_event("poem_recovery_status", %{"waiting" => waiting}, socket),
    do: {:noreply, assign(socket, recovery_waiting: waiting == true)}

  def handle_event("poem_recovery_unavailable", _, socket),
    do:
      {:noreply,
       assign(socket,
         recovery_problem:
           "This browser cannot keep a local recovery copy. Keep this page open and save your words to the chosen collection or copy them somewhere safe."
       )}

  def handle_event("poem_recovery_available", _, socket),
    do: {:noreply, assign(socket, recovery_problem: nil)}

  def handle_event("restore_poem_local", _, socket),
    do: {:noreply, push_event(socket, "poem-restore-local", %{})}

  def handle_event("keep_poem_file", _, socket),
    do: {:noreply, push_event(socket, "poem-keep-saved", %{})}

  defp words(poem), do: %{body: poem.body, title: poem.title || ""}

  defp draft_words(attrs, poem) do
    body = Map.get(attrs, "body", poem.body)

    body =
      if is_binary(body) and String.replace(poem.body, ~r/\r\n?/, "\n") == body,
        do: poem.body,
        else: body

    %{body: body, title: Map.get(attrs, "title", poem.title || "")}
  end

  defp draft_key(location, %{token: nil}), do: "still:poem-draft:#{location.draft_scope}:new"
  defp draft_key(location, poem), do: "still:poem-draft:#{location.scope}:#{poem.id}"

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
      active="poems"
      room_light={@room_light}
      light_open={@light_open}
      room_letters={@room_letters}
      letters_open={@letters_open}
      landscape_open={@landscape_open}
      places={@places}
      place={@place}
      return_writing={@return_writing}
      return_beside={@return_beside}
      return_list={@return_list}
    >
      <div class="poetry-page">
        <nav class="poetry-return" aria-label="Poetry">
          <.link navigate={~p"/poems"}>Poems</.link>
        </nav>
        <p :if={@problem} id="poem-problem" role="alert" class="poetry-note">{@problem}</p>
        <p :if={is_nil(@poem)} class="poetry-note">
          Your files have been left in place. Return to the collection or reconnect its folder.
        </p>
        <div :if={@poem && @live_action in [:new, :edit]}>
          <p :if={!@location.configured} id="poem-local-only" class="poetry-note">
            Local draft in this browser or Mac profile. No poem file has been saved. <.link navigate={
              ~p"/storage"
            }>Choose a collection folder in Storage &amp; Backups</.link>, then return to this page.
          </p>
          <p :if={@location.error && @location.error != @problem} role="alert" class="poetry-note">
            {@location.error}
          </p>
          <p :if={@recovery_problem} id="poem-recovery-problem" role="alert" class="poetry-note">
            {@recovery_problem}
          </p>
          <aside :if={@recovery_waiting} id="poem-recovery" class="recovery-note">
            <p>
              A local recovery copy is waiting. Bringing it back changes this draft; Save updates the collection file.
            </p>
            <div class="recovery-actions">
              <button id="restore-poem-local" phx-click="restore_poem_local">Bring it back</button>
              <button
                id="keep-poem-file"
                phx-click="keep_poem_file"
                data-confirm="Discard this local recovery copy? The saved poem file stays unchanged."
              >Keep the file version</button>
            </div>
          </aside>
          <p :if={@location.configured} id="poem-destination" class="poetry-note">
            Saving in <code>{Path.join(@location.folder, "poems")}</code>
          </p>
          <button
            :if={is_nil(@poem.token)}
            id="refresh-poem-folder"
            phx-click="refresh_poem_folder"
            class="quiet-link"
          >Refresh folder choice</button>
          <.form
            for={%{}}
            as={:poem}
            id="poem-form"
            phx-change="poem_changed"
            phx-submit="save_poem"
            data-authoritative={to_string(@poem.token != nil)}
            data-unsaved={to_string(@dirty)}
            data-save-blocked={to_string(@problem != nil)}
            data-recovery-safe="false"
            phx-mounted={JS.ignore_attributes(["data-unsaved", "data-recovery-safe"])}
          >
            <div id={"poem-fields-#{@poem.id}"} phx-update="ignore">
              <label for="poem-title" class="sr-only">Poem title (optional)</label>
              <input
                id="poem-title"
                name="poem[title]"
                value={@draft.title}
                placeholder="Title (optional)"
                class="poetry-title-input"
                autocomplete="off"
              />
              <label for="poem-body" class="sr-only">Poem</label>
              <textarea
                id="poem-body"
                name="poem[body]"
                class="poetry-editor"
                phx-hook="PoemRecovery"
                data-draft-key={@draft_key}
                data-persisted={Jason.encode!(words(@poem))}
                spellcheck="true"
                autocapitalize="off"
                autocorrect="off"
                wrap="off"
                autofocus
              >{"\n" <> @draft.body}</textarea>
            </div>
            <footer class="poetry-editor-footer">
              <div class="poetry-actions">
                <button id="save-poem" type="submit" class="quiet-link">Save poem</button>
                <.link
                  :if={@poem.token}
                  id="read-poem"
                  navigate={~p"/poems/#{@poem.id}"}
                  class="quiet-link"
                >Read saved poem</.link>
              </div>
              <span id="poem-save-status" role="status" class="save-message">
                {cond do
                  @notice -> @notice
                  @dirty -> "Local draft · changes are not saved to the collection"
                  @poem.token -> "Saved poem · edits save when you choose Save"
                  true -> "Local draft · not saved to a collection"
                end}
              </span>
            </footer>
          </.form>
          <details :if={@location.configured} class="poetry-file-note" id="poem-save-destination">
            <summary>Save location</summary>
            <p>
              <code>{@poem.path || Path.join([@location.folder, "poems", @poem.id, "poem.txt"])}</code>
            </p>
            <p>
              Save writes this text file and separate title metadata. Earlier words are kept in revisions. Synchronization is handled by your folder service.
            </p>
          </details>
        </div>
        <article :if={@poem && @live_action == :show} id="poem-reading" class="poetry-reading">
          <h1 :if={@poem.title && @poem.title != ""} class="poetry-title">{@poem.title}</h1>
          <div id="poem-text" class="poetry-lines">{@poem.body}</div>
          <p :if={@poem.body == ""} id="poem-empty" class="poetry-note">An empty page, kept here.</p>
          <footer class="poetry-reading-footer">
            <.link id="edit-poem" navigate={~p"/poems/#{@poem.id}/edit"} class="quiet-link">Edit poem or title</.link>
            <span class="poetry-date">Saved <time>{@poem.updated_at && date(@poem.updated_at)}</time></span>
          </footer>
          <details id="poem-file" class="poetry-file-note">
            <summary>Text file</summary><code>{@poem.path}</code>
          </details>
          <section :if={@revisions != []} id="poem-revisions" class="poetry-history">
            <h2>Earlier words</h2>
            <details :for={revision <- @revisions} id={"poem-revision-#{revision.id}"}>
              <summary>{date(revision.created_at)}</summary>
              <h3 :if={revision.title}>{revision.title}</h3>
              <div class="poetry-lines">{revision.body}</div>
            </details>
          </section>
        </article>
      </div>
    </Layouts.app>
    """
  end
end
