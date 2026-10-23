defmodule StillWeb.EntryLive do
  use StillWeb, :live_view

  alias Still.Writing

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:entry, nil)
     |> assign(:historical_version, nil)
     |> assign(:version_missing, false)
     |> assign(:search_query, "")
     |> assign(:search_line, nil)
     |> assign(:search_earlier, false)
     |> assign(:search_written, false)
     |> assign(:previous_reading, nil)
     |> assign(:notebook_neighbors, nil)
     |> assign(:form, to_form(Writing.change_entry(Writing.new_entry())))
     |> assign(:status, :quiet)
     |> assign(:recovery_available, false)
     |> assign(:stale_body, nil)
     |> assign(:stale_title, nil)
     |> assign(:checkpoint, false)
     |> assign(:versions_open, false)
     |> assign(:versions, [])
     |> assign(:editing, true)
     |> assign(:title_enabled, false)
     |> assign(:list_writing, false)
     |> assign(:list_interpretation, nil)
     |> assign(:list_suggestion_dismissed, nil)
     |> assign(:draft_scope, "")
     |> assign(:memory, nil)
     |> assign(:beside, nil)
     |> assign(:last, nil)
     |> assign(:place, Writing.geography(nil))
     |> assign(:gravity_field, [])
     |> assign(:field_waiting, [])
     |> assign(:field_transition, nil)
     |> assign(:gravity_timer, nil)
     |> assign(:arrival, nil)
     |> assign(:connections, %{siblings: [], nearby: nil, echo: nil, far: nil})
     |> assign(:companions, [])}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    entry = Writing.get_entry!(id)

    query = Writing.search_query(params["q"])
    version = Writing.get_version(entry, params["version"])

    if socket.assigns.entry && socket.assigns.entry.id == entry.id && params["read"] != "1" &&
         query == "" && !params["version"] && !socket.assigns.historical_version do
      {:noreply, assign(socket, :page_title, Writing.opening(entry))}
    else
      editing =
        entry.origin != "before" && params["read"] != "1" && !params["version"] && query == ""

      if connected?(socket) do
        Writing.remember_visit(entry)
        if editing, do: Writing.remember_writing(entry)
      end

      words = version || entry

      {:noreply,
       socket
       |> load_entry(entry, editing)
       |> assign(:historical_version, version)
       |> assign(
         :page_title,
         if(version,
           do: "#{version.title || "Untitled"} · Earlier words",
           else: Writing.opening(entry)
         )
       )
       |> assign(:version_missing, !!params["version"] && is_nil(version))
       |> assign(:search_query, query)
       |> assign(:search_earlier, params["earlier"] == "1")
       |> assign(:search_written, params["written"] == "1")
       |> assign(:search_line, Writing.search_passage(words.body, query).line)
       |> assign(:arrival, arrival(params))
       |> assign(:checkpoint, true)
       |> assign(:status, :quiet)
       |> assign(:recovery_available, false)
       |> assign(:versions_open, false)
       |> assign(:versions, [])
       |> assign(:stale_body, nil)
       |> assign(:beside, if(entry.beside_id, do: Writing.get_entry(entry.beside_id)))
       |> assign(
         :memory,
         if(editing && entry.origin == "now" && !entry.beside_id, do: Writing.remember_one())
       )
       |> assign(:return_writing, Writing.current_writing())
       |> assign(:return_beside, Writing.current_beside())
       |> record_reading()
       |> settle_before(entry.body)}
    end
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: action}} = socket)
      when action in [:before, :wander] do
    case Writing.wander_entry() do
      nil -> {:noreply, push_navigate(socket, to: ~p"/?new=1")}
      entry -> {:noreply, push_navigate(socket, to: ~p"/w/#{entry.id}?read=1&cross=far")}
    end
  end

  def handle_params(params, _uri, socket) do
    list? = socket.assigns.live_action == :list
    beside = lookup_beside(Map.get(params, "beside"))
    waiting = if !list? && !beside && params["new"] != "1", do: Writing.current_writing()
    pending_beside = if !list? && !beside && params["new"] != "1", do: Writing.current_beside()
    pending_list? = !list? && !beside && params["new"] != "1" && Writing.current_list_draft?()

    cond do
      waiting ->
        {:noreply, push_navigate(socket, to: ~p"/w/#{waiting.id}")}

      pending_beside && pending_list? ->
        {:noreply, push_navigate(socket, to: ~p"/list?beside=#{pending_beside.id}&resume=1")}

      pending_beside ->
        {:noreply, push_navigate(socket, to: ~p"/?beside=#{pending_beside.id}")}

      pending_list? ->
        {:noreply, push_navigate(socket, to: ~p"/list?resume=1")}

      true ->
        if connected?(socket),
          do: Writing.begin_writing(beside, if(list?, do: [writing_form: "list"], else: []))

        {:noreply,
         socket
         |> assign(:entry, nil)
         |> assign(:historical_version, nil)
         |> assign(:version_missing, false)
         |> assign(:search_query, "")
         |> assign(:search_line, nil)
         |> assign(:previous_reading, nil)
         |> assign(:notebook_neighbors, nil)
         |> assign(:form, to_form(Writing.change_entry(Writing.new_entry())))
         |> assign(:page_title, "Now")
         |> assign(:editing, true)
         |> assign(:title_enabled, list?)
         |> assign(:list_writing, list?)
         |> assign(:list_interpretation, nil)
         |> assign(:list_suggestion_dismissed, nil)
         |> assign(:draft_scope, draft_scope(list?, beside))
         |> assign(:status, :quiet)
         |> assign(:checkpoint, false)
         |> assign(:recovery_available, false)
         |> assign(:versions_open, false)
         |> assign(:versions, [])
         |> assign(:stale_body, nil)
         |> assign(:beside, beside)
         |> assign(:return_writing, nil)
         |> assign(:return_beside, beside)
         |> assign(:return_list, list?)
         |> assign(:place, Writing.geography(nil))
         |> clear_field()
         |> assign(:arrival, nil)
         |> assign(:last, Writing.last_visited())
         |> assign(:memory, if(beside, do: nil, else: Writing.remember_one()))}
    end
  end

  @impl true
  def handle_event("save", %{"entry" => attrs}, socket), do: save(attrs, socket, false)

  def handle_event("finish", %{"entry" => %{"action" => "save"} = attrs}, socket),
    do: save(attrs, socket, false)

  def handle_event("finish", %{"entry" => %{"interpret" => "title"} = attrs}, socket),
    do: accept_list_title(attrs, socket)

  def handle_event("finish", %{"entry" => attrs}, socket), do: save(attrs, socket, true)

  def handle_event("edit", _, socket) do
    if socket.assigns.entry.origin == "now", do: Writing.remember_writing(socket.assigns.entry)

    {:noreply,
     socket
     |> assign(:editing, true)
     |> assign(:search_query, "")
     |> assign(:search_line, nil)
     |> assign(:checkpoint, true)
     |> assign(:return_writing, Writing.current_writing())
     |> assign(:return_beside, Writing.current_beside())
     |> settle_before(socket.assigns.entry.body)}
  end

  def handle_event("read", _, socket) do
    {:noreply, socket |> load_entry(socket.assigns.entry, false) |> record_reading()}
  end

  def handle_event("reading_back", _, socket) do
    version = socket.assigns.historical_version

    case Writing.back_reading(socket.assigns.entry, version && version.id) do
      nil -> {:noreply, assign(socket, :previous_reading, nil)}
      place -> {:noreply, push_navigate(socket, to: trail_path(place))}
    end
  end

  def handle_event("leave_list_title", _, socket) do
    suggestion = socket.assigns.list_interpretation

    {:noreply,
     socket
     |> assign(:list_suggestion_dismissed, suggestion && suggestion.title)
     |> assign(:list_interpretation, nil)}
  end

  def handle_event("recovery_found", _, socket) do
    {:noreply, assign(socket, :recovery_available, true)}
  end

  def handle_event("restore_local", _, socket) do
    {:noreply,
     socket
     |> assign(:recovery_available, false)
     |> assign(:editing, true)
     |> assign(:checkpoint, true)
     |> push_event("restore-local", %{})}
  end

  def handle_event("dismiss_recovery", _, socket) do
    {:noreply,
     socket |> assign(:recovery_available, false) |> push_event("discard-recovery", %{})}
  end

  def handle_event("keep_both", _, socket) do
    opts = [title: socket.assigns.stale_title]

    opts =
      if socket.assigns.list_writing, do: Keyword.put(opts, :writing_form, "list"), else: opts

    case Writing.save_entry(nil, socket.assigns.stale_body, opts) do
      {:ok, entry} ->
        {:noreply,
         socket
         |> push_event("writing-saved", %{
           body: entry.body,
           title: entry.title,
           id: entry.id,
           first: true,
           draft_key: draft_key(socket.assigns.entry, socket.assigns.draft_scope)
         })
         |> push_navigate(to: ~p"/w/#{entry.id}")}

      {:error, _} ->
        {:noreply, assign(socket, :status, :error)}
    end
  end

  def handle_event("toggle_versions", _, socket) do
    open = not socket.assigns.versions_open
    versions = if open, do: Writing.list_versions(socket.assigns.entry), else: []
    {:noreply, socket |> assign(:versions_open, open) |> assign(:versions, versions)}
  end

  def handle_event("restore_version", %{"id" => id}, socket) do
    previous = socket.assigns.entry

    case Writing.restore_version(socket.assigns.entry, id) do
      {:ok, entry} ->
        {:noreply,
         socket
         |> load_entry(entry, socket.assigns.editing)
         |> assign(:versions, Writing.list_versions(entry))
         |> assign(:status, :saved)
         |> push_event("replace-writing", %{
           id: entry.id,
           body: entry.body,
           title: entry.title,
           previous_body: previous.body,
           previous_title: previous.title
         })}

      {:error, {:stale, _}} ->
        {:noreply, assign(socket, :status, :stale_restore)}

      {:error, _} ->
        {:noreply, assign(socket, :status, :error)}
    end
  end

  @impl true
  def handle_info({:settle_before, id, body}, socket) do
    entry = socket.assigns.entry

    if socket.assigns.editing && entry && entry.id == id &&
         entry.body == body do
      excluded = [entry.id] ++ if(socket.assigns.beside, do: [socket.assigns.beside.id], else: [])
      previous = Enum.reject(socket.assigns.gravity_field, & &1.departing)

      field =
        Writing.gravity_field(body,
          previous: previous,
          exclude_ids: excluded,
          title: entry.title,
          list: socket.assigns.list_writing
        )

      {:noreply, socket |> assign(:gravity_timer, nil) |> move_field(field, id, body)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:release_before, id, body, transition}, socket) do
    if socket.assigns.field_transition == transition && socket.assigns.editing &&
         socket.assigns.entry && socket.assigns.entry.id == id &&
         socket.assigns.entry.body == body do
      {:noreply,
       socket
       |> assign(:gravity_field, socket.assigns.field_waiting)
       |> assign(:field_waiting, [])
       |> assign(:field_transition, nil)}
    else
      {:noreply, socket}
    end
  end

  defp settle_before(socket, body) do
    if socket.assigns.gravity_timer, do: Process.cancel_timer(socket.assigns.gravity_timer)

    if connected?(socket) && socket.assigns.editing && socket.assigns.entry do
      timer = Process.send_after(self(), {:settle_before, socket.assigns.entry.id, body}, 1100)
      assign(socket, :gravity_timer, timer)
    else
      socket = assign(socket, :gravity_timer, nil)
      if socket.assigns.editing, do: clear_field(socket), else: socket
    end
  end

  # Let an old presence leave before admitting its replacement. The visible
  # field never becomes a pile of departing and newly arriving fragments.
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
      socket
      |> assign(:gravity_field, next)
      |> assign(:field_waiting, [])
      |> assign(:field_transition, nil)
    else
      transition = make_ref()

      visible =
        Enum.map(existing, fn old ->
          Enum.find(next, &(&1.entry.id == old.entry.id)) || %{old | departing: true}
        end)

      Process.send_after(self(), {:release_before, id, body, transition}, 1900)

      socket
      |> assign(:gravity_field, visible)
      |> assign(:field_waiting, next)
      |> assign(:field_transition, transition)
    end
  end

  defp clear_field(socket) do
    socket
    |> assign(:gravity_field, [])
    |> assign(:field_waiting, [])
    |> assign(:field_transition, nil)
  end

  defp arrival(%{"approach" => side}) when side in ["left", "right"], do: "from-#{side}"

  defp arrival(%{"cross" => distance}) when distance in ["near", "far", "sibling"],
    do: "cross-#{distance}"

  defp arrival(_params), do: nil

  defp save(attrs, socket, finish?) do
    entry = socket.assigns.entry
    body = Map.get(attrs, "body", "")
    opts = [checkpoint: socket.assigns.checkpoint]

    opts =
      if socket.assigns.list_writing && (is_nil(entry) || entry.origin == "now"),
        do: Keyword.put(opts, :writing_form, "list"),
        else: opts

    opts =
      if Map.has_key?(attrs, "title"), do: Keyword.put(opts, :title, attrs["title"]), else: opts

    opts =
      if socket.assigns.beside,
        do: Keyword.put(opts, :beside_id, socket.assigns.beside.id),
        else: opts

    if is_nil(entry) and String.trim(body) == "" do
      {:noreply, socket}
    else
      case Writing.save_entry(entry, body, opts) do
        {:ok, saved} ->
          first? = is_nil(entry)
          if first? and connected?(socket), do: Writing.remember_visit(saved)
          if saved.origin == "now", do: Writing.remember_writing(saved)

          socket =
            socket
            |> assign(:entry, saved)
            |> assign(:form, to_form(Writing.change_entry(saved)))
            |> assign(:status, :saved)
            |> assign(:recovery_available, false)
            |> assign(:checkpoint, false)
            |> assign(:stale_body, nil)
            |> assign(
              :list_interpretation,
              interpretation(
                saved,
                socket.assigns.list_writing,
                socket.assigns.list_suggestion_dismissed
              )
            )
            |> assign(:return_writing, Writing.current_writing())
            |> assign(:return_list, false)
            |> push_event("writing-saved", %{
              body: body,
              title: saved.title,
              id: saved.id,
              first: first?,
              draft_key: draft_key(entry, socket.assigns.draft_scope)
            })

          socket =
            if finish?, do: socket |> load_entry(saved, false) |> record_reading(), else: socket

          socket = settle_before(socket, saved.body)

          socket =
            if first?, do: push_patch(socket, to: ~p"/w/#{saved.id}", replace: true), else: socket

          {:noreply, socket}

        {:error, {:stale, _current}} ->
          {:noreply,
           socket
           |> assign(:stale_body, body)
           |> assign(:stale_title, Map.get(attrs, "title", entry && entry.title))
           |> assign(:status, :stale)}

        {:error, _reason} ->
          {:noreply, assign(socket, :status, :error)}
      end
    end
  end

  defp load_entry(socket, entry, editing) do
    list? = Writing.list_entry?(entry)

    socket
    |> assign(:entry, entry)
    |> assign(:form, to_form(Writing.change_entry(entry)))
    |> assign(:page_title, Writing.opening(entry))
    |> assign(:editing, editing)
    |> assign(:place, Writing.geography(entry))
    |> clear_field()
    |> assign(:list_writing, list?)
    |> assign(:title_enabled, entry.origin == "before" || list? || !!entry.title)
    |> assign(:list_interpretation, if(editing, do: interpretation(entry, list?), else: nil))
    |> assign(:draft_scope, "")
    |> assign(:return_list, Writing.current_list_draft?())
    |> assign(:notebook_neighbors, if(editing, do: nil, else: Writing.notebook_neighbors(entry)))
    |> assign(
      :connections,
      if(editing, do: socket.assigns.connections, else: Writing.connections(entry))
    )
    |> assign(
      :companions,
      if(editing,
        do: [],
        else: Enum.reject(Writing.companions(entry), &(&1.id == entry.beside_id))
      )
    )
    |> assign(:gravity_field, if(editing, do: [], else: reading_field(entry)))
  end

  defp record_reading(%{assigns: %{editing: true}} = socket), do: socket

  defp record_reading(socket) do
    entry = socket.assigns.entry
    version = socket.assigns.historical_version

    if connected?(socket) do
      Writing.remember_reading(entry,
        version: version && version.id,
        query: socket.assigns.search_query,
        earlier: socket.assigns.search_earlier,
        written: socket.assigns.search_written
      )
    end

    assign(socket, :previous_reading, Writing.previous_reading(entry, version && version.id))
  end

  defp trail_path(place) do
    params =
      [read: "1"] ++
        if(place["version"], do: [version: place["version"]], else: []) ++
        if(place["query"] not in [nil, ""], do: [q: place["query"]], else: []) ++
        if(place["earlier"], do: [earlier: "1"], else: []) ++
        if(place["written"], do: [written: "1"], else: [])

    entry = Writing.get_entry!(place["id"])
    words = Writing.get_version(entry, to_string(place["version"])) || entry
    line = Writing.search_passage(words.body, place["query"] || "").line
    ~p"/w/#{place["id"]}?#{params}" <> if(line, do: "#passage-#{line}", else: "")
  end

  defp results_path(query, earlier, written) do
    params =
      [q: query] ++
        if(earlier, do: [earlier: "1"], else: []) ++ if(written, do: [written: "1"], else: [])

    ~p"/pages?#{params}"
  end

  defp reading_field(entry) do
    sibling_ids = Writing.source_siblings(entry) |> Enum.map(& &1.id)

    Writing.gravity_field(entry.body,
      title: entry.title,
      list: Writing.list_entry?(entry),
      entry_id: entry.id,
      exclude_ids: sibling_ids,
      reading: true
    )
    |> Enum.map(&Map.merge(&1, %{departing: false, delay: 0}))
  end

  defp lookup_beside(nil), do: nil

  defp lookup_beside(id) do
    case Integer.parse(id) do
      {number, ""} -> Writing.get_entry(number)
      _ -> nil
    end
  end

  defp threshold_excerpt(entry) do
    entry.body
    |> String.split("\n")
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.take(3)
    |> Enum.join("\n")
  end

  defp draft_scope(true, nil), do: "list"
  defp draft_scope(true, beside), do: "list:beside:#{beside.id}"
  defp draft_scope(_, nil), do: ""
  defp draft_scope(_, beside), do: "beside:#{beside.id}"

  defp draft_key(nil, ""), do: "still:draft:new"
  defp draft_key(nil, scope), do: "still:draft:new:#{scope}"
  defp draft_key(entry, _scope), do: "still:draft:#{entry.id}"

  defp interpretation(%{title: title, body: body}, true) when title in [nil, ""],
    do: Writing.list_interpretation(body)

  defp interpretation(_, _), do: nil

  defp interpretation(entry, list?, dismissed) do
    case interpretation(entry, list?) do
      %{title: ^dismissed} -> nil
      suggestion -> suggestion
    end
  end

  defp reading_path(%{origin: "now", id: id}, crossing), do: ~p"/w/#{id}?read=1&cross=#{crossing}"
  defp reading_path(%{id: id}, crossing), do: ~p"/w/#{id}?cross=#{crossing}"

  attr :fragments, :list, required: true

  defp field(assigns) do
    ~H"""
    <aside
      :for={fragment <- @fragments}
      id={"drawn-before-#{fragment.entry.id}"}
      class={"gravity-presence field-#{fragment.side} gravity-#{fragment.distance} motion-#{fragment.motion} #{if fragment.departing, do: "gravity-receding"}"}
      style={"--field-y: #{fragment.height}vh; --pull: #{fragment.strength}; --arrival-delay: #{fragment.delay}ms;"}
      aria-label={if fragment.entry.origin == "before", do: "From before", else: "Written here"}
      aria-hidden={if fragment.departing, do: "true", else: nil}
      inert={fragment.departing}
    >
      <.link
        navigate={~p"/w/#{fragment.entry.id}?read=1&approach=#{fragment.side}"}
        class="gravity-door"
      >
        <span class="gravity-horizon" aria-hidden="true"></span>
        <div class="gravity-words"><.shaped_words body={fragment.line} /></div>
        <span :if={fragment.entry.title} class="gravity-title"><.list_title text={
          fragment.entry.title
        } /></span>
        <span class="gravity-place">{fragment.place.label}</span>
      </.link>
    </aside>
    """
  end

  defp accept_list_title(attrs, socket) do
    body = Map.get(attrs, "body", "")
    title = Map.get(attrs, "title")
    previous = socket.assigns.entry
    opts = [title: title, writing_form: "list"]

    opts =
      if socket.assigns.beside,
        do: Keyword.put(opts, :beside_id, socket.assigns.beside.id),
        else: opts

    case Writing.accept_list_title(previous, body, opts) do
      {:ok, saved} ->
        if is_nil(previous) && connected?(socket), do: Writing.remember_visit(saved)
        if saved.origin == "now", do: Writing.remember_writing(saved)

        socket =
          socket
          |> load_entry(saved, true)
          |> assign(:status, :saved)
          |> assign(:checkpoint, true)
          |> assign(:recovery_available, false)
          |> assign(:return_writing, Writing.current_writing())
          |> assign(:return_beside, Writing.current_beside())
          |> assign(:return_list, Writing.current_list_draft?())
          |> push_event("writing-saved", %{
            body: saved.body,
            title: saved.title,
            id: saved.id,
            first: is_nil(previous),
            draft_key: draft_key(previous, socket.assigns.draft_scope)
          })
          |> push_event("replace-writing", %{
            id: saved.id,
            body: saved.body,
            title: saved.title,
            previous_body: body,
            previous_title: title,
            only_if_current: true
          })
          |> settle_before(saved.body)

        {:noreply,
         if(is_nil(previous),
           do: push_patch(socket, to: ~p"/w/#{saved.id}", replace: true),
           else: socket
         )}

      {:error, {:stale, _}} ->
        {:noreply,
         socket
         |> assign(:stale_body, body)
         |> assign(:stale_title, title)
         |> assign(:status, :stale)}

      {:error, _} ->
        {:noreply, assign(socket, :status, :error)}
    end
  end

  defp source_neighbor(entry, siblings) do
    Enum.find(siblings, &(&1.source_order > entry.source_order)) || List.last(siblings)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={
        cond do
          !@editing || (@entry && @entry.origin == "before") -> "before"
          @list_writing -> "list"
          true -> "write"
        end
      }
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
      <div
        :if={@editing}
        class={"writing-room #{if @entry && @entry.origin == "before", do: "changing-before"}"}
      >
        <h1 class="sr-only">Write now</h1>
        <div class="room-intro">
          <span class="room-line" aria-hidden="true"></span>
          <span>{cond do
            @entry && @entry.origin == "before" -> "Before, again"
            @beside -> "Alongside these words"
            @list_writing -> "A new list"
            true -> "Now"
          end}</span>
        </div>

        <.form
          for={@form}
          id="writing-form"
          phx-change="save"
          phx-submit="finish"
          class="editor-form"
          data-save-blocked={to_string(@status in [:stale, :error])}
        >
          <input
            :if={@title_enabled}
            id="writing-title"
            name="entry[title]"
            value={@form[:title].value}
            class="title-input"
            aria-label="List title"
            placeholder="A title, if you like."
            autocomplete="off"
            phx-debounce="700"
            phx-update="ignore"
          />
          <.input
            field={@form[:body]}
            type="textarea"
            id="writing-body"
            class="writing-input"
            aria-label="Writing"
            aria-describedby="writing-keyboard-hint"
            placeholder={
              cond do
                @entry -> ""
                @list_writing -> "One thing: another:\nAnything that follows."
                true -> "Begin anywhere."
              end
            }
            autocomplete="off"
            autofocus
            spellcheck="true"
            phx-debounce="700"
            phx-hook="DraftRecovery"
            phx-update="ignore"
            data-entry-id={if @entry, do: @entry.id, else: "new"}
            data-draft-scope={@draft_scope}
          />
          <div :if={@list_interpretation} id="list-interpretation" class="list-interpretation">
            <button type="submit" name="entry[interpret]" value="title" class="quiet-link">Use first line as title</button>
            <button type="button" phx-click="leave_list_title" class="quiet-link">Leave it here</button>
          </div>
          <p id="writing-keyboard-hint" class="sr-only">
            Tab indents. Shift+Tab removes an indent. Escape leaves the editor for the page controls. Command or Control+S saves; Command or Control+Enter reads.
          </p>
          <div class="writing-footer">
            <div class="save-message" role="status" aria-live="polite">
              <span class="saved-status">
                <%= case @status do %>
                  <% :saved -> %>
                    Saved on this Mac
                  <% :stale -> %>
                    These words changed in another window.
                  <% :error -> %>
                    Could not save. Your browser still has this writing.
                  <% _ -> %>
                    {if @entry, do: "Saved on this Mac", else: "Autosaves as you write"}
                <% end %>
              </span>
              <span class="saving-status">Saving…</span>
            </div>
            <div class="footer-actions">
              <button
                id="save-writing"
                type="submit"
                name="entry[action]"
                value="save"
                class="quiet-link"
              >Save</button>
              <.link id="open-saved-writing" navigate={~p"/pages?written=1"} class="quiet-link">Saved writing</.link>
              <button :if={@entry} type="button" class="quiet-link" phx-click="toggle_versions">Earlier words</button>
              <button :if={@entry} type="submit" class="quiet-link">Read</button>
            </div>
          </div>
        </.form>
        <.recovery
          recovery_available={@recovery_available}
          status={@status}
          entry_id={@entry && @entry.id}
        />
        <.versions open={@versions_open} versions={@versions} />
      </div>

      <.field :if={@editing} fragments={@gravity_field} />

      <article
        :if={!@editing && @historical_version}
        class="reading-room historical-reading"
        aria-labelledby="reading-title"
        phx-mounted={
          JS.focus(to: if(@search_line, do: "#passage-#{@search_line}", else: "#reading-title"))
        }
      >
        <div class="historical-notice">
          <p>
            Earlier words · saved
            <time datetime={DateTime.to_iso8601(@historical_version.inserted_at)}>{Calendar.strftime(
              @historical_version.inserted_at,
              "%B %d, %Y · %H:%M UTC"
            )}</time>
          </p>
          <p>You are reading an earlier version. The current words are unchanged.</p>
          <.link navigate={~p"/w/#{@entry.id}?read=1"} class="quiet-link">Read current words</.link>
        </div>
        <h1 id="reading-title" tabindex="-1" class="list-title">
          <.highlight text={@historical_version.title || "Earlier words"} query={@search_query} />
        </h1>
        <div class="list-body historical-body">
          <.shaped_words
            body={@historical_version.body}
            query={@search_query}
            id_prefix="passage"
            target_line={@search_line}
          />
        </div>
        <div class="reading-foot">
          <.link
            :if={@search_query != ""}
            navigate={results_path(@search_query, @search_earlier, @search_written)}
            class="quiet-link"
          >Back to results</.link>
          <button
            :if={@previous_reading}
            id="reading-back"
            type="button"
            phx-click="reading_back"
            class="quiet-link"
          >Back where I was</button>
        </div>
      </article>

      <article
        :if={!@editing && @entry && !@historical_version}
        class={"reading-room #{@arrival}"}
        id={"reading-#{@entry.id}"}
        phx-hook="ReadRecovery"
        data-entry-id={@entry.id}
        data-entry-title={@entry.title || ""}
        aria-labelledby="reading-title"
        phx-mounted={
          JS.focus(to: if(@search_line, do: "#passage-#{@search_line}", else: "#reading-title"))
        }
      >
        <p :if={@version_missing} class="recovery-note" role="status">
          That earlier version isn't here. These are the current words.
        </p>
        <header class="reading-heading">
          <div class="room-intro">
            <span class="room-line" aria-hidden="true"></span>
            <span>{if @entry.origin == "before", do: "From before", else: "Written here"}</span>
            <span :if={@entry.returned_at} class="return-whisper">& now</span>
          </div>
          <h1
            id="reading-title"
            tabindex="-1"
            class={if(@entry.title, do: "list-title", else: "sr-only")}
          >
            <.highlight text={@entry.title || Writing.opening(@entry)} query={@search_query} />
          </h1>
        </header>
        <div class="list-body" id="list-body">
          <.shaped_words
            body={@entry.body}
            query={@search_query}
            id_prefix="passage"
            target_line={@search_line}
          />
        </div>
        <.field fragments={@gravity_field} />
        <.recovery recovery_available={@recovery_available} status={@status} entry_id={@entry.id} />
        <div class="reading-foot">
          <button
            :if={@previous_reading}
            id="reading-back"
            type="button"
            phx-click="reading_back"
            class="quiet-link"
          >Back where I was</button>
          <.link
            :if={@search_query != ""}
            navigate={results_path(@search_query, @search_earlier, @search_written)}
            class="quiet-link"
          >Back to results</.link>
          <button type="button" class="quiet-link" phx-click="edit">Change these words</button>
          <button type="button" class="quiet-link" phx-click="toggle_versions">Earlier words</button>
          <.link
            :if={@entry.origin == "before" && @entry.notebook}
            id="notebook-return"
            navigate={~p"/notebooks?#{[notebook: @place.key, at: @entry.id]}" <> "#list-#{@entry.id}"}
            class="quiet-link"
          >{@place.label} · index</.link>
        </div>
        <nav
          :if={@notebook_neighbors}
          class="notebook-sequence"
          aria-label={"Read #{@notebook_neighbors.notebook} in source order"}
        >
          <.link
            :if={@notebook_neighbors.previous}
            id="notebook-previous"
            navigate={~p"/w/#{@notebook_neighbors.previous.id}?read=1"}
            class="quiet-link"
            aria-label={"Previous List: #{Writing.opening(@notebook_neighbors.previous)}"}
          >
            <span>Previous</span><span class="sequence-title"><.list_title text={
              Writing.opening(@notebook_neighbors.previous)
            } /></span>
          </.link>
          <.link
            :if={@notebook_neighbors.next}
            id="notebook-next"
            navigate={~p"/w/#{@notebook_neighbors.next.id}?read=1"}
            class="quiet-link"
            aria-label={"Next List: #{Writing.opening(@notebook_neighbors.next)}"}
          >
            <span>Next</span><span class="sequence-title"><.list_title text={
              Writing.opening(@notebook_neighbors.next)
            } /></span>
          </.link>
        </nav>
        <.versions open={@versions_open} versions={@versions} />

        <section
          :if={@connections.siblings != []}
          class="together-room"
          aria-label="These were together"
        >
          <p :if={length(@connections.siblings) <= 3} class="section-whisper">These were together</p>
          <div :if={length(@connections.siblings) <= 3} class="sibling-lines">
            <.link
              :for={sibling <- @connections.siblings}
              navigate={~p"/w/#{sibling.id}?cross=sibling"}
              class="sibling-link"
            ><.list_title text={Writing.opening(sibling)} /></.link>
          </div>
          <details :if={length(@connections.siblings) > 3} class="sibling-fold">
            <summary>These were together</summary>
            <div class="sibling-lines">
              <.link
                :for={sibling <- @connections.siblings}
                navigate={~p"/w/#{sibling.id}?cross=sibling"}
                class="sibling-link"
              ><.list_title text={Writing.opening(sibling)} /></.link>
            </div>
          </details>
          <.link
            :if={length(@connections.siblings) > 3}
            navigate={~p"/w/#{source_neighbor(@entry, @connections.siblings).id}?cross=sibling"}
            class="sibling-peek"
          >
            <span class="sibling-link"><.list_title text={
              Writing.opening(source_neighbor(@entry, @connections.siblings))
            } /></span>
            <div class="threshold-body">
              <.shaped_words body={threshold_excerpt(source_neighbor(@entry, @connections.siblings))} />
            </div>
          </.link>
        </section>

        <section :if={@companions != []} class="together-room" aria-label="Written here">
          <p class="section-whisper">Written here, beside this</p>
          <.link
            :for={companion <- @companions}
            navigate={~p"/w/#{companion.id}?read=1"}
            class="sibling-link"
          >{Writing.opening(companion)}</.link>
        </section>

        <details :if={@entry.source_group} class="source-note">
          <summary>Where these words were</summary>
          <p class="source-neighborhood">{@entry.notebook |> String.replace("/", " · ")}</p>
          <p
            :if={@entry.source["original_title"] && @entry.source["original_title"] != @entry.title}
            class="original-title"
          >
            {@entry.source["original_title"]}
          </p>
          <div
            :if={@entry.source["preamble"] && @entry.source["preamble"] != ""}
            class="source-preamble"
          >
            <span class="section-whisper">Before these words</span><div>
              {@entry.source["preamble"]}
            </div>
          </div>
          <p :for={artifact <- @entry.source["artifacts"] || []} class="source-path">
            {artifact["path"] |> Path.basename()}
          </p>
        </details>

        <aside :if={@beside} class="beside-room" aria-label="Written beside">
          <p class="section-whisper">Written beside</p>
          <.link navigate={~p"/w/#{@beside.id}"} class="beside-title">{Writing.opening(@beside)}</.link>
          <div class="threshold-body"><.shaped_words body={threshold_excerpt(@beside)} /></div>
        </aside>

        <section class="drift-room" aria-label="Keep wandering">
          <div
            :if={
              @connections.echo &&
                !Enum.any?(@gravity_field, &(&1.entry.id == @connections.echo.entry.id))
            }
            class="echo-door"
          >
            <span class="echo-phrase">{@connections.echo.phrase}</span>
            <.link navigate={~p"/w/#{@connections.echo.entry.id}?read=1&cross=far"} class="door-title"><.list_title text={
              Writing.opening(@connections.echo.entry)
            } /></.link>
          </div>
          <div class="drift-directions">
            <.link
              :if={@connections.nearby}
              navigate={reading_path(@connections.nearby, "near")}
              class="quiet-link"
              id="move-near"
              title={Writing.opening(@connections.nearby)}
            >Stay near <span aria-hidden="true">↗</span></.link>
            <.link
              :if={@connections.far}
              navigate={reading_path(@connections.far, "far")}
              class="quiet-link"
              id="move-far"
              title={Writing.opening(@connections.far)}
            >Further away <span aria-hidden="true">↗</span></.link>
            <.link navigate={~p"/?beside=#{@entry.id}"} class="quiet-link">Write beside this</.link>
          </div>
        </section>
      </article>

      <aside :if={@editing && @beside} class="beside-room" aria-label="Writing beside">
        <.link navigate={~p"/w/#{@beside.id}"} class="beside-title">{Writing.opening(@beside)}</.link>
        <div class="threshold-body"><.shaped_words body={threshold_excerpt(@beside)} /></div>
      </aside>

      <section
        :if={@editing && @entry && !@beside && (@memory || @last)}
        class={"threshold-room #{if Enum.any?(@gravity_field, &(!&1.departing)), do: "threshold-distant"}"}
        aria-label="The words that wait"
      >
        <.link
          :if={@memory}
          navigate={~p"/w/#{@memory.id}"}
          class="threshold-link"
        >
          <span class="section-whisper">{if @memory.origin == "before",
            do: "From before",
            else: "From another day"}</span>
          <div class="threshold-body"><.shaped_words body={threshold_excerpt(@memory)} /></div>
          <span class="threshold-title">{Writing.opening(@memory)} <span aria-hidden="true">↗</span></span>
        </.link>
        <.link
          :if={@last && (!@memory || @last.id != @memory.id)}
          navigate={~p"/w/#{@last.id}"}
          class="left-open-link"
        ><span class="section-whisper">Left open</span><span>{Writing.opening(@last)}</span></.link>
      </section>
    </Layouts.app>
    """
  end

  attr :recovery_available, :boolean, required: true
  attr :status, :atom, required: true
  attr :entry_id, :integer, default: nil

  defp recovery(assigns) do
    ~H"""
    <div :if={@recovery_available} id="recovery-notice" class="recovery-note">
      <p>This browser kept words that may not have reached Still.</p>
      <div class="recovery-actions">
        <button type="button" phx-click="restore_local">Bring them back</button>
        <button
          type="button"
          phx-click="dismiss_recovery"
          data-confirm="Remove this unsaved browser copy?"
        >Dismiss</button>
      </div>
    </div>
    <div :if={@status == :stale_restore} id="stale-restore-notice" class="recovery-note">
      <p>
        These words changed in another window. Reopen them before restoring. This browser keeps any unsaved words.
      </p>
      <.link navigate={~p"/w/#{@entry_id}"} class="quiet-link">Open the current words</.link>
    </div>
    <div :if={@status == :stale} id="stale-notice" class="recovery-note">
      <p>Your unsaved words are safe in this browser. You can keep them on a separate page.</p>
      <button type="button" phx-click="keep_both">Keep both pages</button>
    </div>
    """
  end

  attr :open, :boolean, required: true
  attr :versions, :list, required: true

  defp versions(assigns) do
    ~H"""
    <section :if={@open} class="earlier-words" aria-label="Earlier words">
      <h2>Earlier words</h2>
      <p :if={@versions == []} class="muted">There are no earlier versions yet.</p>
      <details :for={version <- @versions} class="version-row">
        <summary>{version.body |> String.replace(~r/\s+/, " ") |> String.slice(0, 120)}</summary>
        <p :if={version.title} class="version-title">{version.title}</p>
        <div class="version-body"><.shaped_words body={version.body} /></div>
        <button
          type="button"
          phx-click="restore_version"
          phx-value-id={version.id}
        >Restore these words</button>
      </details>
    </section>
    """
  end
end
