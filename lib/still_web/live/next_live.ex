defmodule StillWeb.NextLive do
  use StillWeb, :live_view
  on_mount {StillWeb.CorrespondenceWorkspace, :appearance}

  alias Still.{Storage, Next}
  alias Still.Correspondence.Appearance
  alias Still.Next.{Directory, Target}
  alias StillWeb.{CorrespondenceWorkspace, NextLinks}

  @impl true
  def mount(_params, _session, socket) do
    appearance = Appearance.current()

    {:ok,
     assign(socket,
       page_title: "Next",
       problem: nil,
       notice: nil,
       editor_key: nil,
       capture_version: 0,
       correspondence_light?: appearance.light?,
       correspondence_color: appearance.color,
       tasks: [],
       editing: nil,
       form: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    location = Storage.collection_location()

    today = Next.today()

    context =
      params |> Map.take(~w(edit from ref on new)) |> Map.filter(fn {_, v} -> is_binary(v) end)

    editor_key = {location.scope, context}

    socket =
      assign(socket,
        location: location,
        context: context,
        today: today,
        filters: Directory.filters(params)
      )

    case Next.list(location) do
      {:ok, tasks} ->
        socket = put_tasks(assign(socket, collection_problem: nil), tasks)

        if socket.assigns.editor_key == editor_key do
          {:noreply, socket}
        else
          {:noreply, open_editor(assign(socket, editor_key: editor_key), tasks, context)}
        end

      {:error, message} ->
        {:noreply,
         assign(reset_editor(socket, nil),
           collection_problem: message,
           editor_key: nil,
           tasks: []
         )}
    end
  end

  @impl true
  def handle_event("filter_tasks", params, socket) do
    %{filters: filters, context: context} = socket.assigns

    filters =
      filters
      |> Map.merge(Map.take(params, ~w(q source)))
      |> Map.put("page", 1)
      |> Directory.filters()

    {:noreply, push_patch(socket, to: list_path(filters, context), replace: true)}
  end

  def handle_event(
        "capture_task",
        %{"capture" => %{"details" => "true", "title" => title}},
        socket
      )
      when is_binary(title) do
    {:noreply,
     socket
     |> assign(capture_form: capture_form(title), notice: nil, problem: nil)
     |> push_patch(to: list_path(socket.assigns.filters, %{"new" => "true"}))}
  end

  def handle_event("capture_task", %{"capture" => %{"title" => title}}, socket) do
    case Next.save(socket.assigns.location, %{"title" => title}) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> assign(capture_form: capture_form(""), notice: "Item added.", problem: nil)
         |> update(:capture_version, &(&1 + 1))
         |> show_saved(Directory.defaults())}

      {:error, message} ->
        {:noreply,
         assign(socket, capture_form: capture_form(title), problem: message, notice: nil)}
    end
  end

  def handle_event("save_task", %{"task" => attrs}, %{assigns: %{form: form}} = socket)
      when not is_nil(form) and is_map(attrs) do
    %{location: location, editing: editing, target: target, filters: filters} =
      socket.assigns

    attrs = Map.take(attrs, ~w(title notes planned_on due_on detach))
    target = if attrs["detach"] == "true", do: nil, else: target

    case Next.save(location, Map.put(attrs, "target", target), editing) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> assign(notice: if(editing, do: "Item saved.", else: "Item added."), problem: nil)
         |> show_saved(if(editing, do: filters, else: Directory.defaults()))}

      {:error, message} ->
        {:noreply, assign(socket, form: to_form(attrs, as: :task), problem: message, notice: nil)}
    end
  end

  def handle_event("task_action", %{"id" => id, "action" => action}, socket) do
    %{location: location, tasks: tasks, today: today} = socket.assigns

    case Enum.find(tasks, &(&1.id == id)) do
      nil ->
        {:noreply, assign(socket, problem: "This item is unavailable.", notice: nil)}

      selected ->
        editing = socket.assigns.editing
        task = if editing && editing.id == id, do: editing, else: selected

        case change_task(location, task, action, today) do
          {:ok, updated, notice} ->
            socket =
              socket
              |> put_tasks(Enum.map(tasks, &if(&1.id == id, do: updated, else: &1)))
              |> assign(problem: nil, notice: notice)

            {:noreply,
             if(editing && editing.id == id, do: assign(socket, :editing, updated), else: socket)}

          {:error, message} ->
            {:noreply, assign(socket, problem: message, notice: nil)}
        end
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp change_task(location, task, "today", today) when task.status == :open do
    with {:ok, updated} <- Next.save(location, %{"planned_on" => today}, task),
         do: {:ok, updated, "Planned for today."}
  end

  defp change_task(location, task, "done", _today) when task.status == :open,
    do: set_status(location, task, :done, "Item completed.")

  defp change_task(location, task, "reopen", _today) when task.status != :open,
    do: set_status(location, task, :open, "Item reopened.")

  defp change_task(location, task, "archive", _today) when task.status == :open,
    do: set_status(location, task, :archived, "Item archived.")

  defp change_task(_location, _task, _action, _today),
    do: {:error, "Reopen this item before changing it."}

  defp set_status(location, task, status, notice) do
    with {:ok, updated} <- Next.set_status(location, task, status), do: {:ok, updated, notice}
  end

  defp put_tasks(socket, tasks) do
    %{filters: filters, today: today} = socket.assigns
    assign(socket, tasks: tasks, directory: Directory.browse(tasks, filters, today))
  end

  defp show_saved(socket, filters) do
    if socket.assigns.filters == filters && socket.assigns.context == %{} do
      # Even when staying on the same URL, include the newly captured task.
      case Next.list(socket.assigns.location) do
        {:ok, tasks} -> put_tasks(socket, tasks)
        {:error, message} -> assign(socket, collection_problem: message, editor_key: nil)
      end
    else
      push_patch(socket, to: list_path(filters))
    end
  end

  defp open_editor(socket, tasks, %{"edit" => id}) do
    id = String.downcase(id)

    case Enum.find(tasks, &(&1.id == id)) do
      nil -> reset_editor(socket, "This item is unavailable in the selected writing folder.")
      task -> put_editor(socket, task, task.target, task.planned_on)
    end
  end

  defp open_editor(socket, _tasks, %{"from" => type, "ref" => id}) do
    case Target.parse(type, id) do
      nil -> reset_editor(socket, "This correspondence link is invalid.")
      target -> put_editor(socket, nil, target, nil)
    end
  end

  defp open_editor(socket, _tasks, %{"on" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, planned} -> put_editor(socket, nil, nil, planned)
      _ -> reset_editor(socket, "Choose a valid calendar date.")
    end
  end

  defp open_editor(socket, _tasks, %{"new" => "true"}) do
    title =
      if socket.assigns[:capture_form], do: socket.assigns.capture_form[:title].value, else: ""

    put_editor(socket, nil, nil, nil, title)
  end

  defp open_editor(socket, _tasks, _params), do: reset_editor(socket, nil)

  defp reset_editor(socket, problem) do
    assign(socket,
      editing: nil,
      target: nil,
      target_label: nil,
      form: nil,
      capture_form: capture_form(""),
      editor_problem: problem,
      earlier_notes: []
    )
  end

  defp put_editor(socket, task, target, planned_on, draft_title \\ "") do
    location = socket.assigns.location
    target_label = if target, do: Target.label(location, target)
    {earlier, problem} = earlier_notes(location, task)

    attrs = %{
      "title" => if(task, do: task.title, else: draft_title),
      "notes" => if(task, do: task.notes, else: ""),
      "planned_on" => planned_on && Date.to_iso8601(planned_on),
      "due_on" => task && task.due_on && Date.to_iso8601(task.due_on)
    }

    assign(socket,
      editing: task,
      target: target,
      target_label: target_label,
      editor_problem: problem,
      capture_form: capture_form(""),
      form: to_form(attrs, as: :task),
      earlier_notes: earlier
    )
  end

  defp earlier_notes(_location, nil), do: {[], nil}

  defp earlier_notes(location, task) do
    case Next.history(location, task) do
      {:ok, history} ->
        [_current | earlier] = Enum.dedup_by([task | history], &{&1.title, &1.notes})
        {earlier, nil}

      {:error, message} ->
        {[], message}
    end
  end

  defp capture_form(title), do: to_form(%{"title" => title}, as: :capture)

  defp list_path(filters, context \\ %{}) do
    defaults = Directory.defaults()

    params =
      filters
      |> Map.reject(fn {name, value} -> defaults[name] == value end)
      |> Map.merge(context)

    if params == %{}, do: ~p"/correspondence/next", else: ~p"/correspondence/next?#{params}"
  end

  defp blank_state("today"), do: "Nothing is planned or due today."
  defp blank_state("upcoming"), do: "Future plans and deadlines will appear here."
  defp blank_state("history"), do: "Completed and archived items will appear here."
  defp blank_state(_), do: "The list is clear."

  defp date_label(date, today) do
    cond do
      date == today -> "Today"
      date == Date.add(today, 1) -> "Tomorrow"
      date.year == today.year -> Calendar.strftime(date, "%b %-d")
      true -> Calendar.strftime(date, "%b %-d, %Y")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <CorrespondenceWorkspace.workspace
      flash={@flash}
      appearance_light?={@correspondence_light?}
      appearance_color={@correspondence_color}
      active_next?
      nav_mode={:navigate}
      problem={@collection_problem}
    >
      <section id="next-page" class="corr-page" aria-labelledby="next-heading">
        <header class="corr-directory-heading next-directory-heading">
          <h1 id="next-heading">Next</h1>
          <.form
            :if={!@collection_problem && !@form}
            for={@capture_form}
            id="next-capture"
            class="next-capture"
            phx-submit="capture_task"
          >
            <% capture_id = "capture_title-#{@capture_version}" %>
            <label class="sr-only" for={capture_id}>New item title</label>
            <div class="corr-directory-search">
              <input
                id={capture_id}
                name={@capture_form[:title].name}
                value={@capture_form[:title].value}
                placeholder="What would you like to do?"
                maxlength="300"
                required
                phx-mounted={if @capture_version > 0, do: JS.focus(to: "##{capture_id}")}
              />
            </div>
            <button type="submit" class="corr-button corr-button-primary" phx-disable-with="Adding…">Add item</button>
            <button
              type="submit"
              name="capture[details]"
              value="true"
              formnovalidate
              class="corr-text-link next-quiet-action"
            >Add with details</button>
          </.form>
        </header>

        <p :if={@problem} class="corr-message error" role="alert">{@problem}</p>
        <p :if={@notice} class="corr-message" role="status">{@notice}</p>

        <div :if={!@collection_problem}>
          <.form
            for={%{}}
            class="corr-directory-toolbar next-directory-toolbar"
            id="next-filters"
            phx-change="filter_tasks"
            phx-submit="filter_tasks"
          >
            <label class="corr-directory-search">
              <span class="sr-only">Find items</span>
              <input
                type="search"
                name="q"
                value={@filters["q"]}
                maxlength="300"
                phx-debounce="250"
                placeholder="Find items"
              />
            </label>
            <details class="corr-popover corr-directory-filters">
              <summary>Filters</summary>
              <div class="corr-popover-panel">
                <label for="next-source-filter">Source</label>
                <select id="next-source-filter" name="source">
                  <option
                    :for={{label, source} <- Directory.sources()}
                    value={source}
                    selected={source == @filters["source"]}
                  >
                    {label}
                  </option>
                </select>
              </div>
            </details>
            <nav class="corr-calendar-view-switch next-views" aria-label="Item views">
              <.link
                :for={{label, value} <- Directory.views()}
                patch={list_path(%{@filters | "view" => value, "page" => 1}, @context)}
                aria-current={if @filters["view"] == value, do: "page"}
              >{label}</.link>
            </nav>
            <.link
              id="reset-next"
              class="corr-text-link"
              patch={list_path(Directory.defaults(), @context)}
            >Reset</.link>
          </.form>

          <p :if={@editor_problem} class="corr-message error" role="alert">{@editor_problem}</p>
          <section
            :if={@form}
            id="next-workspace"
            class="next-workspace"
            aria-labelledby="next-workspace-heading"
          >
            <header class="next-workspace-heading">
              <h2 id="next-workspace-heading">{if @editing, do: "Edit item", else: "Add item"}</h2>
              <.link class="corr-text-link" patch={list_path(@filters)}>Close</.link>
            </header>

            <.form
              for={@form}
              id="next-editor"
              phx-submit="save_task"
              phx-mounted={JS.focus(to: "#task_title")}
            >
              <label for={@form[:title].id}>
                Title
                <input
                  id={@form[:title].id}
                  name={@form[:title].name}
                  value={@form[:title].value}
                  maxlength="300"
                  required
                />
              </label>
              <label for={@form[:notes].id}>
                Notes <textarea
                  id={@form[:notes].id}
                  name={@form[:notes].name}
                  rows="4"
                  maxlength="20000"
                >{@form[:notes].value}</textarea>
              </label>
              <div class="next-dates">
                <label for={@form[:planned_on].id}>
                  Plan for
                  <input
                    type="date"
                    id={@form[:planned_on].id}
                    name={@form[:planned_on].name}
                    value={@form[:planned_on].value}
                  />
                </label>
                <label for={@form[:due_on].id}>
                  Deadline
                  <input
                    type="date"
                    id={@form[:due_on].id}
                    name={@form[:due_on].name}
                    value={@form[:due_on].value}
                  />
                </label>
              </div>
              <div :if={@target} class="next-source">
                <span>{Target.kind(@target.type)}</span>
                <.link :if={@target_label} navigate={NextLinks.source_path(@target)}>{@target_label} ↗</.link>
                <p :if={!@target_label}>This correspondence item is unavailable.</p>
                <label>
                  <input
                    type="checkbox"
                    name={@form[:detach].name}
                    value="true"
                    checked={@form[:detach].value == "true"}
                  /> Save without the link
                </label>
              </div>
              <div class="next-editor-actions">
                <button
                  type="submit"
                  class="corr-button corr-button-primary"
                  phx-disable-with="Saving…"
                >
                  {if @editing, do: "Save changes", else: "Add item"}
                </button>
                <button
                  :if={@editing && @editing.status == :open}
                  type="button"
                  class="corr-text-link next-quiet-action"
                  phx-click="task_action"
                  phx-value-id={@editing.id}
                  phx-value-action="archive"
                >Archive item</button>
              </div>
            </.form>

            <details :if={@earlier_notes != []} class="next-earlier-notes">
              <summary>Earlier notes</summary>
              <div :for={earlier <- @earlier_notes}>
                <strong>{earlier.title}</strong>
                <p :if={earlier.notes != ""}>{earlier.notes}</p>
              </div>
            </details>
          </section>

          <p id="next-result-count" class="corr-result-count" role="status">
            <%= cond do %>
              <% @directory.count == 0 -> %>
                0 items
              <% @directory.count == 1 -> %>
                1 item
              <% @directory.pages == 1 -> %>
                {@directory.count} items
              <% true -> %>
                {@directory.first}–{@directory.last} of {@directory.count} items
            <% end %>
          </p>

          <div class="corr-table-scroll" tabindex="0" role="region" aria-label="Next items">
            <table class="corr-table next-table" id="next-table">
              <thead>
                <tr>
                  <.sort_column label="Item" sort="title" filters={@filters} context={@context} />
                  <.sort_column label="Plan" sort="plan" filters={@filters} context={@context} />
                  <.sort_column
                    label="Deadline"
                    sort="deadline"
                    filters={@filters}
                    context={@context}
                  />
                  <th scope="col">Linked to</th>
                  <th scope="col">Actions</th>
                </tr>
              </thead>
              <tbody id="next-items">
                <tr :if={@directory.rows == []}>
                  <td colspan="5" class="next-empty">
                    {if @filters["q"] == "" && @filters["source"] == "all",
                      do: blank_state(@filters["view"]),
                      else: "No items match these filters."}
                  </td>
                </tr>
                <tr
                  :for={task <- @directory.rows}
                  id={"next-#{task.id}"}
                  data-status={task.status}
                  aria-current={if @editing && @editing.id == task.id, do: "true"}
                >
                  <td>
                    <.link
                      class="corr-table-title next-item-title"
                      patch={list_path(@filters, %{"edit" => task.id})}
                    >{task.title}</.link>
                    <p :if={task.notes != ""} class="next-item-notes">{task.notes}</p>
                    <p :if={task.status != :open} class="next-item-status">
                      {if task.status == :done, do: "Completed", else: "Archived"}
                    </p>
                  </td>
                  <td class="next-table-date">
                    <time :if={task.planned_on} datetime={Date.to_iso8601(task.planned_on)}>
                      {date_label(task.planned_on, @today)}
                    </time>
                    <span :if={!task.planned_on} aria-label="No plan date">—</span>
                  </td>
                  <td class={[
                    "next-table-date",
                    task.status == :open && Next.overdue?(task, @today) && "next-overdue"
                  ]}>
                    <time :if={task.due_on} datetime={Date.to_iso8601(task.due_on)}>
                      {date_label(task.due_on, @today)}
                    </time>
                    <p :if={task.status == :open && Next.overdue?(task, @today)}>Overdue</p>
                    <span :if={!task.due_on} aria-label="No deadline">—</span>
                  </td>
                  <td>
                    <span :if={task.target}>{Target.kind(task.target.type)}</span>
                    <span :if={!task.target} aria-label="Unlinked">—</span>
                  </td>
                  <td>
                    <div class="next-row-actions">
                      <button
                        type="button"
                        class="next-check"
                        aria-label={"#{if task.status == :open, do: "Complete", else: "Reopen"} #{task.title}"}
                        phx-click="task_action"
                        phx-value-id={task.id}
                        phx-value-action={if task.status == :open, do: "done", else: "reopen"}
                      >{if task.status == :open, do: "Complete", else: "Reopen"}</button>
                      <button
                        :if={
                          task.status == :open && task.planned_on != @today &&
                            !(@editing && @editing.id == task.id)
                        }
                        type="button"
                        class="next-plan-today"
                        aria-label={"Plan #{task.title} for today"}
                        phx-click="task_action"
                        phx-value-id={task.id}
                        phx-value-action="today"
                      >Plan today</button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <nav :if={@directory.pages > 1} class="corr-pagination" aria-label="Next pages">
            <.link
              :if={@directory.page > 1}
              class="corr-text-link"
              patch={list_path(%{@filters | "page" => @directory.page - 1}, @context)}
            >Previous</.link>
            <span>Page {@directory.page} of {@directory.pages}</span>
            <.link
              :if={@directory.page < @directory.pages}
              class="corr-text-link"
              patch={list_path(%{@filters | "page" => @directory.page + 1}, @context)}
            >Next page</.link>
          </nav>
        </div>
      </section>
    </CorrespondenceWorkspace.workspace>
    """
  end

  defp sort_column(assigns) do
    active? = assigns.filters["sort"] == assigns.sort
    desc? = assigns.filters["dir"] == "desc"
    dir = if active? && !desc?, do: "desc", else: "asc"

    assigns =
      assign(assigns,
        aria_sort: if(active?, do: if(desc?, do: "descending", else: "ascending")),
        arrow: if(active?, do: if(desc?, do: "↓", else: "↑")),
        path:
          list_path(
            %{assigns.filters | "sort" => assigns.sort, "dir" => dir, "page" => 1},
            assigns.context
          )
      )

    ~H"""
    <th scope="col" aria-sort={@aria_sort}>
      <.link patch={@path} class="next-sort">
        {@label}<span :if={@arrow} aria-hidden="true">{@arrow}</span>
      </.link>
    </th>
    """
  end
end
