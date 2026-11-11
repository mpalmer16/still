defmodule StillWeb.NotebookReadingLive do
  use StillWeb, :live_view

  alias Still.{Correspondence, Storage, Writing}
  alias Still.Writing.ReadingPlace
  alias StillWeb.PieceFind
  alias StillWeb.ReadingLinks

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       notebook: nil,
       entry: nil,
       version: nil,
       version_missing: false,
       previous: nil,
       next: nil,
       reading_context: %{},
       versions: [],
       words: nil,
       piece_find_open?: false,
       piece_find_query: "",
       piece_find_target_line: nil,
       problem: nil,
       sidebar_open: false,
       place: Writing.geography(nil)
     )}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    Writing.with_collection_snapshot(fn ->
      problem = Still.Writing.Discovery.problem()
      entry = if is_nil(problem), do: Writing.get_entry(id)

      if is_nil(entry) do
        {:noreply,
         assign(socket,
           problem: problem || "This piece is no longer available in this notebook.",
           page_title: "Notebooks"
         )}
      else
        key = Writing.geography(entry).key
        notebook = Writing.notebook(key)

        if is_nil(notebook) or not Enum.any?(notebook.entries, &(&1.id == entry.id)) do
          {:noreply,
           assign(socket,
             problem: "This piece is not currently in a notebook.",
             page_title: "Notebooks"
           )}
        else
          version = Writing.get_version(entry, params["version"])
          words = version || entry

          context =
            ReadingPlace.context(
              entry,
              Map.put(params, "from", "notebook") |> Map.put("notebook", key)
            )

          {previous, next} = neighbors(notebook, entry.id)
          location = Storage.collection_location()
          status = Correspondence.writing_status(location)

          socket =
            if connected?(socket) do
              Writing.remember_visit(entry)

              case ReadingPlace.remember(entry, context) do
                {:ok, _} -> socket
                {:error, message} -> put_flash(socket, :error, message)
              end
            else
              socket
            end

          {:noreply,
           socket
           |> assign(
             notebook: notebook,
             entry: entry,
             location: location,
             submission_focus: Map.get(status.focused, entry.file_id, false),
             submitted: MapSet.member?(status.submitted, entry.file_id),
             version: version,
             version_missing: not is_nil(params["version"]) and is_nil(version),
             versions: Writing.list_versions(entry),
             previous: previous,
             next: next,
             reading_context: context,
             problem: nil,
             sidebar_open: false,
             place: Writing.geography(entry),
             page_title:
               if(version,
                 do: "Earlier words · #{Writing.opening(entry)}",
                 else: Writing.opening(entry)
               ),
             words: words,
             piece_find_open?: false,
             piece_find_query: "",
             piece_find_target_line: nil
           )}
        end
      end
    end)
  end

  @impl true
  def handle_event("toggle_index", _, socket),
    do: {:noreply, update(socket, :sidebar_open, &(!&1))}

  def handle_event("open_piece_find", _, socket) do
    {:noreply,
     socket
     |> assign(piece_find_open?: true, piece_find_query: "", piece_find_target_line: nil)
     |> push_event("room-focus", %{id: "piece-find-query", scroll: true})}
  end

  def handle_event("close_piece_find", _, socket) do
    {:noreply,
     socket
     |> assign(piece_find_open?: false, piece_find_query: "", piece_find_target_line: nil)
     |> push_event("room-focus", %{id: "open-piece-find"})}
  end

  def handle_event("find_in_piece", %{"piece_find" => %{"query" => query}} = params, socket) do
    query = PieceFind.query(query)

    target_line =
      if Map.has_key?(params, "_target"),
        do: nil,
        else: PieceFind.first_match_line(socket.assigns.words.body, query)

    socket =
      assign(socket,
        piece_find_open?: true,
        piece_find_query: query,
        piece_find_target_line: target_line
      )

    socket =
      if target_line,
        do: push_event(socket, "room-focus", %{id: "passage-#{target_line}", scroll: true}),
        else: socket

    {:noreply, socket}
  end

  def handle_event("find_in_piece", _, socket), do: {:noreply, socket}

  def handle_event("toggle_submission_focus", _, %{assigns: %{entry: %{file_id: id}}} = socket)
      when is_binary(id) do
    marked? = !socket.assigns.submission_focus

    case Correspondence.set_focus(socket.assigns.location, id, marked?) do
      :ok -> {:noreply, assign(socket, submission_focus: marked?)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active="notebooks"
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
      <p :if={@problem} class="recovery-note" role="alert">
        {@problem} <.link navigate={~p"/notebooks"}>All notebooks</.link>
      </p>
      <div
        :if={!@problem && @entry}
        class={"notebook-reader #{if @sidebar_open, do: "index-open", else: "index-closed"}"}
        id="notebook-reader"
      >
        <button
          type="button"
          phx-click="toggle_index"
          class="notebook-index-toggle quiet-link"
          aria-expanded={to_string(@sidebar_open)}
          aria-controls="notebook-sidebar"
        >Notebook index</button>
        <aside id="notebook-sidebar" aria-label="Notebook index">
          <.link navigate={~p"/notebooks"} class="quiet-link">All notebooks</.link>
          <h2>{(@notebook && @notebook.label) || "Notebook"}</h2>
          <section
            :for={section <- @notebook.sections}
            class="notebook-reader-section"
            aria-label={section.label}
          >
            <h3 :if={length(@notebook.sections) > 1}>{section.label}</h3>
            <ol>
              <li :for={item <- section.entries} id={"reader-list-#{item.id}"}>
                <.link
                  patch={reader_path(item, @notebook, @reading_context)}
                  aria-current={if item.id == @entry.id, do: "page", else: nil}
                >
                  <span :if={Writing.source_number(item)} class="notebook-piece-number">{Writing.source_number(
                    item
                  )}</span>
                  <span class="notebook-piece-title"><.list_title text={Writing.opening(item)} /></span>
                </.link>
              </li>
            </ol>
          </section>
        </aside>
        <article id="notebook-content" class="reading-room" aria-labelledby="reading-title">
          <nav class="reading-context notebook-toolbar" aria-label="Reading place">
            <.link
              id="reading-origin"
              navigate={ReadingLinks.origin(%{entry: @entry, context: @reading_context})}
              class="quiet-link"
            >Contents</.link>
            <span class="reader-reference">{Writing.reference_label(@entry)}</span>
            <.link
              navigate={ReadingLinks.wander(@entry, @reading_context)}
              id="wander-with-this"
              class="quiet-link"
            >Wander with this ↗</.link>
            <StillWeb.PieceFind.panel
              open={@piece_find_open?}
              query={@piece_find_query}
              matches={piece_find_matches(@entry, @words, @piece_find_query)}
            />
          </nav>
          <div
            id={"notebook-document-#{@entry.id}-#{@version && @version.id || "current"}"}
            phx-mounted={JS.focus(to: "#reading-title")}
          >
            <p :if={@version_missing} class="recovery-note" role="status">
              That earlier version isn't here. These are the current words.
            </p>
            <div :if={@version} class="historical-notice">
              <p>Earlier words. The current words are unchanged.</p>
              <.link
                patch={ReadingLinks.reader(@entry, Map.put(@reading_context, "version", nil))}
                class="quiet-link"
              >Read current words</.link>
            </div>
            <header class="reading-heading">
              <h1
                id="reading-title"
                tabindex="-1"
                class={if @entry.title && is_nil(@entry.file_id), do: "list-title", else: "sr-only"}
              >
                <.highlight
                  text={
                    (@version && (@version.title || "Earlier words")) || @entry.title ||
                      Writing.opening(@entry)
                  }
                  query={if @piece_find_open?, do: @piece_find_query, else: ""}
                />
              </h1>
            </header>
            <div class="list-body" id="list-body">
              <StillWeb.Echoes.reading
                :if={@entry.origin == "before" || @entry.file_id}
                body={@words.body}
                query={if @piece_find_open?, do: @piece_find_query, else: ""}
                id_prefix="passage"
                target_line={@piece_find_target_line}
                listening={false}
              />
              <.shaped_words
                :if={@entry.origin != "before" && is_nil(@entry.file_id)}
                body={@words.body}
                query={if @piece_find_open?, do: @piece_find_query, else: ""}
                id_prefix="passage"
                target_line={@piece_find_target_line}
              />
            </div>
            <.submission_mark
              :if={@entry.file_id && !@version}
              marked={@submission_focus}
              piece_id={@entry.file_id}
              submitted={@submitted}
            />
            <div class="reading-foot">
              <StillWeb.CopyText.copy_text
                id="copy-notebook-reading"
                body={@words.body}
                title={@words.title}
                title_source={if @words.title, do: "explicit", else: "first_line"}
                title_in_body={not is_nil(@entry.file_id)}
              />
              <.link :if={@entry.origin == "before"} navigate={~p"/w/#{@entry.id}"} class="quiet-link">Change these words</.link>
              <.link
                :if={@entry.file_id}
                navigate={~p"/writing/#{@entry.file_id}/edit"}
                class="quiet-link"
              >Change these words</.link>
              <details :if={@versions != []} class="notebook-earlier-words">
                <summary>Earlier words</summary>
                <ul>
                  <li :for={version <- @versions}>
                    <.link patch={
                      ReadingLinks.reader(@entry, Map.put(@reading_context, "version", version.id))
                    }>
                      {version.title || "Untitled"} · {Calendar.strftime(
                        version.inserted_at,
                        "%B %d, %Y"
                      )}
                    </.link>
                  </li>
                </ul>
              </details>
            </div>
            <nav class="notebook-sequence" aria-label="Move through this notebook">
              <.link
                :if={@previous}
                id="notebook-previous"
                patch={reader_path(@previous, @notebook, @reading_context)}
                class="quiet-link"
              >Previous</.link>
              <.link
                :if={@next}
                id="notebook-next"
                patch={reader_path(@next, @notebook, @reading_context)}
                class="quiet-link"
              >Next</.link>
            </nav>
          </div>
        </article>
      </div>
    </Layouts.app>
    """
  end

  defp reader_path(entry, notebook, context) do
    ReadingLinks.reader(
      entry,
      context
      |> Map.put("from", "notebook")
      |> Map.put("notebook", notebook && notebook.key)
      |> Map.put("version", nil)
    )
  end

  defp piece_find_matches(entry, words, query) do
    title = if is_nil(entry.file_id), do: Map.get(words, :title), else: nil

    text =
      [
        if(is_binary(title) and title != "", do: title <> "\n", else: ""),
        Map.get(words, :body, "")
      ]
      |> IO.iodata_to_binary()

    PieceFind.match_count(text, query)
  end

  defp neighbors(notebook, id) do
    entries = Enum.flat_map(notebook.sections, & &1.entries)

    case Enum.find_index(entries, &(&1.id == id)) do
      nil -> {nil, nil}
      index -> {if(index > 0, do: Enum.at(entries, index - 1)), Enum.at(entries, index + 1)}
    end
  end
end
