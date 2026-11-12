defmodule StillWeb.CorrespondenceLive do
  use StillWeb, :live_view

  alias Still.{Correspondence, Poems, Storage}

  alias Still.Correspondence.{
    Appearance,
    Calendar,
    CalendarImport,
    Recurrence,
    Icons,
    PacketExports,
    PacketNotes,
    PlaceDirectory,
    WorkDirectory,
    PacketDirectory,
    PlaceImport,
    Proofs
  }

  alias StillWeb.{
    CorrespondenceHome,
    CorrespondenceCalendar,
    CorrespondenceDirectories,
    CorrespondenceImport,
    CorrespondencePlaces,
    CorrespondenceWork
  }

  @impl true
  def mount(_params, _session, socket) do
    appearance = Appearance.current()

    {:ok,
     socket
     |> allow_upload(:places, accept: ~w(.json), max_entries: 1, max_file_size: 1_048_576)
     |> allow_upload(:events, accept: ~w(.json), max_entries: 1, max_file_size: 1_048_576)
     |> assign(
       notice: nil,
       problem: nil,
       search: "",
       works_limit: 40,
       submission_focus: false,
       place_icons: %{},
       places_filters: PlaceDirectory.browse([], [], %{}).filters,
       places_directory: nil,
       places_page_active?: false,
       directory_action: nil,
       works_directory: WorkDirectory.browse([], [], %{}),
       packets_directory: PacketDirectory.browse([], [], [], %{}),
       cover_letter_choices: [],
       cover_letter_preview: nil,
       cover_letter_problem: nil,
       form: %{},
       revisions: [],
       journal_packets: [],
       packet_search: "",
       import_plan: nil,
       import_result: nil,
       calendar_events: [],
       calendar_today: NaiveDateTime.local_now() |> NaiveDateTime.to_date(),
       calendar_month:
         NaiveDateTime.local_now() |> NaiveDateTime.to_date() |> Date.beginning_of_month(),
       calendar_selected: nil,
       calendar_query: "",
       calendar_cancelled: false,
       calendar_hidden: false,
       calendar_view: "calendar",
       calendar_page: 1,
       calendar_range: "upcoming",
       calendar_event: nil,
       calendar_event_form: %{},
       calendar_import_plan: nil,
       calendar_import_result: nil,
       correspondence_light?: appearance.light?,
       correspondence_color: appearance.color,
       proof_sources: [],
       comparison: nil,
       proof_problem: nil,
       proof_plain: false,
       packet_preview: [],
       packet_preview_problem: nil,
       packet_notes: nil,
       pdf_request: nil,
       pdf_exporting?: false,
       packet_export_notice: nil,
       last_packet_export: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    location = Storage.collection_location()
    action = socket.assigns.live_action

    previous_location = socket.assigns[:location]

    same_directory? =
      action in [:journals, :collection, :packets] && socket.assigns.directory_action == action &&
        location.available && location.configured && previous_location &&
        previous_location.available &&
        is_nil(socket.assigns.problem) && previous_location.scope == location.scope &&
        previous_location.folder == location.folder

    if same_directory? do
      {:noreply, put_directory(socket, action, params)}
    else
      {:noreply, socket} =
        cond do
          !location.configured || !location.available ->
            {:noreply,
             assign(socket,
               location: location,
               page_title: "Correspondence",
               problem: collection_problem(location),
               overview: %{journals: [], packets: [], pieces: []},
               piece: nil,
               journal: nil,
               packet: nil,
               history: [],
               overlap: [],
               form: %{}
             )}

          action in [:home, :collection, :journals, :import_journals, :packets] ->
            load_overview(socket, location, action)

          action in [:new_calendar_event, :edit_calendar_event] ->
            load_calendar_event(socket, location, params["id"])

          action in [:calendar, :import_calendar] ->
            load_calendar(socket, location, params)

          action == :piece ->
            load_piece(socket, location, params["id"], params)

          action in [:new_journal, :journal] ->
            load_journal(socket, location, params["id"])

          action in [:new_packet, :packet] ->
            load_packet(socket, location, params["id"], params)

          true ->
            {:noreply, socket}
        end

      socket = assign(socket, places_page_active?: action == :journals, directory_action: action)

      socket =
        if action in [:journals, :collection, :packets],
          do: put_directory(socket, action, params),
          else: socket

      {:noreply, load_place_icons(socket)}
    end
  end

  defp load_calendar(socket, location, params) do
    today = NaiveDateTime.local_now() |> NaiveDateTime.to_date()

    month =
      case Date.from_iso8601(to_string(params["month"] || "") <> "-01") do
        {:ok, date} -> date
        _ -> Date.beginning_of_month(today)
      end

    selected =
      case Date.from_iso8601(to_string(params["date"] || "")) do
        {:ok, date} -> date
        _ -> nil
      end

    query =
      if is_binary(params["q"]),
        do: params["q"] |> String.trim() |> String.slice(0, 300),
        else: ""

    socket =
      assign(socket,
        location: location,
        overview: empty_overview(),
        piece: nil,
        journal: nil,
        packet: nil,
        calendar_today: today,
        calendar_month: month,
        calendar_selected: selected,
        calendar_query: query,
        calendar_cancelled: params["cancelled"] == "true",
        calendar_hidden: params["hidden"] == "true",
        calendar_view: if(params["view"] == "list", do: "list", else: "calendar"),
        calendar_range: if(params["range"] == "all", do: "all", else: "upcoming"),
        calendar_page:
          case Integer.parse(to_string(params["page"] || "1")) do
            {page, ""} when page > 0 -> min(page, 100_000)
            _ -> 1
          end,
        page_title:
          if(socket.assigns.live_action == :import_calendar,
            do: "Import events",
            else: "Calendar"
          )
      )

    case Calendar.list(location) do
      {:ok, events} -> {:noreply, assign(socket, calendar_events: events, problem: nil)}
      {:error, message} -> {:noreply, assign(socket, calendar_events: [], problem: message)}
    end
  end

  defp load_calendar_event(socket, location, id) do
    today = NaiveDateTime.local_now() |> NaiveDateTime.to_date()
    result = if id, do: Calendar.get(location, id), else: {:ok, nil}

    case result do
      {:ok, event} ->
        {:noreply,
         assign(socket,
           location: location,
           overview: empty_overview(),
           piece: nil,
           journal: nil,
           packet: nil,
           calendar_event: event,
           calendar_event_form: calendar_event_form(event, today),
           page_title: if(event, do: "Edit event", else: "New event"),
           problem: nil
         )}

      {:error, message} ->
        {:noreply,
         assign(socket,
           location: location,
           overview: empty_overview(),
           calendar_event: nil,
           calendar_event_form: %{},
           page_title: "Calendar",
           problem: message
         )}
    end
  end

  defp calendar_event_form(event, today) do
    fields =
      ~w(external_id title date start_time end_time end_date timezone venue address url notes category status)

    form =
      Map.new(fields, fn key ->
        {key,
         if(event,
           do: Map.get(event, key, Map.get(event, String.to_existing_atom(key))) || "",
           else: ""
         )}
      end)

    recurrence = if event, do: Map.get(event, :recurrence, Map.get(event, "recurrence"))

    form
    |> Map.put(
      "external_id",
      if(event, do: form["external_id"], else: "still-" <> Ecto.UUID.generate())
    )
    |> Map.put("date", if(event, do: form["date"], else: Date.to_iso8601(today)))
    |> Map.put("category", if(form["category"] == "", do: "other", else: form["category"]))
    |> Map.put("status", if(form["status"] == "", do: "scheduled", else: form["status"]))
    |> Map.put("repeat_frequency", if(recurrence, do: recurrence["frequency"], else: "none"))
    |> Map.put(
      "repeat_interval",
      if(recurrence, do: to_string(recurrence["interval"] || 1), else: "1")
    )
    |> Map.put("repeat_until", (recurrence && recurrence["until"]) || "")
    |> Map.put("repeat_weekday", (recurrence && recurrence["weekday"]) || "")
    |> Map.put(
      "repeat_week_of_month",
      if(recurrence && recurrence["week_of_month"],
        do: to_string(recurrence["week_of_month"]),
        else: ""
      )
    )
    |> Map.put(
      "repeat_excluded_dates",
      if(recurrence, do: Enum.join(recurrence["excluded_dates"] || [], ", "), else: "")
    )
  end

  defp calendar_occurrences(assigns) do
    grid_start =
      assigns.calendar_month
      |> Date.beginning_of_month()
      |> then(&Date.add(&1, 1 - Date.day_of_week(&1)))

    agenda_start = assigns.calendar_selected || assigns.calendar_today
    agenda_end = if assigns.calendar_selected, do: agenda_start, else: Date.add(agenda_start, 366)

    windows =
      Recurrence.occurrences(assigns.calendar_events, grid_start, Date.add(grid_start, 41)) ++
        Recurrence.occurrences(assigns.calendar_events, agenda_start, agenda_end)

    # The list's All dates view also keeps old one-off events available without expanding unbounded repeat series.
    one_off =
      if assigns.calendar_view == "list",
        do:
          Enum.flat_map(assigns.calendar_events, fn event ->
            if assigns.calendar_range == "all" or
                 is_nil(Map.get(event, :recurrence, Map.get(event, "recurrence"))) do
              {:ok, date} = Date.from_iso8601(value(event, :date))
              Recurrence.occurrences([event], date, date)
            else
              []
            end
          end),
        else: []

    (windows ++ one_off) |> Enum.uniq_by(& &1.occurrence_key)
  end

  defp put_directory(socket, :journals, params), do: put_places_directory(socket, params)

  defp put_directory(socket, :collection, params),
    do:
      assign(socket,
        works_directory:
          WorkDirectory.browse(
            socket.assigns.overview.pieces,
            socket.assigns.overview.packets,
            params
          )
      )

  defp put_directory(socket, :packets, params),
    do:
      assign(socket,
        packets_directory:
          PacketDirectory.browse(
            socket.assigns.overview.packets,
            socket.assigns.overview.journals,
            Map.get(socket.assigns.overview, :packet_pieces, socket.assigns.overview.pieces),
            params
          )
      )

  defp directory_path(:collection, filters), do: ~p"/correspondence/writing?#{filters}"
  defp directory_path(:packets, filters), do: ~p"/correspondence/packets?#{filters}"

  defp put_places_directory(socket, params) do
    directory =
      PlaceDirectory.browse(
        socket.assigns.overview.journals,
        socket.assigns.overview.packets,
        params
      )

    assign(socket, places_directory: directory, places_filters: directory.filters)
  end

  defp places_path(filters) do
    defaults = PlaceDirectory.browse([], [], %{}).filters

    params =
      Map.reject(filters, fn {key, value} -> to_string(value) == to_string(defaults[key]) end)

    if map_size(params) == 0,
      do: ~p"/correspondence/journals",
      else: ~p"/correspondence/journals?#{params}"
  end

  defp load_place_icons(socket) do
    journals =
      cond do
        not is_nil(socket.assigns.problem) ->
          []

        socket.assigns.live_action == :journal && socket.assigns.journal ->
          [socket.assigns.journal]

        socket.assigns.live_action == :journals ->
          socket.assigns.overview.journals

        socket.assigns.live_action == :home ->
          Enum.filter(
            socket.assigns.overview.journals,
            &(&1.shortlisted && Correspondence.active_journal?(&1))
          )

        true ->
          []
      end

    location = socket.assigns.location

    cached = Icons.cached_many(location, journals)

    icons =
      Map.new(journals, fn journal ->
        {journal.id,
         case cached[journal.id] do
           {:ok, uri} -> uri
           _ -> nil
         end}
      end)

    missing_icons =
      Enum.filter(journals, fn journal ->
        cached[journal.id] == :missing and Icons.candidates(journal) != []
      end)

    socket = assign(socket, place_icons: icons)

    if connected?(socket) do
      socket = cancel_async(socket, :place_icons)

      if Application.get_env(:still, :fetch_place_icons, true) && missing_icons != [] do
        parent = self()

        fetcher =
          Application.get_env(
            :still,
            :place_icon_fetcher,
            &Still.Correspondence.IconFetcher.fetch/1
          )

        start_async(socket, :place_icons, fn ->
          missing_icons
          |> Task.async_stream(
            fn journal ->
              uri = Icons.ensure_missing(location, journal, fetcher)

              send(
                parent,
                {:place_icon, location.scope, journal.id, Icons.source_key(journal), uri}
              )
            end,
            max_concurrency: 4,
            timeout: 30_000,
            on_timeout: :kill_task
          )
          |> Stream.run()
        end)
      else
        socket
      end
    else
      socket
    end
  end

  @impl true
  def handle_async(:place_icons, _result, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:place_icon, scope, id, source_key, uri}, socket) do
    journal = Enum.find(socket.assigns.overview.journals, &(&1.id == id))

    if socket.assigns.location.scope == scope && Storage.collection_location().scope == scope &&
         journal && Icons.source_key(journal) == source_key do
      {:noreply, assign(socket, place_icons: Map.put(socket.assigns.place_icons, id, uri))}
    else
      {:noreply, socket}
    end
  end

  defp load_overview(socket, location, action) do
    case Correspondence.focused_overview(location) do
      {:ok, overview} ->
        {:noreply,
         assign(socket,
           location: location,
           overview: overview,
           page_title: title_for(action),
           problem: nil,
           piece: nil,
           journal: nil,
           packet: nil,
           history: [],
           overlap: [],
           form: %{}
         )}

      {:error, message} ->
        {:noreply,
         assign(socket,
           location: location,
           overview: empty_overview(),
           problem: message,
           page_title: title_for(action)
         )}
    end
  end

  defp load_piece(socket, location, id, params) do
    with {:ok, piece} <- Poems.get(location, id),
         {:ok, history} <- Correspondence.history(location, id),
         {:ok, revisions} <- Poems.revisions(location, id),
         {:ok, journals} <- Correspondence.journals(location) do
      sources = Proofs.sources(piece, revisions, history)
      requested = params["compare"]

      source =
        if requested == "latest",
          do: List.first(sources),
          else: Enum.find(sources, &(&1.key == requested))

      proof_problem =
        cond do
          requested == "latest" && sources == [] ->
            "This work has no earlier saves or sent copies yet."

          requested && is_nil(source) ->
            "That version isn't available for this work. Your current words are shown."

          true ->
            nil
        end

      {:noreply,
       assign(socket,
         location: location,
         overview: %{journals: journals, pieces: [], packets: []},
         piece: piece,
         submission_focus:
           Map.get(Correspondence.writing_status(location).focused, piece.id, false),
         history: history,
         revisions: revisions,
         proof_sources: sources,
         comparison: if(source, do: Proofs.compare(source, piece)),
         proof_problem: proof_problem,
         proof_plain: params["view"] == "plain",
         journal: nil,
         packet: nil,
         page_title: Poems.display_title(piece),
         problem: nil
       )}
    else
      {:error, message} ->
        {:noreply,
         assign(socket, location: location, problem: message, piece: nil, page_title: "Works")}
    end
  end

  defp load_journal(socket, location, nil) do
    {:noreply,
     assign(socket,
       location: location,
       overview: empty_overview(),
       journal: nil,
       journal_packets: [],
       packet: nil,
       page_title: "A new place",
       form: journal_defaults(),
       problem: nil
     )}
  end

  defp load_journal(socket, location, id) do
    with {:ok, journal} <- Correspondence.journal(location, id),
         {:ok, overview} <-
           Correspondence.focused_overview(location, journal.possible_piece_ids || []) do
      journal_packets = Enum.filter(overview.packets, &(&1.journal_id == journal.id))

      {:noreply,
       assign(socket,
         location: location,
         overview: overview,
         journal: journal,
         journal_packets: journal_packets,
         packet: nil,
         form: journal,
         page_title: journal.name,
         problem: nil
       )}
    else
      {:error, message} ->
        {:noreply,
         assign(socket,
           location: location,
           journal: nil,
           journal_packets: [],
           problem: message,
           page_title: "Place"
         )}
    end
  end

  defp refresh_packet_preview(
         %{assigns: %{packet: %{snapshot: %{pieces: pieces}} = packet}} = socket
       ),
       do:
         assign(socket,
           packet_preview: pieces,
           packet_preview_problem: nil,
           cover_letter_preview: %{body: packet.cover_letter || "", title: "Cover letter as sent"},
           cover_letter_problem: nil
         )

  defp refresh_packet_preview(socket) do
    result =
      Correspondence.manuscript_preview(
        socket.assigns.location,
        socket.assigns.form[:piece_ids] || []
      )

    socket =
      case result do
        {:ok, pieces} -> assign(socket, packet_preview: pieces, packet_preview_problem: nil)
        {:error, message} -> assign(socket, packet_preview: [], packet_preview_problem: message)
      end

    put_cover_letter_preview(socket)
  end

  defp put_cover_letter_preview(socket) do
    id = socket.assigns.form[:cover_letter_piece_id]

    if id not in [nil, ""] do
      case Correspondence.manuscript_preview(socket.assigns.location, [id]) do
        {:ok, [piece]} ->
          assign(socket, cover_letter_preview: piece, cover_letter_problem: nil)

        {:error, message} ->
          assign(socket, cover_letter_preview: nil, cover_letter_problem: message)
      end
    else
      assign(socket, cover_letter_preview: nil, cover_letter_problem: nil)
    end
  end

  defp manuscript_text(piece) do
    if Map.get(piece, :title_in_body, true),
      do: piece.body,
      else: piece.title <> "\n\n" <> piece.body
  end

  defp load_packet(socket, location, nil, params) do
    previous = previous_packet(location, params["from"])
    keep_ids = if previous, do: previous.piece_ids, else: []

    with {:ok, overview} <- Correspondence.focused_overview(location, keep_ids) do
      defaults =
        packet_defaults_from(overview, params, previous) |> packet_destination(overview, params)

      {:noreply,
       assign(socket,
         location: location,
         overview: overview,
         packet: nil,
         journal: Enum.find(overview.journals, &(&1.id == defaults.journal_id)),
         page_title: "A new packet",
         form: defaults,
         overlap: overlap_rows(location, defaults.piece_ids, nil),
         problem: nil,
         packet_notes: nil,
         cover_letter_choices: [],
         packet_export_notice: nil,
         last_packet_export: nil
       )
       |> refresh_packet_preview()}
    else
      {:error, message} ->
        {:noreply,
         assign(socket,
           location: location,
           problem: message,
           overview: empty_overview(),
           page_title: "Packet"
         )}
    end
  end

  defp load_packet(socket, location, id, _params) do
    with {:ok, packet} <- Correspondence.packet(location, id),
         {:ok, overview} <- Correspondence.focused_overview(location, packet.piece_ids) do
      overlap = packet_overlaps(location, packet)

      {notes, notes_problem} =
        case PacketNotes.get(location, packet) do
          {:ok, notes} -> {notes, nil}
          {:error, message} -> {nil, message}
        end

      {:noreply,
       assign(socket,
         location: location,
         overview: overview,
         packet: packet,
         journal: Enum.find(overview.journals, &(&1.id == packet.journal_id)),
         form: packet,
         overlap: overlap,
         page_title: packet.title,
         packet_notes: notes,
         cover_letter_choices: [],
         packet_export_notice: nil,
         last_packet_export: nil,
         problem: notes_problem
       )
       |> refresh_packet_preview()}
    else
      {:error, message} ->
        {:noreply,
         assign(socket, location: location, problem: message, packet: nil, page_title: "Packet")}
    end
  end

  defp collection_problem(%{error: error}) when is_binary(error),
    do: String.replace(error, "backup folder", "collection folder")

  defp collection_problem(_), do: "Choose an available collection folder to use Correspondence."

  @impl true
  def handle_event(
        "compare_work",
        %{"proof" => %{"source" => key}},
        %{assigns: %{live_action: :piece, piece: piece}} = socket
      )
      when not is_nil(piece) do
    if Enum.any?(socket.assigns.proof_sources, &(&1.key == key)) do
      params = [compare: key] ++ if(socket.assigns.proof_plain, do: [view: "plain"], else: [])
      {:noreply, push_patch(socket, to: ~p"/correspondence/writing/#{piece.id}?#{params}")}
    else
      {:noreply, assign(socket, :proof_problem, "That version isn't available for this work.")}
    end
  end

  def handle_event("compare_work", _, socket), do: {:noreply, socket}

  def handle_event(
        "toggle_submission_focus",
        _,
        %{assigns: %{live_action: :piece, piece: piece}} = socket
      )
      when not is_nil(piece) do
    marked? = !socket.assigns.submission_focus

    case Correspondence.set_focus(socket.assigns.location, piece.id, marked?) do
      :ok -> {:noreply, assign(socket, submission_focus: marked?)}
      {:error, message} -> {:noreply, assign(socket, problem: message)}
    end
  end

  def handle_event("validate_places_upload", _, socket),
    do: {:noreply, assign(socket, import_plan: nil, import_result: nil, problem: nil)}

  def handle_event("preview_places_import", _, socket) do
    {completed, pending} = uploaded_entries(socket, :places)

    if length(completed) == 1 && pending == [] &&
         upload_errors(socket.assigns.uploads.places) == [] do
      [result] =
        consume_uploaded_entries(socket, :places, fn %{path: path}, _entry ->
          result =
            with {:ok, bytes} <- File.read(path),
                 do: PlaceImport.preview(socket.assigns.location, bytes)

          {:ok, result}
        end)

      case result do
        {:ok, plan} ->
          {:noreply, assign(socket, import_plan: plan, import_result: nil, problem: nil)}

        {:error, reason} ->
          {:noreply,
           assign(socket, import_plan: nil, import_result: nil, problem: import_problem(reason))}
      end
    else
      {:noreply,
       assign(socket,
         import_plan: nil,
         import_result: nil,
         problem: "Choose one JSON file and wait for its upload to finish."
       )}
    end
  end

  def handle_event("import_places", _, %{assigns: %{import_plan: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("import_places", _, socket) do
    result = PlaceImport.commit(socket.assigns.import_plan)
    {:noreply, assign(socket, import_plan: nil, import_result: result, problem: nil)}
  end

  def handle_event("filter_calendar", %{"calendar" => params}, socket) do
    filters = %{
      "month" => Elixir.Calendar.strftime(socket.assigns.calendar_month, "%Y-%m"),
      "q" => params["q"] || "",
      "cancelled" => to_string(params["cancelled"] in [true, "true"]),
      "hidden" => to_string(params["hidden"] in [true, "true"]),
      "view" => socket.assigns.calendar_view,
      "range" => params["range"] || socket.assigns.calendar_range
    }

    filters =
      if socket.assigns.calendar_selected,
        do: Map.put(filters, "date", Date.to_iso8601(socket.assigns.calendar_selected)),
        else: filters

    {:noreply, push_patch(socket, to: ~p"/correspondence/calendar?#{filters}", replace: true)}
  end

  def handle_event("calendar_event_changed", %{"event" => attrs}, socket),
    do:
      {:noreply,
       assign(socket, calendar_event_form: Map.merge(socket.assigns.calendar_event_form, attrs))}

  def handle_event("save_calendar_event", %{"event" => attrs}, socket) do
    form = Map.merge(socket.assigns.calendar_event_form, attrs)
    event = socket.assigns.calendar_event

    with {:ok, recurrence} <- calendar_rule(form),
         attrs =
           Map.take(
             form,
             ~w(title date start_time end_time end_date timezone venue address url notes category status)
           )
           |> Map.put("external_id", socket.assigns.calendar_event_form["external_id"])
           |> Map.put("recurrence", recurrence),
         {:ok, _saved} <-
           Calendar.save(socket.assigns.location, attrs, event && event.id, event && event.token) do
      {:noreply,
       socket
       |> assign(notice: "Event saved.", problem: nil)
       |> push_patch(
         to:
           ~p"/correspondence/calendar?#{%{"month" => String.slice(form["date"], 0, 7), "date" => form["date"]}}"
       )}
    else
      {:error, message} -> {:noreply, assign(socket, calendar_event_form: form, problem: message)}
    end
  end

  def handle_event(action, %{"id" => id} = params, socket)
      when action in [
             "hide_calendar_event",
             "restore_calendar_event",
             "hide_calendar_series",
             "restore_calendar_series"
           ] do
    event = Enum.find(socket.assigns.calendar_events, &(&1.id == id))

    if event do
      date =
        if action in ["hide_calendar_event", "restore_calendar_event"] and
             Map.get(event, :recurrence, Map.get(event, "recurrence")),
           do: params["date"]

      hidden = action in ["hide_calendar_event", "hide_calendar_series"]

      case Calendar.set_hidden(socket.assigns.location, id, event.token, hidden, date) do
        {:ok, saved} ->
          {:noreply,
           assign(socket,
             calendar_events:
               Enum.map(socket.assigns.calendar_events, &if(&1.id == id, do: saved, else: &1)),
             notice:
               if(hidden,
                 do: "Event hidden. Use Include hidden to show it again.",
                 else: "Event shown again."
               ),
             problem: nil
           )}

        {:error, message} ->
          {:noreply, assign(socket, problem: message)}
      end
    else
      {:noreply, assign(socket, problem: "Reopen the calendar before changing this event.")}
    end
  end

  def handle_event("validate_calendar_upload", _, socket),
    do:
      {:noreply,
       assign(socket, calendar_import_plan: nil, calendar_import_result: nil, problem: nil)}

  def handle_event("preview_calendar_import", _, socket) do
    {completed, pending} = uploaded_entries(socket, :events)

    if length(completed) == 1 && pending == [] &&
         upload_errors(socket.assigns.uploads.events) == [] do
      [result] =
        consume_uploaded_entries(socket, :events, fn %{path: path}, _entry ->
          result =
            with {:ok, bytes} <- File.read(path),
                 do: CalendarImport.preview(socket.assigns.location, bytes)

          {:ok, result}
        end)

      case result do
        {:ok, plan} ->
          {:noreply,
           assign(socket, calendar_import_plan: plan, calendar_import_result: nil, problem: nil)}

        {:error, reason} ->
          {:noreply,
           assign(socket,
             calendar_import_plan: nil,
             calendar_import_result: nil,
             problem: import_problem(reason)
           )}
      end
    else
      {:noreply,
       assign(socket,
         calendar_import_plan: nil,
         calendar_import_result: nil,
         problem: "Choose one JSON file and wait for its upload to finish."
       )}
    end
  end

  def handle_event("import_calendar", _, %{assigns: %{calendar_import_plan: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("import_calendar", _, socket) do
    case CalendarImport.commit(socket.assigns.calendar_import_plan) do
      {:ok, result} ->
        {:noreply,
         assign(socket, calendar_import_plan: nil, calendar_import_result: result, problem: nil)}

      {:error, message} ->
        {:noreply,
         assign(socket, calendar_import_plan: nil, calendar_import_result: nil, problem: message)}
    end
  end

  def handle_event("toggle_place_active", %{"id" => id}, socket) do
    journal = Enum.find(socket.assigns.overview.journals, &(&1.id == id))

    if journal do
      case Correspondence.set_journal_active(
             socket.assigns.location,
             id,
             journal.token,
             journal.inactive
           ) do
        {:ok, saved} ->
          journals =
            Enum.map(socket.assigns.overview.journals, fn j ->
              if j.id == id, do: saved, else: j
            end)

          {:noreply,
           assign(socket,
             overview: %{socket.assigns.overview | journals: journals},
             journal: saved,
             form: Map.put(socket.assigns.form, :inactive, saved.inactive),
             problem: nil,
             notice:
               if(saved.inactive,
                 do: "Place deactivated. Past submissions and notes are preserved.",
                 else: "Place reactivated."
               )
           )}

        {:error, reason} ->
          {:noreply, assign(socket, problem: reason, notice: nil)}
      end
    else
      {:noreply, assign(socket, problem: "Reopen the place before changing its status.")}
    end
  end

  def handle_event("toggle_shortlist", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.overview.journals, &(&1.id == id)) do
      nil ->
        {:noreply,
         assign(socket,
           problem: "Reopen Places before changing which places you keep nearby.",
           notice: nil
         )}

      journal ->
        attrs =
          journal
          |> Map.take(Map.keys(journal_defaults()))
          |> Map.put(:shortlisted, !journal.shortlisted)

        case Correspondence.save_journal(
               socket.assigns.location,
               attrs,
               journal.id,
               journal.token
             ) do
          {:ok, saved} ->
            journals =
              Enum.map(socket.assigns.overview.journals, fn j ->
                if j.id == id, do: saved, else: j
              end)

            socket =
              assign(socket,
                overview: %{socket.assigns.overview | journals: journals},
                problem: nil,
                notice:
                  if(saved.shortlisted,
                    do: "Place kept nearby.",
                    else: "Place no longer kept nearby."
                  )
              )

            socket =
              if socket.assigns.journal && socket.assigns.journal.id == id,
                do:
                  assign(socket,
                    journal: saved,
                    form: Map.put(socket.assigns.form, :shortlisted, saved.shortlisted)
                  ),
                else: socket

            socket =
              if socket.assigns.live_action == :journals,
                do: put_places_directory(socket, socket.assigns.places_filters),
                else: socket

            {:noreply, socket}

          {:error, message} ->
            {:noreply, assign(socket, problem: message, notice: nil)}
        end
    end
  end

  def handle_event("filter_places", %{"places" => params}, socket) do
    filters = socket.assigns.places_filters |> Map.merge(params) |> Map.put("page", "1")

    directory =
      PlaceDirectory.browse(
        socket.assigns.overview.journals,
        socket.assigns.overview.packets,
        filters
      )

    {:noreply, push_patch(socket, to: places_path(directory.filters), replace: true)}
  end

  def handle_event("sort_places", %{"column" => column}, socket) do
    filters = socket.assigns.places_filters

    direction =
      cond do
        filters["sort"] == column && filters["direction"] == "asc" -> "desc"
        filters["sort"] == column -> "asc"
        column == "last_sent" -> "desc"
        true -> "asc"
      end

    filters = Map.merge(filters, %{"sort" => column, "direction" => direction, "page" => "1"})

    directory =
      PlaceDirectory.browse(
        socket.assigns.overview.journals,
        socket.assigns.overview.packets,
        filters
      )

    {:noreply, push_patch(socket, to: places_path(directory.filters), replace: true)}
  end

  def handle_event("places_page", %{"page" => page}, socket) do
    directory =
      PlaceDirectory.browse(
        socket.assigns.overview.journals,
        socket.assigns.overview.packets,
        Map.put(socket.assigns.places_filters, "page", page)
      )

    {:noreply, push_patch(socket, to: places_path(directory.filters))}
  end

  def handle_event("filter_works", %{"works" => params}, socket) do
    filters = Map.merge(socket.assigns.works_directory.filters, params) |> Map.put("page", "1")

    directory =
      WorkDirectory.browse(
        socket.assigns.overview.pieces,
        socket.assigns.overview.packets,
        filters
      )

    {:noreply,
     push_patch(socket, to: directory_path(:collection, directory.filters), replace: true)}
  end

  def handle_event("filter_packets", %{"packets" => params}, socket) do
    filters = Map.merge(socket.assigns.packets_directory.filters, params) |> Map.put("page", "1")

    directory =
      PacketDirectory.browse(
        socket.assigns.overview.packets,
        socket.assigns.overview.journals,
        Map.get(socket.assigns.overview, :packet_pieces, socket.assigns.overview.pieces),
        filters
      )

    {:noreply, push_patch(socket, to: directory_path(:packets, directory.filters), replace: true)}
  end

  def handle_event("works_page", %{"page" => page}, socket),
    do:
      {:noreply,
       push_patch(socket,
         to:
           directory_path(
             :collection,
             Map.put(socket.assigns.works_directory.filters, "page", page)
           )
       )}

  def handle_event("packets_page", %{"page" => page}, socket),
    do:
      {:noreply,
       push_patch(socket,
         to:
           directory_path(
             :packets,
             Map.put(socket.assigns.packets_directory.filters, "page", page)
           )
       )}

  def handle_event("search", %{"search" => value}, socket),
    do: {:noreply, assign(socket, search: value, works_limit: 40)}

  def handle_event("packet_search", %{"search" => value}, socket),
    do: {:noreply, assign(socket, packet_search: value)}

  def handle_event("more_works", _, socket) do
    {:noreply,
     assign(
       socket,
       :works_limit,
       min(socket.assigns.works_limit + 40, length(socket.assigns.overview.pieces))
     )}
  end

  def handle_event("toggle_palette", _, socket),
    do: appearance_result(socket, Appearance.set_light(!socket.assigns.correspondence_light?))

  def handle_event("change_correspondence_color", %{"appearance" => %{"color" => color}}, socket),
    do: appearance_result(socket, Appearance.choose_color(color))

  def handle_event("keep_possible_piece", %{"possibility" => %{"piece_id" => id}}, socket) do
    save_possibility(socket, id, true)
  end

  def handle_event("remove_possible_piece", %{"id" => id}, socket) do
    save_possibility(socket, id, false)
  end

  def handle_event("save_journal", %{"journal" => attrs}, socket) do
    journal = socket.assigns.journal
    id = journal && journal.id
    token = journal && journal.token

    attrs = Map.put(attrs, "inactive", (journal && journal.inactive) || false)
    attrs = Map.put(attrs, "verified", checked?(attrs["verified"]))
    attrs = Map.put(attrs, "shortlisted", checked?(attrs["shortlisted"]))

    case Correspondence.save_journal(socket.assigns.location, attrs, id, token) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> assign(journal: saved, form: saved, notice: "Place saved.", problem: nil)
         |> push_patch(to: ~p"/correspondence/journals/#{saved.id}")}

      {:error, message} ->
        {:noreply, assign(socket, form: attrs, problem: message, notice: nil)}
    end
  end

  def handle_event("refresh_packet_preview", _, socket),
    do: {:noreply, refresh_packet_preview(socket)}

  def handle_event("save_packet_notes", %{"id" => id, "body" => body, "token" => token}, socket) do
    if socket.assigns.packet && socket.assigns.packet.id == id do
      case PacketNotes.save(
             socket.assigns.location,
             id,
             body,
             if(token == "", do: nil, else: token)
           ) do
        {:ok, notes} ->
          {:reply, %{ok: true, body: notes.body, token: notes.token},
           assign(socket, packet_notes: notes)}

        {:error, message} ->
          {:reply, %{error: message}, socket}
      end
    else
      {:reply, %{error: "Reopen this packet before saving notes."}, socket}
    end
  end

  def handle_event("export_packet_pdf", _, socket) do
    packet = socket.assigns.packet

    cond do
      is_nil(packet) ->
        {:noreply, assign(socket, problem: "Save this packet before exporting.")}

      socket.assigns.pdf_exporting? ->
        {:noreply, socket}

      packet_unsaved?(socket.assigns.form, packet) ->
        {:noreply, assign(socket, problem: "Save your packet changes before exporting.")}

      true ->
        case PacketExports.prepare(socket.assigns.location, packet.id) do
          {:ok, prepared} ->
            request_id = Ecto.UUID.generate()

            ticket =
              Phoenix.Token.sign(StillWeb.Endpoint, "writing-pdf-export", %{
                scope: socket.assigns.location.scope,
                id: packet.id,
                kind: "packet",
                source_token: prepared.source_token,
                request_id: request_id
              })

            {:noreply,
             socket
             |> assign(
               pdf_exporting?: true,
               pdf_request: %{id: request_id, packet_id: packet.id},
               packet_export_notice: "Preparing PDF…",
               problem: nil
             )
             |> push_event("writing-pdf-request", %{ticket: ticket, request_id: request_id})}

          {:error, message} ->
            {:noreply, assign(socket, problem: message, packet_export_notice: nil)}
        end
    end
  end

  def handle_event(event, %{"request_id" => request_id} = params, socket)
      when event in ["pdf_export_finished", "pdf_export_failed"] do
    case socket.assigns.pdf_request do
      %{id: ^request_id, packet_id: id} ->
        current? = socket.assigns[:packet] && socket.assigns.packet.id == id

        message =
          if event == "pdf_export_finished",
            do: "PDF saved: #{params["path"]}",
            else: params["message"]

        socket = assign(socket, pdf_exporting?: false, pdf_request: nil)

        socket =
          if current? do
            if event == "pdf_export_finished",
              do:
                assign(socket, packet_export_notice: message, last_packet_export: params["path"]),
              else: assign(socket, problem: message, packet_export_notice: nil)
          else
            put_flash(
              socket,
              if(event == "pdf_export_finished", do: :info, else: :error),
              message
            )
          end

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(event, _, socket) when event in ["pdf_export_finished", "pdf_export_failed"],
    do: {:noreply, socket}

  def handle_event("reveal_packet_export", _, socket) do
    if socket.assigns.last_packet_export,
      do:
        {:noreply,
         push_event(socket, "reveal-writing-export", %{path: socket.assigns.last_packet_export})},
      else: {:noreply, socket}
  end

  def handle_event("choose_cover_letter", _, socket) do
    case Poems.list(socket.assigns.location) do
      {:ok, pieces} -> {:noreply, assign(socket, cover_letter_choices: pieces, problem: nil)}
      {:error, message} -> {:noreply, assign(socket, problem: message)}
    end
  end

  def handle_event("duplicate_packet", _, socket) do
    packet = socket.assigns.packet

    cond do
      is_nil(packet) ->
        {:noreply, assign(socket, problem: "Save this packet before duplicating it.")}

      packet_unsaved?(socket.assigns.form, packet) ->
        {:noreply, assign(socket, problem: "Save your packet changes before duplicating it.")}

      true ->
        case Correspondence.duplicate_packet(socket.assigns.location, packet.id, packet.token) do
          {:ok, copy} ->
            {:noreply,
             socket
             |> assign(
               notice: "Duplicated as a new draft. Choose its next destination when you're ready."
             )
             |> push_patch(to: ~p"/correspondence/packets/#{copy.id}")}

          {:error, message} ->
            {:noreply, assign(socket, problem: message)}
        end
    end
  end

  def handle_event("edit_packet_piece", %{"id" => id}, socket) do
    form = socket.assigns.form
    packet = socket.assigns.packet
    allowed = id in (form[:piece_ids] || []) or id == form[:cover_letter_piece_id]

    if allowed and (is_nil(packet) or packet.status == "preparing") do
      case Correspondence.save_packet(
             socket.assigns.location,
             packet_attrs(form),
             packet && packet.id,
             packet && packet.token
           ) do
        {:ok, saved} ->
          {:noreply, push_navigate(socket, to: ~p"/writing/#{id}/edit?packet=#{saved.id}")}

        {:error, message} ->
          {:noreply, assign(socket, problem: message)}
      end
    else
      {:noreply,
       assign(socket, problem: "Open a draft packet containing this writing before editing it.")}
    end
  end

  def handle_event("save_packet", %{"packet" => attrs}, socket) do
    packet = socket.assigns.packet
    id = packet && packet.id
    token = packet && packet.token

    attrs =
      attrs
      |> Map.put("piece_ids", socket.assigns.form[:piece_ids] || [])
      |> Map.put_new("preparation_notes", if(packet, do: packet.preparation_notes, else: ""))
      |> Map.put_new("cover_letter_piece_id", socket.assigns.form[:cover_letter_piece_id])
      |> then(fn attrs ->
        if attrs["cover_letter_piece_id"] not in [nil, ""],
          do: Map.put(attrs, "cover_letter", nil),
          else: attrs
      end)

    case Correspondence.save_packet(socket.assigns.location, attrs, id, token) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> assign(packet: saved, form: saved, notice: "Packet saved.", problem: nil)
         |> push_patch(to: ~p"/correspondence/packets/#{saved.id}")}

      {:error, message} ->
        {:noreply,
         assign(socket,
           form: Map.merge(socket.assigns.form, packet_form_changes(attrs)),
           problem: message,
           notice: nil
         )}
    end
  end

  def handle_event("toggle_piece", %{"id" => id}, socket) do
    ids = socket.assigns.form[:piece_ids] || []
    ids = if id in ids, do: Enum.reject(ids, &(&1 == id)), else: ids ++ [id]
    ids = ids

    {:noreply,
     assign(socket,
       form: Map.put(socket.assigns.form, :piece_ids, ids),
       overlap:
         overlap_rows(
           socket.assigns.location,
           ids,
           socket.assigns.packet && socket.assigns.packet.id
         )
     )
     |> refresh_packet_preview()}
  end

  def handle_event("move_piece", %{"id" => id, "direction" => direction}, socket) do
    ids = socket.assigns.form[:piece_ids] || []
    index = Enum.find_index(ids, &(&1 == id))

    next =
      if direction == "up",
        do: max((index || 0) - 1, 0),
        else: min((index || 0) + 1, length(ids) - 1)

    moved = move(ids, index, next)

    {:noreply,
     assign(socket,
       form: Map.put(socket.assigns.form, :piece_ids, moved),
       overlap:
         overlap_rows(
           socket.assigns.location,
           moved,
           socket.assigns.packet && socket.assigns.packet.id
         )
     )
     |> refresh_packet_preview()}
  end

  def handle_event("set_packet_journal", %{"packet" => attrs}, socket) do
    allowed = %{
      "title" => :title,
      "journal_id" => :journal_id,
      "preparation_notes" => :preparation_notes,
      "cover_letter" => :cover_letter,
      "cover_letter_piece_id" => :cover_letter_piece_id
    }

    changes =
      for {key, atom} <- allowed, Map.has_key?(attrs, key), into: %{}, do: {atom, attrs[key]}

    form = Map.merge(socket.assigns.form, changes)
    journal_id = attrs["journal_id"] || form[:journal_id]
    journal = Enum.find(socket.assigns.overview.journals, &(&1.id == journal_id))

    {:noreply,
     assign(socket,
       form: Map.put(form, :journal_id, journal_id),
       journal: journal,
       overlap:
         overlap_rows(
           socket.assigns.location,
           form[:piece_ids] || [],
           socket.assigns.packet && socket.assigns.packet.id
         )
     )
     |> put_cover_letter_preview()}
  end

  def handle_event("submit_packet", %{"date" => date}, socket) do
    packet = socket.assigns.packet

    cond do
      is_nil(packet) ->
        {:noreply, assign(socket, problem: "Save this packet before marking it sent.")}

      packet_unsaved?(socket.assigns.form, packet) ->
        {:noreply,
         assign(socket,
           problem: "Save your packet changes and review the manuscript before marking it sent."
         )}

      true ->
        case Correspondence.submit(socket.assigns.location, packet.id, packet.token, date) do
          {:ok, sent} ->
            {:noreply,
             socket
             |> assign(
               packet: sent,
               notice: "Marked sent. The submitted text is now preserved in this packet.",
               problem: nil
             )
             |> push_patch(to: ~p"/correspondence/packets/#{sent.id}")}

          {:error, message} ->
            {:noreply, assign(socket, problem: message, notice: nil)}
        end
    end
  end

  def handle_event("set_status", _, %{assigns: %{packet: nil}} = socket),
    do: {:noreply, assign(socket, problem: "Open a saved packet before changing its status.")}

  def handle_event("set_status", %{"status" => status}, socket) do
    packet = socket.assigns.packet

    case Correspondence.set_status(socket.assigns.location, packet.id, packet.token, status) do
      {:ok, updated} ->
        {:noreply,
         assign(socket, packet: updated, notice: "Packet status updated.", problem: nil)}

      {:error, message} ->
        {:noreply, assign(socket, problem: message, notice: nil)}
    end
  end

  def handle_event("set_status", _, socket), do: {:noreply, socket}

  def handle_event("record_response", _, %{assigns: %{packet: nil}} = socket),
    do: {:noreply, assign(socket, problem: "Open a sent packet before recording its reply.")}

  def handle_event("record_response", %{"response" => attrs}, socket) do
    packet = socket.assigns.packet

    accepted_ids =
      if attrs["status"] == "accepted",
        do:
          Enum.filter(List.wrap(attrs["accepted_piece_ids"]), &(&1 in response_piece_ids(packet))),
        else: []

    case Correspondence.respond(
           socket.assigns.location,
           packet.id,
           packet.token,
           attrs["status"],
           attrs["notes"],
           attrs["date"],
           accepted_ids
         ) do
      {:ok, updated} ->
        {:noreply,
         assign(socket,
           packet: updated,
           overlap: packet_overlaps(socket.assigns.location, updated),
           notice: "Reply recorded.",
           problem: nil
         )}

      {:error, message} ->
        {:noreply, assign(socket, problem: message, notice: nil)}
    end
  end

  def handle_event("record_response", _, socket), do: {:noreply, socket}

  def handle_event("validate_journal", %{"journal" => attrs}, socket),
    do: {:noreply, assign(socket, form: attrs)}

  def handle_event("validate_packet", %{"packet" => attrs}, socket),
    do:
      {:noreply, assign(socket, form: Map.merge(socket.assigns.form, packet_form_changes(attrs)))}

  defp calendar_rule(%{"repeat_frequency" => "none"}), do: {:ok, nil}

  defp calendar_rule(form) do
    with {interval, ""} <- Integer.parse(form["repeat_interval"] || "1") do
      rule = %{
        "frequency" => form["repeat_frequency"],
        "interval" => interval,
        "until" => if(form["repeat_until"] in [nil, ""], do: nil, else: form["repeat_until"]),
        "excluded_dates" =>
          String.split(form["repeat_excluded_dates"] || "", ~r/[\s,]+/, trim: true)
      }

      rule =
        if form["repeat_frequency"] == "monthly" and
             (form["repeat_weekday"] not in [nil, ""] or
                form["repeat_week_of_month"] not in [nil, ""]),
           do:
             rule
             |> Map.put("weekday", form["repeat_weekday"])
             |> Map.put(
               "week_of_month",
               case Integer.parse(form["repeat_week_of_month"] || "") do
                 {week, ""} -> week
                 _ -> nil
               end
             ),
           else: rule

      Recurrence.validate(rule, form["date"])
    else
      _ -> {:error, "Choose a whole-number repeat interval between 1 and 100."}
    end
  end

  defp packet_form_changes(attrs) do
    for key <- [
          :title,
          :journal_id,
          :piece_ids,
          :preparation_notes,
          :cover_letter,
          :cover_letter_piece_id
        ],
        Map.has_key?(attrs, Atom.to_string(key)),
        into: %{},
        do: {key, attrs[Atom.to_string(key)]}
  end

  defp packet_attrs(form) do
    attrs =
      Map.take(form, [
        :title,
        :journal_id,
        :piece_ids,
        :preparation_notes,
        :cover_letter,
        :cover_letter_piece_id
      ])

    if attrs[:cover_letter_piece_id] not in [nil, ""],
      do: Map.put(attrs, :cover_letter, nil),
      else: attrs
  end

  defp import_problem(reason) when is_binary(reason), do: reason
  defp import_problem(_), do: "The uploaded file could not be read. Choose it again."

  defp move(list, nil, _), do: list
  defp move(list, from, to) when from == to, do: list

  defp move(list, from, to)
       when from >= 0 and from < length(list) and to >= 0 and to < length(list) do
    item = Enum.at(list, from)
    list |> List.delete_at(from) |> List.insert_at(to, item)
  end

  defp move(list, _, _), do: list

  defp empty_overview, do: %{journals: [], packets: [], pieces: []}

  defp packet_overlaps(location, packet) do
    ids =
      if packet.accepted_piece_ids == [], do: packet.piece_ids, else: packet.accepted_piece_ids

    overlap_rows(location, ids, packet.id)
  end

  defp overlap_rows(location, ids, except_id) do
    case Correspondence.overlap(location, ids, except_id) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp save_possibility(socket, id, keep) do
    journal = socket.assigns.journal

    if journal do
      case Correspondence.set_possible_piece(
             socket.assigns.location,
             journal.id,
             journal.token,
             id,
             keep
           ) do
        {:ok, saved} ->
          {:noreply, assign(socket, journal: saved, notice: "Possibility saved.", problem: nil)}

        {:error, message} ->
          {:noreply, assign(socket, problem: message, notice: nil)}
      end
    else
      {:noreply, assign(socket, problem: "Open a place before saving a possibility.")}
    end
  end

  defp journal_defaults,
    do: %{
      name: "",
      website: "",
      submission_url: "",
      interests: "",
      description: "",
      icon_url: "",
      keywords: "",
      reach: "unknown",
      reach_note: "",
      guidelines: "",
      windows: "",
      fee: "",
      simultaneous_policy: "unknown",
      response_expectation: "",
      notes: "",
      inactive: false,
      shortlisted: false,
      verified: false
    }

  defp packet_defaults,
    do: %{
      title: "Untitled packet",
      journal_id: "",
      piece_ids: [],
      preparation_notes: "",
      cover_letter: "",
      cover_letter_piece_id: nil,
      status: "preparing"
    }

  defp previous_packet(_location, nil), do: nil

  defp previous_packet(location, id) do
    case Correspondence.packet(location, id) do
      {:ok, previous} -> previous
      _ -> nil
    end
  end

  defp packet_defaults_from(_overview, _params, previous) when is_map(previous) do
    %{
      packet_defaults()
      | title: (previous.title || "Untitled packet") <> " — revised",
        journal_id: "",
        piece_ids: previous.piece_ids,
        cover_letter: previous.cover_letter,
        cover_letter_piece_id: Map.get(previous, :cover_letter_piece_id)
    }
  end

  defp packet_defaults_from(overview, params, nil) do
    case Enum.find(overview.pieces, &(&1.id == params["piece"])) do
      nil -> packet_defaults()
      piece -> %{packet_defaults() | piece_ids: [piece.id], title: Poems.display_title(piece)}
    end
  end

  # A directory link may suggest a destination, but only a saved journal is valid.
  defp packet_destination(defaults, overview, %{"journal" => id}) do
    if Enum.any?(overview.journals, &(&1.id == id)),
      do: %{defaults | journal_id: id},
      else: defaults
  end

  defp packet_destination(defaults, _overview, _params), do: defaults

  defp appearance_result(socket, {:ok, appearance}),
    do:
      {:noreply,
       assign(socket,
         correspondence_light?: appearance.light?,
         correspondence_color: appearance.color
       )}

  defp appearance_result(socket, {:error, _}),
    do: {:noreply, put_flash(socket, :error, "Could not remember the correspondence color.")}

  defp title_for(:home), do: "Correspondence"
  defp title_for(:collection), do: "Works"
  defp title_for(:import_journals), do: "Import Places"
  defp title_for(:journals), do: "Places"
  defp title_for(:packets), do: "Packets"
  defp title_for(:calendar), do: "Calendar"
  defp title_for(:import_calendar), do: "Import events"
  defp title_for(_), do: "Correspondence"

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value), do: to_string(value)

  defp value(map, key, default \\ ""),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default)) || default

  defp checked?(value), do: value in [true, "true", "on", 1]
  defp title(piece), do: Poems.display_title(piece)

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
    <Layouts.app flash={@flash} active="correspondence" file_exports correspondence>
      <div
        class={"correspondence-room corr-workspace #{if @correspondence_light?, do: "is-light", else: ""}"}
        data-color={@correspondence_color}
      >
        <header class="corr-header">
          <div class="corr-brand">
            <.link patch={~p"/correspondence"}>Correspondence<span>.</span></.link>
          </div>
          <nav aria-label="Correspondence">
            <.link
              patch={~p"/correspondence"}
              aria-current={if @live_action == :home, do: "page"}
              class={if @live_action == :home, do: "active", else: nil}
            >Home</.link>
            <.link
              patch={~p"/correspondence/writing"}
              aria-current={if @live_action in [:collection, :piece], do: "page"}
              class={if @live_action in [:collection, :piece], do: "active", else: nil}
            >Works</.link>
            <.link
              patch={places_path(@places_filters)}
              aria-current={
                if @live_action in [:journals, :journal, :new_journal, :import_journals], do: "page"
              }
              class={
                if @live_action in [:journals, :journal, :new_journal, :import_journals],
                  do: "active",
                  else: nil
              }
            >Places</.link>
            <.link
              patch={~p"/correspondence/packets"}
              aria-current={if @live_action in [:packets, :packet, :new_packet], do: "page"}
              class={if @live_action in [:packets, :packet, :new_packet], do: "active", else: nil}
            >Packets</.link>
            <.link
              patch={~p"/correspondence/calendar"}
              aria-current={
                if @live_action in [
                     :calendar,
                     :import_calendar,
                     :new_calendar_event,
                     :edit_calendar_event
                   ],
                   do: "page"
              }
              class={
                if @live_action in [
                     :calendar,
                     :import_calendar,
                     :new_calendar_event,
                     :edit_calendar_event
                   ], do: "active", else: nil
              }
            >Calendar</.link>
          </nav>
          <div class="corr-header-actions">
            <details class="corr-popover corr-appearance">
              <summary aria-label="Correspondence appearance" title="Appearance">
                {if @correspondence_light?, do: "☀", else: "☾"}
              </summary>
              <div class="corr-popover-panel">
                <button
                  type="button"
                  phx-click="toggle_palette"
                  class="corr-theme"
                  aria-pressed={to_string(@correspondence_light?)}
                >{if @correspondence_light?, do: "Use dark appearance", else: "Use light appearance"}</button>
                <form id="correspondence-color-form" phx-change="change_correspondence_color">
                  <label for="correspondence-color">Color</label>
                  <select id="correspondence-color" name="appearance[color]">
                    <option
                      :for={{label, color} <- Appearance.choices()}
                      value={color}
                      selected={color == @correspondence_color}
                    >
                      {label}
                    </option>
                  </select>
                </form>
              </div>
            </details>
            <.link id="back-to-still" navigate={~p"/"} class="corr-return">Back to Still ↗</.link>
          </div>
        </header>

        <div :if={@problem} class="corr-message error" role="alert">
          {@problem}<.link navigate={~p"/storage"}>Storage &amp; Backups</.link>
        </div>
        <div :if={@notice} class="corr-message" role="status">{@notice}</div>

        <CorrespondenceHome.home
          :if={@live_action == :home && @location.configured && @location.available}
          icons={@place_icons}
          overview={@overview}
        />

        <section
          :if={@live_action == :calendar && @location.configured && @location.available}
          class="corr-page"
        >
          <CorrespondenceCalendar.page
            events={calendar_occurrences(assigns)}
            today={@calendar_today}
            month={@calendar_month}
            selected_date={@calendar_selected}
            query={@calendar_query}
            include_cancelled={@calendar_cancelled}
            include_hidden={@calendar_hidden}
            view={@calendar_view}
            range={@calendar_range}
            page={@calendar_page}
          />
        </section>
        <section
          :if={@live_action == :import_calendar && @location.configured && @location.available}
          class="corr-page"
        >
          <StillWeb.CalendarImport.page
            upload={@uploads.events}
            plan={@calendar_import_plan}
            result={@calendar_import_result}
          />
        </section>

        <section
          :if={
            @live_action in [:new_calendar_event, :edit_calendar_event] && @location.configured &&
              @location.available && @calendar_event_form != %{}
          }
          class="corr-page"
        >
          <StillWeb.CalendarEventEditor.page form={@calendar_event_form} event={@calendar_event} />
        </section>

        <section
          :if={@live_action == :collection && @location.configured && @location.available}
          class="corr-page"
        >
          <CorrespondenceDirectories.works works={@works_directory} />
        </section>

        <CorrespondenceWork.detail
          :if={@live_action == :piece && @piece}
          piece={@piece}
          submission_focus={@submission_focus}
          places={Correspondence.places_to_consider(@overview.journals, @piece)}
          revisions={@revisions}
          history={@history}
          proof_sources={@proof_sources}
          comparison={@comparison}
          proof_problem={@proof_problem}
          proof_plain={@proof_plain}
        />
        <section
          :if={@live_action == :journals && @location.configured && @location.available}
          class="corr-page"
        >
          <CorrespondencePlaces.directory directory={@places_directory} icons={@place_icons} />
        </section>
        <section
          :if={@live_action == :import_journals && @location.configured && @location.available}
          class="corr-page"
        >
          <CorrespondenceImport.page
            upload={@uploads.places}
            plan={@import_plan}
            result={@import_result}
          />
        </section>
        <section :if={@live_action == :journal && @journal} class="corr-page">
          <CorrespondencePlaces.details
            directory_path={places_path(@places_filters)}
            icon={Map.get(@place_icons, @journal.id)}
            journal={@journal}
            packets={@journal_packets}
            pieces={@overview.pieces}
            form={@form}
          />
        </section>
        <section
          :if={@live_action == :new_journal && @location.configured && @location.available}
          class="corr-page"
        >
          <CorrespondencePlaces.editor form={@form} />
        </section>

        <section
          :if={@live_action == :packets && @location.configured && @location.available}
          class="corr-page"
        >
          <CorrespondenceDirectories.packets packets={@packets_directory} />
        </section>

        <section
          :if={@live_action in [:new_packet, :packet] && (@packet || @live_action == :new_packet)}
          class="corr-page editorial-packet-page"
        >
          <div class="corr-breadcrumb">
            <.link patch={~p"/correspondence/packets"}>← Packets</.link>
          </div>
          <div class="corr-page-heading">
            <h1>{if @packet, do: @packet.title, else: "New packet"}</h1>
            <button
              :if={@packet}
              type="button"
              id="duplicate-packet"
              phx-click="duplicate_packet"
              class="corr-text-link"
            >Duplicate packet</button>
            <p :if={@packet} class="corr-meta">
              {if Map.get(@packet, :snapshot),
                do: @packet.snapshot.journal_name,
                else: if(@journal, do: @journal.name, else: "No destination chosen")} · {length(
                @packet.piece_ids
              )} {plural(length(@packet.piece_ids), "poem", "poems")} · {packet_status_label(@packet)}
            </p>
          </div>
          <div class={"corr-packet-grid #{if @packet && Map.get(@packet, :snapshot), do: "is-sent", else: ""}"}>
            <section
              :if={!@packet || @packet.status == "preparing"}
              class="editorial-packet-library"
              aria-label="Choose writing"
            >
              <div class="corr-section-heading">
                <h2>The pieces</h2><.link
                  :if={!@packet || @packet.status == "preparing"}
                  patch={~p"/correspondence/writing"}
                  class="corr-text-link"
                >Choose from Works →</.link>
              </div>
              <form
                id="packet-writing-search"
                phx-change="packet_search"
                class="corr-search editorial-packet-search"
                aria-label="Search packet writing"
              >
                <input
                  name="search"
                  value={@packet_search}
                  aria-label="Find writing for this packet"
                  placeholder="Find a title or line…"
                />
              </form>
              <p class="corr-meta">Choose current saved writing. Its order is yours to arrange.</p>
              <div
                :if={!@packet || @packet.status == "preparing"}
                class="corr-piece-select"
                tabindex="0"
                aria-label="Saved writing to choose from"
              >
                <article
                  :for={piece <- filtered_pieces(@overview.pieces, @packet_search)}
                  class="corr-select-row"
                >
                  <div>
                    <.link patch={~p"/correspondence/writing/#{piece.id}"} class="corr-work-title">{title(
                      piece
                    )}</.link><p>{opening(piece.body)}</p>
                  </div><button
                    type="button"
                    phx-click="toggle_piece"
                    phx-value-id={piece.id}
                    class={if piece.id in (@form[:piece_ids] || []), do: "selected", else: nil}
                  >{if piece.id in (@form[:piece_ids] || []), do: "Added ✓", else: "Add +"}</button>
                </article>
              </div>
              <p :if={filtered_pieces(@overview.pieces, @packet_search) == []} class="corr-empty-side">
                No marked works match. Mark a piece in Write or try another search.
              </p>
            </section>
            <section class="editorial-packet-manuscript" aria-label="Packet manuscript">
              <div
                :if={!@packet || @packet.status == "preparing"}
                class="corr-section-heading ordered"
              >
                <h2>In this order</h2><span>{length(@form[:piece_ids] || [])} {plural(
                  length(@form[:piece_ids] || []),
                  "piece",
                  "pieces"
                )}</span>
              </div>
              <div :if={!@packet || @packet.status == "preparing"} class="corr-ordered">
                <div
                  :for={{id, index} <- Enum.with_index(@form[:piece_ids] || [], 1)}
                  class="corr-ordered-row"
                >
                  <span>{String.pad_leading(to_string(index), 2, "0")}</span><strong>{piece_name(
                    @overview.pieces,
                    id
                  )}</strong><button
                    type="button"
                    phx-click="move_piece"
                    phx-value-id={id}
                    phx-value-direction="up"
                    aria-label="Move up"
                  >↑</button><button
                    type="button"
                    phx-click="move_piece"
                    phx-value-id={id}
                    phx-value-direction="down"
                    aria-label="Move down"
                  >↓</button><button
                    type="button"
                    phx-click="toggle_piece"
                    phx-value-id={id}
                    aria-label="Remove"
                  >×</button>
                </div><p :if={(@form[:piece_ids] || []) == []} class="corr-empty">
                  Add a saved piece to begin.
                </p>
              </div>
              <div
                :if={!@packet || @packet.status == "preparing"}
                id="packet-preview"
                class="editorial-packet-preview"
              >
                <div class="corr-section-heading">
                  <h2>The manuscript</h2><button
                    type="button"
                    phx-click="refresh_packet_preview"
                    class="corr-small-link"
                  >Refresh saved text</button>
                </div>
                <p :if={@packet_preview_problem} class="corr-message error" role="alert">
                  {@packet_preview_problem}
                </p>
                <article
                  :for={piece <- @packet_preview}
                  class="editorial-packet-sheet"
                >
                  <pre>{manuscript_text(piece)}</pre>
                  <div class="packet-sheet-actions">
                    <button
                      type="button"
                      phx-click="edit_packet_piece"
                      phx-value-id={piece.id}
                      class="corr-small-link"
                    >Edit</button><.link
                      patch={~p"/correspondence/writing/#{piece.id}"}
                      class="corr-small-link"
                    >Work &amp; history →</.link>
                  </div>
                </article>
                <p :if={(@form[:piece_ids] || []) == []} class="corr-empty-side">
                  The selected work will appear here, in manuscript order.
                </p>
              </div>
              <div :if={@packet && Map.get(@packet, :snapshot)} class="corr-snapshot">
                <span class="corr-kicker">SUBMITTED VERSION · {date(@packet.snapshot.date)}</span><p>
                  This packet holds its own copy of the text it carried. Later revisions to the saved writing do not change it.
                </p>
                <details :for={sent_piece <- @packet.snapshot.pieces} class="corr-version" open>
                  <summary>Read “{sent_piece.title}” exactly as sent</summary><pre>{sent_piece.body}</pre>
                  <.link
                    patch={~p"/correspondence/writing/#{sent_piece.id}"}
                    class="corr-small-link"
                  >Open current work and history →</.link>
                </details>
                <.link
                  href={~p"/correspondence/packets/#{@packet.id}/export/txt"}
                  class="corr-text-link"
                >Download plain text →</.link><span> · </span><.link
                  href={~p"/correspondence/packets/#{@packet.id}/export/docx"}
                  class="corr-text-link"
                >Download DOCX</.link>
              </div>
            </section><aside class="corr-destination-panel">
              <h2>Packet details</h2>
              <.form
                :if={!@packet || @packet.status == "preparing"}
                id="packet-form"
                for={%{}}
                as={:packet}
                phx-submit="save_packet"
                phx-change="set_packet_journal"
                class="corr-packet-form"
              >
                <label>Packet title<input
                  name="packet[title]"
                  value={value(@form, :title, "Untitled packet")}
                /></label>
                <label>Destination · optional while preparing<select name="packet[journal_id]"><option value="">
                  Choose later
                </option><option
                  :for={
                    journal <-
                      Enum.filter(
                        @overview.journals,
                        &(Correspondence.active_journal?(&1) || &1.id == value(@form, :journal_id))
                      )
                  }
                  value={journal.id}
                  disabled={journal.inactive}
                  selected={value(@form, :journal_id) == journal.id}
                >
                  {journal.name}{if journal.inactive, do: " (inactive)", else: ""}
                </option></select></label>
                <p :if={@journal} class="corr-guideline">
                  <b>{policy_label(@journal.simultaneous_policy)}</b><br />{value(
                    @journal,
                    :guidelines
                  )}<br /><span :if={!checked?(@journal.verified)}>Personal notes · not verified</span><span :if={
                    checked?(@journal.verified)
                  }>Marked source-checked by you</span>
                </p>
                <.link patch={~p"/correspondence/journals/new"} class="corr-small-link">Add a place you saved →</.link>
                <label :if={!@packet}>Submission notes<textarea
                  name="packet[preparation_notes]"
                  rows="10"
                >{value(@form, :preparation_notes)}</textarea></label>
                <section class="packet-cover-letter" aria-label="Cover letter">
                  <h3>Cover letter</h3>
                  <button type="button" phx-click="choose_cover_letter" class="corr-small-link">Choose saved writing…</button>
                  <label :if={
                    @cover_letter_choices != [] || value(@form, :cover_letter_piece_id) != ""
                  }>
                    Saved writing
                    <select id="packet-cover-letter" name="packet[cover_letter_piece_id]">
                      <option value="">Use the draft below</option>
                      <option
                        :if={
                          value(@form, :cover_letter_piece_id) != "" &&
                            !Enum.any?(
                              @cover_letter_choices,
                              &(&1.id == value(@form, :cover_letter_piece_id))
                            )
                        }
                        value={value(@form, :cover_letter_piece_id)}
                        selected
                      >
                        {if @cover_letter_preview,
                          do: @cover_letter_preview.title,
                          else: "Linked writing unavailable"}
                      </option>
                      <option
                        :for={piece <- @cover_letter_choices}
                        value={piece.id}
                        selected={value(@form, :cover_letter_piece_id) == piece.id}
                      >
                        {title(piece)} · {piece.relative_path}
                      </option>
                    </select>
                  </label>
                  <p class="corr-meta">
                    Saved writing can be a scratch page. It doesn't need to be marked for Correspondence.
                  </p>
                  <p :if={@cover_letter_problem} class="corr-message error" role="alert">
                    {@cover_letter_problem}
                  </p>
                  <div :if={@cover_letter_preview} id="packet-letter-preview">
                    <pre>{@cover_letter_preview.body}</pre>
                    <StillWeb.CopyText.copy_text
                      id="copy-packet-cover-letter"
                      body={@cover_letter_preview.body}
                      title_in_body={true}
                    />
                    <button
                      type="button"
                      phx-click="edit_packet_piece"
                      phx-value-id={value(@form, :cover_letter_piece_id)}
                      class="corr-small-link"
                    >Edit cover letter</button>
                  </div>
                  <label :if={value(@form, :cover_letter_piece_id) == ""}>Or write a draft here<textarea
                    name="packet[cover_letter]"
                    rows="6"
                  >{value(@form, :cover_letter)}</textarea></label>
                </section>
                <button type="submit" class="corr-button">{if @packet,
                  do: "Save changes",
                  else: "Save packet"} <span>→</span></button>
              </.form>
              <div :if={@packet && Map.get(@packet, :snapshot)} class="corr-journal-detail">
                <span class="corr-kicker">DESTINATION</span>
                <p>
                  <strong>{@packet.snapshot.journal_name}</strong>
                </p>
                <p :if={@journal && @journal.guidelines}>{@journal.guidelines}</p>
                <p :if={@journal && @journal.simultaneous_policy}>
                  <b>{policy_label(@journal.simultaneous_policy)}</b>
                </p>
                <p :if={@journal && valid_web_url?(@journal.submission_url)}>
                  Actual submission page:
                  <a href={@journal.submission_url} target="_blank" rel="noopener noreferrer">Open journal submission page ↗</a>
                </p>
                <p :if={@journal && !valid_web_url?(@journal.submission_url)}>
                  No submission URL is saved for this place.
                </p>
                <p :if={!@journal}>The saved journal details are unavailable.</p>
              </div>
              <div :if={@packet && @packet.status != "preparing"} class="corr-readonly-packet">
                <span class="corr-kicker">COVER LETTER AS SENT</span><pre>{value(@packet, :cover_letter, "No cover letter recorded.")}</pre>
                <StillWeb.CopyText.copy_text
                  :if={@packet.cover_letter not in [nil, ""]}
                  id="copy-sent-cover-letter"
                  body={@packet.cover_letter}
                  title_in_body={true}
                />
                <div class="corr-packet-timeline">
                  <h3>Its journey</h3><article
                    :for={event <- Enum.reverse(@packet.events || [])}
                    class="corr-event"
                  >
                    <span>{event_label(event)} · {date(event.date)}</span><p :if={event.note}>
                      {event.note}
                    </p>
                  </article>
                </div>
              </div>
              <p :if={
                (!@packet || @packet.status == "preparing") && @journal &&
                  valid_web_url?(@journal.submission_url)
              }>
                <a
                  href={@journal.submission_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="corr-small-link"
                >Open submission page ↗</a>
              </p>
              <section :if={@packet} class="corr-packet-export" aria-label="Export packet">
                <h2>Submission copy</h2>
                <p class="corr-meta">
                  A clean manuscript, one poem starting on each page. Cover letters and private notes stay here.
                </p>
                <button
                  type="button"
                  class="corr-button"
                  phx-click="export_packet_pdf"
                  disabled={@pdf_exporting? || packet_unsaved?(@form, @packet)}
                >
                  {if @pdf_exporting?, do: "Preparing PDF…", else: "Save as PDF"}
                </button>
                <p :if={@packet_export_notice} role="status" class="corr-meta">
                  {@packet_export_notice}
                </p>
                <button
                  :if={@last_packet_export}
                  type="button"
                  class="corr-small-link"
                  phx-click="reveal_packet_export"
                >Show PDF in Finder</button>
              </section>
              <p
                :if={
                  @packet && packet_review_needed?(@packet, @packet_preview, @cover_letter_preview)
                }
                class="corr-unsaved-note"
                id="packet-review-needed"
              >
                Saved writing has changed. Review the manuscript and cover letter, then Save changes before exporting or marking it sent.
              </p>
              <p :if={@packet && packet_unsaved?(@form, @packet)} class="corr-unsaved-note">
                This packet has unsaved changes. Save it before exporting or marking it sent.
              </p>
              <p :if={!@packet} class="corr-unsaved-note">
                Save this packet draft to keep the selected pieces, their order, and your notes.
              </p>
              <div
                :if={@packet && !Map.get(@packet, :snapshot) && !packet_unsaved?(@form, @packet)}
                class="corr-snapshot"
              >
                <span class="corr-kicker">REVIEW THE MANUSCRIPT</span><p>
                  Export the prepared packet to read it as a submission copy.
                </p><.link
                  href={~p"/correspondence/packets/#{@packet.id}/export/txt"}
                  class="corr-text-link"
                >Download plain text →</.link><span> · </span><.link
                  href={~p"/correspondence/packets/#{@packet.id}/export/docx"}
                  class="corr-text-link"
                >Download DOCX</.link>
              </div>
              <div :if={@overlap != []} class="corr-overlap" role="note">
                <b>{if @packet && @packet.accepted_piece_ids != [],
                  do: "Review other outstanding submissions",
                  else: "Some pieces are already away."}</b>
                <p :if={@packet && @packet.accepted_piece_ids != []}>
                  Accepted work may need withdrawal elsewhere. Still has not contacted anyone.
                </p><p :for={item <- @overlap}>
                  {piece_name(@overview.pieces, item.piece_id)} is with {overlap_journal_name(item)}. Check that journal’s simultaneous-submission policy before proceeding.
                </p>
              </div>
              <form
                :if={@packet && @packet.status == "preparing"}
                phx-submit="submit_packet"
                class="corr-send-form"
              >
                <label>Submission date<input type="date" name="date" value={today()} required /></label><button
                  class="corr-button"
                  type="submit"
                >Mark as sent <span>→</span></button><small>This records the packet here. It does not contact the journal.</small>
              </form>
              <div :if={@packet && @packet.status == "submitted"} class="corr-response">
                <form phx-submit="set_status">
                  <button type="submit" name="status" value="awaiting" class="corr-text-link">Mark as awaiting response →</button>
                </form>
              </div>
              <div :if={@packet && @packet.status == "awaiting"} class="corr-response">
                <form phx-submit="set_status">
                  <button type="submit" name="status" value="submitted" class="corr-text-link">Return to submitted →</button><button
                    type="submit"
                    name="status"
                    value="withdrawn"
                    class="corr-text-link"
                  >Mark withdrawn →</button>
                </form>
              </div>
              <div :if={@packet && response_open?(@packet)} class="corr-response">
                <div class="corr-kicker">RECORD A REPLY</div><.form
                  id="response-form"
                  for={%{}}
                  as={:response}
                  phx-submit="record_response"
                >
                  <label>Reply<select name="response[status]"><option value="declined">
                    Returned with thanks
                  </option><option value="accepted">Accepted</option><option value="withdrawn">
                    Withdrawn
                  </option></select></label><label>Date<input
                    type="date"
                    name="response[date]"
                    value={today()}
                  /></label><label>Notes<textarea
                    name="response[notes]"
                    rows="3"
                    placeholder="A note to help future you remember"
                  ></textarea></label>
                  <div class="corr-accepted-list">
                    <span class="corr-kicker">IF ACCEPTED, WHICH PIECES?</span><input
                      type="hidden"
                      name="response[accepted_piece_ids][]"
                      value=""
                    /><label :for={id <- response_piece_ids(@packet)} class="corr-check"><input
                      type="checkbox"
                      name="response[accepted_piece_ids][]"
                      value={id}
                      checked
                    /> {piece_name(@overview.pieces, id)}</label>
                  </div>
                  <button type="submit" class="corr-text-link">Record reply →</button>
                </.form>
              </div>
            </aside>
            <section
              :if={@packet && @packet_notes}
              class="corr-submission-notes"
              aria-label="Submission notes"
            >
              <h2>Submission notes</h2>
              <p class="corr-meta">
                Your private notes, editable even after sending. These stay out of the manuscript and PDF.
              </p>
              <div
                id={"packet-notes-#{@packet.id}"}
                phx-update="ignore"
                data-packet-notes
              >
                <label for="packet-notes-body" class="sr-only">Submission notes</label>
                <textarea
                  id="packet-notes-body"
                  rows="12"
                  phx-hook="PacketNotes"
                  data-packet-id={@packet.id}
                  data-scope={@location.scope}
                  data-token={@packet_notes.token || ""}
                  data-persisted={@packet_notes.body}
                >{@packet_notes.body}</textarea>
                <p data-notes-status role="status" class="corr-meta">Saved notes</p>
                <button type="button" data-notes-save class="corr-button">Save notes</button>
                <button type="button" data-notes-restore class="corr-small-link" hidden>Restore local notes</button>
              </div>
            </section>
          </div>
        </section>
        <footer :if={@location && @location.configured && @location.available} class="corr-footer">
          <span>STILL · A ROOM FOR WRITING</span><span>Correspondence keeps the words close as they travel.</span><span>Saved in your collection</span>
        </footer>
      </div>
    </Layouts.app>
    """
  end

  defp filtered_pieces(pieces, search), do: Correspondence.search_pieces(pieces, search)

  defp overlap_journal_name(%{journal: %{name: name}}), do: name

  defp overlap_journal_name(%{packet: %{snapshot: %{journal_name: name}}}) when is_binary(name),
    do: name

  defp overlap_journal_name(_), do: "another place"

  defp packet_status_label(%{status: "accepted"} = packet) do
    if length(packet.accepted_piece_ids || []) < length(packet.piece_ids),
      do: "PARTLY ACCEPTED · AWAITING",
      else: "ACCEPTED"
  end

  defp packet_status_label(packet), do: status_label(packet.status)
  defp response_open?(%{status: status}) when status in ["submitted", "awaiting"], do: true

  defp response_open?(%{status: "accepted"} = packet),
    do: length(packet.accepted_piece_ids || []) < length(packet.piece_ids)

  defp response_open?(_), do: false

  defp response_piece_ids(%{status: "accepted", piece_ids: ids, accepted_piece_ids: accepted}),
    do: ids -- (accepted || [])

  defp response_piece_ids(%{piece_ids: ids}), do: ids

  defp packet_unsaved?(form, packet) do
    Enum.any?(
      [
        :title,
        :journal_id,
        :piece_ids,
        :preparation_notes,
        :cover_letter,
        :cover_letter_piece_id
      ],
      fn key ->
        (Map.get(form, key) || "") != (Map.get(packet, key) || "")
      end
    )
  end

  defp packet_review_needed?(%{status: "preparing"} = packet, pieces, letter) do
    (Enum.any?(pieces, &(Map.get(packet.piece_tokens, &1.id) != &1.token)) or
       (packet.cover_letter_piece_id && letter && packet.cover_letter_piece_token != letter.token)) ||
      false
  end

  defp packet_review_needed?(_, _, _), do: false

  defp date(nil), do: "date not recorded"

  defp date(%Date{} = date),
    do: Elixir.Calendar.strftime(date, "%d %b %Y") |> String.replace_prefix("0", "")

  defp date(%DateTime{} = date),
    do: Elixir.Calendar.strftime(date, "%d %b %Y") |> String.replace_prefix("0", "")

  defp date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date_time, _offset} ->
        date(date_time)

      _ ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date(date)
          _ -> value
        end
    end
  end

  defp date(_), do: "date not recorded"
  defp today, do: Date.utc_today() |> Date.to_iso8601()
  defp event_label(%{status: status}) when is_binary(status), do: status_label(status)
  defp event_label(%{kind: "submitted"}), do: "SUBMITTED"
  defp event_label(%{kind: "status"}), do: "STATUS UPDATED"
  defp event_label(_), do: "REPLY RECORDED"

  defp valid_web_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp valid_web_url?(_), do: false
  defp status_label("preparing"), do: "IN PREPARATION"
  defp status_label("submitted"), do: "SUBMITTED"
  defp status_label("awaiting"), do: "AWAITING RESPONSE"
  defp status_label("declined"), do: "RETURNED"
  defp status_label("accepted"), do: "ACCEPTED"
  defp status_label("withdrawn"), do: "WITHDRAWN"
  defp status_label(status), do: status |> text() |> String.upcase()
  defp policy_label("allowed"), do: "Simultaneous submissions allowed"
  defp policy_label("not_allowed"), do: "Simultaneous submissions not allowed"
  defp policy_label(_), do: "Simultaneous-submission policy unknown"

  defp piece_name(pieces, id),
    do:
      case(Enum.find(pieces, &(&1.id == id)),
        do: (
          nil -> "Work unavailable"
          piece -> title(piece)
        )
      )

  defp plural(1, one, _), do: one
  defp plural(_, _, many), do: many
end
