defmodule StillWeb.NotebookReadingLive do
  use StillWeb, :live_view

  alias Still.{Correspondence, Poems, Storage, Writing}
  alias Still.Writing.{Attention, PoemReferences}
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
       reading_context: %{},
       linked_segments: [],
       listening_line: nil,
       echo_field: [],
       versions: [],
       words: nil,
       reference_timer: nil,
       piece_find_open?: false,
       piece_find_query: "",
       piece_find_target_line: nil,
       piece_find_target_id: nil,
       problem: nil,
       sidebar_open: false,
       place: Writing.geography(nil)
     )}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    if socket.assigns.reference_timer, do: Process.cancel_timer(socket.assigns.reference_timer)
    socket = assign(socket, :reference_timer, nil)

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
              Map.put_new(params, "from", "notebook") |> Map.put("notebook", key)
            )

          location = Storage.collection_location()
          status = Correspondence.writing_status(location)
          linked_segments = linked_segments(location, entry, words)
          echo_field = whole_page_field(location, entry, words)

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
             linked_segments: linked_segments,
             reference_timer: reference_timer(socket, entry, words, linked_segments),
             listening_line: nil,
             echo_field: StillWeb.Echoes.immediate(echo_field),
             piece_find_open?: false,
             piece_find_query: "",
             piece_find_target_line: nil,
             piece_find_target_id: nil
           )}
        end
      end
    end)
  end

  @impl true
  def handle_event("toggle_index", _, socket),
    do: {:noreply, update(socket, :sidebar_open, &(!&1))}

  def handle_event("focus_passage", %{"id" => id, "line" => value}, socket) do
    entry = socket.assigns.entry
    document_id = document_id(entry)

    with true <- id == document_id,
         true <- is_binary(value),
         {line, ""} <- Integer.parse(value),
         true <- line != socket.assigns.listening_line,
         passage when not is_nil(passage) <-
           Enum.find(reading_passages(socket.assigns.linked_segments), fn passage ->
             passage.kind == :passage and passage.first_line == line
           end) do
      field = passage_field(socket.assigns.location, entry, passage.text)

      {:noreply,
       assign(socket,
         listening_line: line,
         echo_field: StillWeb.Echoes.immediate(field)
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("focus_passage", _, socket), do: {:noreply, socket}

  def handle_event("clear_passage_focus", _, socket) do
    field = whole_page_field(socket.assigns.location, socket.assigns.entry, socket.assigns.words)

    {:noreply,
     assign(socket,
       listening_line: nil,
       echo_field: StillWeb.Echoes.immediate(field)
     )}
  end

  def handle_event("open_piece_find", _, socket) do
    {:noreply,
     socket
     |> assign(
       piece_find_open?: true,
       piece_find_query: "",
       piece_find_target_line: nil,
       piece_find_target_id: nil
     )
     |> push_event("room-focus", %{id: "piece-find-query", scroll: true})}
  end

  def handle_event("close_piece_find", _, socket) do
    {:noreply,
     socket
     |> assign(
       piece_find_open?: false,
       piece_find_query: "",
       piece_find_target_line: nil,
       piece_find_target_id: nil
     )
     |> push_event("room-focus", %{id: "open-piece-find"})}
  end

  def handle_event("find_in_piece", _, %{assigns: %{piece_find_open?: false}} = socket),
    do: {:noreply, socket}

  def handle_event("find_in_piece", %{"piece_find" => %{"query" => query}} = params, socket) do
    query = PieceFind.query(query)

    target =
      if Map.has_key?(params, "_target"),
        do: {nil, nil},
        else: reading_find_target(socket.assigns.linked_segments, query)

    {target_id, target_line} = target

    socket =
      assign(socket,
        piece_find_open?: true,
        piece_find_query: query,
        piece_find_target_line: target_line,
        piece_find_target_id: target_id
      )

    socket =
      if target_id,
        do:
          push_event(socket, "room-focus", %{
            id: target_id,
            focus_id: "piece-find-query",
            scroll: true
          }),
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
  def handle_info({:refresh_notebook_references, id, body}, socket) do
    entry = socket.assigns.entry

    if entry && document_id(entry) == id && socket.assigns.words.body == body do
      segments = linked_segments(socket.assigns.location, entry, socket.assigns.words)

      updated = assign(socket, linked_segments: segments, reference_timer: nil)
      timer = reference_timer(updated, entry, socket.assigns.words, segments)
      {:noreply, assign(updated, :reference_timer, timer)}
    else
      {:noreply, socket}
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
        <StillWeb.NotebookIndex.sidebar
          notebook={@notebook}
          entry_id={@entry.id}
          context={@reading_context}
          patch
        />
        <article id="notebook-content" class="reading-room" aria-labelledby="reading-title">
          <nav class="reading-context notebook-toolbar" aria-label="Reading place">
            <.link
              id="reading-origin"
              navigate={ReadingLinks.origin(%{entry: @entry, context: @reading_context})}
              class="quiet-link"
            >{if @reading_context["from"] == "find", do: "Back to results", else: "Contents"}</.link>
            <span class="reader-reference">{Writing.reference_label(@entry)}</span>
            <.link
              navigate={ReadingLinks.wander(@entry, @reading_context)}
              id="wander-with-this"
              class="quiet-link"
            >Wander with this ↗</.link>
            <StillWeb.PieceFind.panel
              open={@piece_find_open?}
              query={@piece_find_query}
              matches={piece_find_matches(@entry, @words, @linked_segments, @piece_find_query)}
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
              <div
                :if={Enum.any?(@linked_segments, &(&1.kind == :reference))}
                class="linked-reading"
              >
                <%= for {segment, index} <- Enum.with_index(reading_segments(@linked_segments)) do %>
                  <%= if segment.kind == :text do %>
                    <StillWeb.Echoes.reading
                      body={segment.raw}
                      query={if @piece_find_open?, do: @piece_find_query, else: ""}
                      id_prefix={"linked-passage-#{index}"}
                      target_line={@piece_find_target_line}
                      active_line={@listening_line}
                      start_line={segment.start_line}
                      document_id={document_id(@entry)}
                    />
                  <% else %>
                    <StillWeb.PoemReference.passage
                      segment={segment}
                      id={"linked-poem-#{index}"}
                      query={if @piece_find_open?, do: @piece_find_query, else: ""}
                      return_to={ReadingLinks.edit(@entry, @reading_context)}
                    />
                  <% end %>
                <% end %>
              </div>
              <StillWeb.Echoes.reading
                :if={
                  not has_linked_references?(@linked_segments) &&
                    (@entry.origin == "before" || @entry.file_id)
                }
                body={@words.body}
                query={if @piece_find_open?, do: @piece_find_query, else: ""}
                id_prefix="passage"
                target_line={@piece_find_target_line}
                active_line={@listening_line}
                document_id={document_id(@entry)}
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
                reference_sources={reference_sources(@linked_segments)}
              />
              <.link
                :if={@reading_context["from"] == "find"}
                id="reading-origin-bottom"
                navigate={ReadingLinks.origin(%{entry: @entry, context: @reading_context})}
                class="quiet-link"
              >Back to results</.link>
              <.link
                :if={@entry.origin == "before" && !@version}
                navigate={~p"/w/#{@entry.id}?edit=1"}
                class="quiet-link"
              >Edit</.link>
              <.link
                :if={@entry.file_id && !@version}
                navigate={ReadingLinks.edit(@entry, @reading_context)}
                class="quiet-link"
              >Edit</.link>
            </div>
          </div>
        </article>
        <aside id="notebook-echoes" class="notebook-echoes" aria-label="Echoes">
          <StillWeb.Echoes.field fragments={@echo_field} responsive />
        </aside>
      </div>
    </Layouts.app>
    """
  end

  defp piece_find_matches(entry, words, segments, query) do
    title = if is_nil(entry.file_id), do: Map.get(words, :title), else: nil

    text =
      [
        if(is_binary(title) and title != "", do: title <> "\n", else: ""),
        reading_find_text(segments)
      ]
      |> IO.iodata_to_binary()

    PieceFind.match_count(text, query)
  end

  defp reading_find_target(segments, query) do
    if has_linked_references?(segments) do
      segments
      |> reading_segments()
      |> Enum.with_index()
      |> Enum.find_value(fn {segment, index} ->
        case segment do
          %{kind: :text, raw: raw, start_line: start_line} ->
            if line = PieceFind.first_match_line(raw, query) do
              line = line + start_line - 1
              {"linked-passage-#{index}-#{line}", line}
            end

          %{status: :available, source: source} ->
            if PieceFind.first_match_line(source.body, query),
              do: {"linked-poem-#{index}", nil}

          _ ->
            nil
        end
      end)
    else
      case PieceFind.first_match_line(reading_find_text(segments), query) do
        nil -> {nil, nil}
        line -> {"passage-#{line}", line}
      end
    end
  end

  defp reading_find_text(segments) do
    if has_linked_references?(segments) do
      segments
      |> reading_segments()
      |> Enum.map_join("\n", fn segment ->
        case segment do
          %{kind: :text, raw: raw} -> raw
          %{status: :available, source: source} -> source.body
          _ -> ""
        end
      end)
    else
      Enum.map_join(segments, & &1.raw)
    end
  end

  defp reference_sources(segments) do
    for %{kind: :reference, status: :available, raw: raw, source: source} <- segments,
        into: %{},
        do: {raw, source.body}
  end

  defp reference_timer(socket, entry, words, segments) do
    if connected?(socket) && has_linked_references?(segments) do
      Process.send_after(
        self(),
        {:refresh_notebook_references, document_id(entry), words.body},
        3_000
      )
    end
  end

  defp linked_segments(location, entry, words) do
    if entry.file_id do
      PoemReferences.resolve(location, words.body, current_id: entry.file_id, reconcile: false)
    else
      [%{kind: :text, raw: words.body}]
    end
  end

  defp whole_page_field(location, entry, words) do
    case entry.file_id && Poems.get(location, entry.file_id) do
      {:ok, piece} ->
        Writing.saved_field(Map.put(piece, :body, words.body))

      _ ->
        Writing.gravity_field(words.body, reading: true, entry_id: entry.id)
    end
  end

  defp passage_field(location, entry, passage) do
    case entry.file_id && Poems.get(location, entry.file_id) do
      {:ok, piece} -> Writing.saved_field(piece, passage)
      _ -> Writing.gravity_field(passage, reading: true, entry_id: entry.id)
    end
  end

  defp reading_passages(segments) do
    for %{kind: :text} = segment <- reading_segments(segments),
        passage <- Attention.passages(segment.raw) do
      Map.update!(passage, :first_line, &(&1 + segment.start_line - 1))
    end
  end

  defp reading_segments(segments) do
    {values, _} =
      Enum.map_reduce(segments, 1, fn segment, line ->
        {Map.put(segment, :start_line, line),
         line + length(Regex.scan(~r/\r\n|\r|\n/, segment.raw))}
      end)

    values
  end

  defp document_id(%{file_id: id}) when is_binary(id), do: id
  defp document_id(%{id: id}), do: "entry-#{id}"

  defp has_linked_references?(segments),
    do: Enum.any?(segments, &(&1.kind == :reference))
end
