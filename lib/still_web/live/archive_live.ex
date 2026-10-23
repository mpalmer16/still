defmodule StillWeb.ArchiveLive do
  use StillWeb, :live_view
  alias Still.Writing
  @page_size 40

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:earlier, false)
     |> assign(:written, false)
     |> assign(:offset, 0)
     |> stream(:results, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = Writing.search_query(params["q"])
    earlier = params["earlier"] == "1"
    written = params["written"] == "1"

    results =
      Writing.find_entries(
        query: query,
        earlier: earlier,
        scope: if(written, do: :saved, else: :all),
        limit: @page_size + 1
      )

    shown = Enum.take(results, @page_size)

    {:noreply,
     socket
     |> assign(:page_title, if(written, do: "Saved writing", else: "Find"))
     |> assign(:query, query)
     |> assign(:earlier, earlier)
     |> assign(:written, written)
     |> assign(:form, to_form(%{"query" => query}, as: :search))
     |> assign(:offset, length(shown))
     |> assign(:more?, length(results) > @page_size)
     |> assign(:empty?, shown == [])
     |> stream(:results, shown, reset: true)}
  end

  @impl true
  def handle_event("search", %{"search" => attrs}, socket) do
    params =
      search_params(
        attrs["query"] || "",
        attrs["earlier"] in ["true", "1"],
        Map.get(attrs, "written", to_string(socket.assigns.written)) in ["true", "1"]
      )

    path = if params == [], do: ~p"/pages", else: ~p"/pages?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("more", _, socket) do
    results =
      Writing.find_entries(
        query: socket.assigns.query,
        earlier: socket.assigns.earlier,
        scope: if(socket.assigns.written, do: :saved, else: :all),
        limit: @page_size + 1,
        offset: socket.assigns.offset
      )

    shown = Enum.take(results, @page_size)

    {:noreply,
     socket
     |> assign(:offset, socket.assigns.offset + length(shown))
     |> assign(:more?, length(results) > @page_size)
     |> stream(:results, shown)}
  end

  defp search_params(query, earlier, written) do
    if(String.trim(query) == "", do: [], else: [q: query]) ++
      if(earlier, do: [earlier: "1"], else: []) ++ if(written, do: [written: "1"], else: [])
  end

  defp result_path(result, query, earlier, written) do
    if query == "" do
      if written, do: ~p"/w/#{result.entry.id}?written=1", else: ~p"/w/#{result.entry.id}"
    else
      params =
        [read: "1", q: query] ++
          if(earlier, do: [earlier: "1"], else: []) ++
          if(result.version, do: [version: result.version.id], else: []) ++
          if(written, do: [written: "1"], else: [])

      ~p"/w/#{result.entry.id}?#{params}" <>
        if(result.line, do: "#passage-#{result.line}", else: "#reading-title")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active="pages"
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
      <div class="archive-room">
        <div class="archive-heading">
          <span class="section-whisper">A few words are enough</span>
          <h1>{if @written, do: "Saved writing.", else: "Find."}</h1>
          <.link navigate={~p"/notebooks"} class="quiet-link notebook-browse">Browse notebooks</.link>
        </div>
        <p :if={@written} class="archive-hint">
          New pages and Lists you’ve changed here. Your writing saves automatically on this Mac.
        </p>
        <nav class="archive-scopes" aria-label="Writing to browse">
          <.link
            id="all-writing"
            patch={~p"/pages"}
            aria-current={if !@written, do: "page"}
            class="quiet-link"
          >All writing</.link>
          <.link
            id="saved-writing"
            patch={~p"/pages?written=1"}
            aria-current={if @written, do: "page"}
            class="quiet-link"
          >Saved writing</.link>
          <.link id="storage-settings" navigate={~p"/storage"} class="quiet-link">Storage &amp; Backups</.link>
        </nav>
        <.form for={@form} id="search-form" phx-change="search" class="search-form" role="search">
          <.input
            field={@form[:query]}
            type="search"
            id="search-query"
            class="search-input"
            placeholder="A title, a phrase, a few words"
            aria-label="Search writing"
            aria-describedby="search-hint"
            autocomplete="off"
            autofocus
            phx-mounted={JS.focus(to: "#search-query")}
            phx-debounce="300"
          />
          <span class="search-mark" aria-hidden="true">⌕</span>
          <p id="search-hint" class="search-hint">Remembered words can be anywhere in the piece.</p>
          <input type="hidden" name="search[written]" value={to_string(@written)} />
          <input type="hidden" name="search[earlier]" value="false" />
          <label class="search-earlier" for="search-earlier">
            <input
              id="search-earlier"
              type="checkbox"
              name="search[earlier]"
              value="true"
              checked={@earlier}
            /> Include earlier words
          </label>
        </.form>
        <p id="search-status" class="sr-only" role="status" aria-live="polite" aria-atomic="true">
          {if @empty?,
            do: "No matches.",
            else: "#{@offset} results shown#{if @more?, do: "; more available", else: ""}."}
        </p>
        <div id="entry-list" phx-update="stream" class="entry-list">
          <.link
            :for={{id, result} <- @streams.results}
            id={id}
            navigate={result_path(result, @query, @earlier, @written)}
            class="entry-row"
          >
            <span :if={result.version} class="entry-date earlier-label">
              Earlier words · saved
              <time datetime={DateTime.to_iso8601(result.version.inserted_at)}>{Calendar.strftime(
                result.version.inserted_at,
                "%B %d, %Y · %H:%M UTC"
              )}</time>
            </span>
            <span :if={!result.version && result.entry.origin == "before"} class="entry-date">from before{if result.entry.returned_at,
              do: " & now"}</span>
            <time
              :if={!result.version && result.entry.origin != "before"}
              class="entry-date"
              datetime={DateTime.to_iso8601(result.entry.inserted_at)}
            >{Calendar.strftime(result.entry.inserted_at, "%B %d, %Y")}</time>
            <span class="entry-opening"><.highlight text={result.title} query={@query} /></span>
            <span :if={result.excerpt != ""} class="entry-excerpt"><.highlight
              text={result.excerpt}
              query={@query}
            /></span>
          </.link>
        </div>
        <p :if={@empty?} class="archive-empty">
          {cond do
            @query != "" -> "Nothing with those words yet."
            @written -> "Your writing will be here when you begin."
            true -> "The first page is waiting."
          end}
        </p>
        <button :if={@more?} id="more-pages" type="button" phx-click="more" class="more-link">Keep looking</button>
        <div class="archive-foot"><.link navigate={~p"/"} class="quiet-link">Write now</.link></div>
      </div>
    </Layouts.app>
    """
  end
end
