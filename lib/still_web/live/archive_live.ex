defmodule StillWeb.ArchiveLive do
  use StillWeb, :live_view
  alias Still.Writing
  alias Still.Writing.ReadingPlace
  alias StillWeb.ReadingLinks
  @page_size 40

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:earlier, false)
     |> assign(:written, false)
     |> assign(:reading_bookmark, nil)
     |> assign(:offset, 0)
     |> assign(:collection_problem, nil)
     |> stream(:results, [])}
  end

  @impl true
  def handle_params(%{"written" => "1"}, _uri, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/writing")}

  def handle_params(params, _uri, socket) do
    Writing.with_collection_snapshot(fn -> load_results(params, socket) end)
  end

  defp load_results(params, socket) do
    query = Writing.search_query(params["q"])
    earlier = params["earlier"] == "1"
    written = params["written"] == "1"

    shown_count = normalized_shown(params["shown"])

    results =
      find_results(
        query: query,
        earlier: earlier,
        scope: if(written, do: :saved, else: :all),
        limit: shown_count + 1
      )

    shown = Enum.take(results, shown_count)
    selected_at = params["at"]

    {:noreply,
     socket
     |> assign(:page_title, if(written, do: "Saved writing", else: "Find"))
     |> assign(:query, query)
     |> assign(:collection_problem, Writing.refresh_files())
     |> assign(:earlier, earlier)
     |> assign(:written, written)
     |> assign(:form, to_form(%{"query" => query}, as: :search))
     |> assign(:offset, length(shown))
     |> assign(:shown_count, shown_count)
     |> assign(:selected_at, selected_at)
     |> assign(:reading_bookmark, ReadingPlace.last())
     |> assign(:more?, length(results) > shown_count)
     |> assign(:empty?, shown == [])
     |> stream(:results, shown, reset: true)}
  end

  @impl true
  def handle_event("retry", _, socket) do
    handle_params(
      %{
        "q" => socket.assigns.query,
        "earlier" => if(socket.assigns.earlier, do: "1", else: "0"),
        "shown" => socket.assigns.shown_count
      },
      nil,
      socket
    )
  end

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
    handle_params(
      %{
        "q" => socket.assigns.query,
        "earlier" => if(socket.assigns.earlier, do: "1", else: "0"),
        "shown" => socket.assigns.shown_count + @page_size
      },
      nil,
      socket
    )
  end

  defp notebook?(entry), do: is_binary(entry.notebook) && String.trim(entry.notebook) != ""

  defp find_results(opts) do
    count = Keyword.fetch!(opts, :limit)

    Writing.with_collection_snapshot(fn ->
      Stream.iterate(0, &(&1 + 100))
      |> Enum.reduce_while([], fn offset, batches ->
        limit = min(100, count - offset)

        if limit <= 0 do
          {:halt, batches}
        else
          batch = Writing.find_entries(Keyword.merge(opts, limit: limit, offset: offset))

          if length(batch) < limit,
            do: {:halt, [batch | batches]},
            else: {:cont, [batch | batches]}
        end
      end)
      |> Enum.reverse()
      |> List.flatten()
    end)
  end

  defp normalized_shown(value) do
    parsed =
      case Integer.parse(to_string(value || "40")) do
        {n, ""} -> n
        _ -> 40
      end

    parsed |> max(40) |> min(5_000) |> then(&(div(&1 + 39, 40) * 40))
  end

  defp search_params(query, earlier, written) do
    if(String.trim(query) == "", do: [], else: [q: query]) ++
      if(earlier, do: [earlier: "1"], else: []) ++ if(written, do: [written: "1"], else: [])
  end

  defp result_path(result, query, earlier, written, shown) do
    context = %{
      "from" => "find",
      "q" => query,
      "earlier" => earlier,
      "written" => written,
      "shown" => max(shown, @page_size),
      "at" => result_anchor(result),
      "version" => if(result.version, do: result.version.id)
    }

    ReadingLinks.reader(result.entry, context) <>
      if(result.line, do: "#passage-#{result.line}", else: "#reading-title")
  end

  defp result_anchor(%{version: nil, entry: entry}), do: "current-#{entry.id}"
  defp result_anchor(%{version: version}), do: "version-#{version.id}"

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
          <.link
            :if={@reading_bookmark}
            navigate={ReadingLinks.resume(@reading_bookmark)}
            id="continue-reading"
            class="quiet-link"
          >Continue reading</.link>
          <p :if={@collection_problem} id="search-collection-problem" role="alert">
            {@collection_problem}
            <button type="button" phx-click="retry" class="quiet-link">Try again</button>
          </p>
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
            navigate={~p"/writing"}
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
            autofocus={is_nil(@selected_at)}
            phx-mounted={JS.focus(to: "#search-query")}
            phx-debounce="120"
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
          {cond do
            @collection_problem ->
              "Search is unavailable. Try again when the collection is available."

            @empty? ->
              "No matches."

            true ->
              "#{@offset} results shown#{if @more?, do: "; more available", else: ""}."
          end}
        </p>
        <div :if={!@collection_problem} id="entry-list" phx-update="stream" class="entry-list">
          <.link
            :for={{id, result} <- @streams.results}
            id={id}
            navigate={result_path(result, @query, @earlier, @written, @offset)}
            class="entry-row"
            aria-current={if @selected_at == result_anchor(result), do: "location"}
            phx-mounted={if @selected_at == result_anchor(result), do: JS.focus(to: "##{id}")}
          >
            <span :if={result.version} class="entry-date earlier-label">
              Earlier words · saved
              <time datetime={DateTime.to_iso8601(result.version.inserted_at)}>{Calendar.strftime(
                result.version.inserted_at,
                "%B %d, %Y · %H:%M UTC"
              )}</time>
            </span>
            <span :if={notebook?(result.entry)} class="entry-date entry-notebook">{Writing.reference_label(
              result.entry
            )}{if !result.version &&
                    result.entry.returned_at,
                  do: " & now"}</span>
            <span
              :if={!result.version && result.entry.origin == "before" && !notebook?(result.entry)}
              class="entry-date"
            >from before{if result.entry.returned_at,
              do: " & now"}</span>
            <time
              :if={
                !result.version && result.entry.origin != "before" && is_nil(result.entry.file_id) &&
                  !notebook?(result.entry)
              }
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
        <p :if={@empty? && !@collection_problem} class="archive-empty">
          {cond do
            @query != "" -> "Nothing with those words yet."
            @written -> "Your writing will be here when you begin."
            true -> "The first page is waiting."
          end}
        </p>
        <button
          :if={@more? && !@collection_problem}
          id="more-pages"
          type="button"
          phx-click="more"
          class="more-link"
        >Keep looking</button>
        <div class="archive-foot"><.link navigate={~p"/"} class="quiet-link">Write now</.link></div>
      </div>
    </Layouts.app>
    """
  end
end
