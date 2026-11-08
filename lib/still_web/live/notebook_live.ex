defmodule StillWeb.NotebookLive do
  use StillWeb, :live_view

  alias Still.{Poems, Storage, Writing}
  alias Still.Writing.Notebook
  alias Still.Writing.ReadingPlace
  alias StillWeb.ReadingLinks

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:notebooks, [])
     |> assign(:reading_bookmark, nil)
     |> assign(:notebook, nil)
     |> assign(:missing, false)
     |> assign(:problem, nil)
     |> assign(:selected_id, nil)
     |> assign(:delete_list, nil)
     |> assign(:notebook_form, to_form(Notebook.changeset(%Notebook{}, %{})))}
  end

  @impl true
  def handle_event("create_notebook", %{"notebook" => attrs}, socket) do
    case Writing.create_folder_notebook(attrs) do
      {:ok, notebook} ->
        {:noreply,
         socket
         |> put_flash(:info, "Notebook added.")
         |> assign(:notebooks, Writing.notebooks())
         |> push_patch(to: ~p"/notebooks?notebook=#{notebook.key}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :notebook_form, to_form(changeset))}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("choose_current", %{"id" => id}, socket) do
    result =
      if id == "",
        do: Writing.choose_current_notebook(nil),
        else: Writing.choose_current_notebook(String.to_integer(id))

    case result do
      {:ok, _} -> {:noreply, assign(socket, :notebooks, Writing.notebooks())}
      _ -> {:noreply, put_flash(socket, :error, "That notebook could not be selected.")}
    end
  end

  def handle_event("rename_section", %{"section" => key, "label" => label}, socket) do
    update_section(socket, fn notebook ->
      Still.Writing.NotebookSections.rename(notebook.key, key, label)
    end)
  end

  def handle_event("choose_section", %{"section" => key}, socket) do
    update_section(socket, fn notebook ->
      Still.Writing.NotebookSections.choose(notebook.key, key)
    end)
  end

  def handle_event("request_delete_list", %{"id" => id}, socket) do
    if notebook_contains?(socket.assigns.notebook, id) do
      case Poems.get(Storage.collection_location(), id) do
        {:ok, piece} -> {:noreply, assign(socket, :delete_list, piece)}
        {:error, message} -> {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:noreply, put_flash(socket, :error, "That List is no longer in this notebook.")}
    end
  end

  def handle_event("cancel_delete_list", _, socket),
    do: {:noreply, assign(socket, :delete_list, nil)}

  def handle_event(
        "confirm_delete_list",
        _,
        %{assigns: %{delete_list: piece, notebook: notebook}} = socket
      )
      when not is_nil(piece) and not is_nil(notebook) do
    if notebook_contains?(notebook, piece.id) do
      permanently_delete_list(socket, piece, notebook)
    else
      {:noreply, assign(socket, :delete_list, nil)}
    end
  end

  def handle_event("confirm_delete_list", _, socket), do: {:noreply, socket}

  defp update_section(socket, action) do
    case socket.assigns.notebook && action.(socket.assigns.notebook) do
      {:ok, _} ->
        {:noreply, socket |> assign(:notebook, Writing.notebook(socket.assigns.notebook.key))}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}

      _ ->
        {:noreply, socket}
    end
  end

  defp permanently_delete_list(socket, piece, notebook) do
    case Poems.permanently_delete(Storage.collection_location(), piece, true) do
      :ok ->
        {:noreply,
         socket
         |> assign(:delete_list, nil)
         |> put_flash(:info, "List permanently deleted.")
         |> push_patch(to: ~p"/notebooks?notebook=#{notebook.key}")}

      {:error, message} ->
        {:noreply, socket |> assign(:delete_list, nil) |> put_flash(:error, message)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    Writing.with_collection_snapshot(fn -> load_notebook(params, socket) end)
  end

  defp load_notebook(params, socket) do
    key = Map.get(params, "notebook")
    notebook = if key, do: Writing.notebook(key)

    selected_id =
      with value when is_binary(value) <- Map.get(params, "at"),
           {id, ""} <- Integer.parse(value),
           true <- not is_nil(notebook),
           true <- Enum.any?(notebook.entries, &(&1.id == id)) do
        id
      else
        _ -> nil
      end

    bookmark = if notebook, do: ReadingPlace.for_notebook(notebook.key)

    {:noreply,
     socket
     |> assign(:notebooks, Writing.notebooks())
     |> assign(:problem, Still.Writing.Discovery.problem())
     |> assign(:notebook, notebook)
     |> assign(:missing, not is_nil(key) && is_nil(notebook))
     |> assign(:selected_id, selected_id)
     |> assign(:delete_list, nil)
     |> assign(:reading_bookmark, bookmark)
     |> assign(:page_title, if(notebook, do: notebook.label, else: "Notebooks"))
     |> assign(:place, if(notebook, do: notebook.place, else: Writing.geography(nil)))}
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
      <div class="notebook-room">
        <p :if={@problem} class="recovery-note" role="alert">{@problem}</p>
        <div :if={is_nil(@notebook)} class="notebook-heading">
          <span class="section-whisper">A place for each List</span>
          <h1>Notebooks.</h1>
        </div>

        <p :if={@missing} class="notebook-empty">That notebook isn't here.</p>
        <.link :if={@missing} patch={~p"/notebooks"} class="quiet-link">All notebooks</.link>

        <p :if={!@missing && @notebooks == []} class="notebook-empty">
          Your notebooks will appear here.
        </p>

        <div :if={is_nil(@notebook) && !@missing} id="notebook-catalog">
          <section
            :for={{region, label} <- regions()}
            :if={Enum.any?(@notebooks, &(&1.region == region))}
            class="notebook-region"
            aria-label={label}
          >
            <h2 class="section-whisper">{label}</h2>
            <ul class="notebook-names">
              <li :for={notebook <- Enum.filter(@notebooks, &(&1.region == region))}>
                <.link
                  patch={~p"/notebooks?notebook=#{notebook.key}"}
                  class="notebook-name"
                >
                  <span>{notebook.label}</span>
                  <span class="notebook-count">{notebook.count} {if notebook.count == 1,
                    do: "List",
                    else: "Lists"}</span>
                </.link>
              </li>
            </ul>
          </section>
          <section class="notebook-region" aria-label="Add a notebook">
            <h2 class="section-whisper">Add a notebook</h2>
            <.form
              for={@notebook_form}
              id="new-notebook"
              phx-submit="create_notebook"
              class="still-form-panel"
            >
              <label>Notebook name
              <input name="notebook[label]" required maxlength="200" placeholder="Notebook 2" /></label>
              <details class="still-form-options">
                <summary>Folder and notebook details</summary>
                <div class="still-form-grid">
                  <label class="still-field-wide">
                    Folder inside your writing folder
                    <input
                      name="notebook[relative_path]"
                      maxlength="1024"
                      placeholder="Uses the notebook name by default"
                    />
                  </label>
                  <label class="still-field-wide">Original notebook label
                  <input name="notebook[key]" maxlength="1024" /></label>
                  <label class="still-field-wide">
                    <input type="hidden" name="notebook[numbered]" value="false" />
                    <input type="checkbox" name="notebook[numbered]" value="true" checked />
                    Number new Lists automatically
                    <span>Turn off for a collection of poems or other writing without notebook numbers.</span>
                  </label>
                  <label>Series <input name="notebook[series]" maxlength="200" /></label>
                  <label>Year <input name="notebook[year]" type="number" min="1" max="9999" /></label>
                  <label>Number as written <input name="notebook[number_label]" maxlength="100" /></label>
                  <label>Pen <input name="notebook[pen]" maxlength="500" /></label>
                  <label class="still-field-wide">Description <textarea
                    name="notebook[description]"
                    rows="2"
                  ></textarea></label>
                </div>
              </details>
              <button class="still-form-action" type="submit">Add notebook</button>
              <p :if={@notebook_form.source.action} role="alert">
                That notebook could not be added. Check the details and use a distinct name or original label.
              </p>
            </.form>
            <form phx-submit="choose_current" class="still-form-panel still-form-inline">
              <label>
                Current notebook
                <select name="id">
                  <option value="">None selected</option>
                  <option
                    :for={item <- Enum.filter(@notebooks, &Map.get(&1, :managed, false))}
                    value={item.id}
                    selected={item.current}
                  >
                    {item.label}
                  </option>
                </select>
              </label>
              <button class="still-form-action" type="submit">Choose</button>
            </form>
          </section>
        </div>

        <div :if={@notebook} id="notebook-index">
          <.link patch={~p"/notebooks"} class="quiet-link notebook-back">All notebooks</.link>
          <.link
            :if={@reading_bookmark}
            navigate={
              ReadingLinks.reader(@reading_bookmark.entry, %{
                "from" => "notebook",
                "notebook" => @notebook.key,
                "version" => @reading_bookmark.context["version"]
              })
            }
            id="continue-reading"
            class="quiet-link"
          >Continue reading</.link>
          <header class="notebook-heading">
            <span class="section-whisper">{region_label(@notebook.region)}</span>
            <h1>{@notebook.label}</h1>
            <p class="notebook-order">
              {cond do
                Map.get(@notebook, :numbered, true) == false ->
                  "By filename within each section, without notebook numbers."

                length(@notebook.sections) == 1 ->
                  "In source order, from beginning to end."

                true ->
                  "Each source section keeps its own order."
              end}
            </p>
          </header>

          <section
            :for={{section, index} <- Enum.with_index(@notebook.sections)}
            id={"notebook-section-#{index}"}
            class="notebook-section"
            aria-label={section.label}
          >
            <div class="notebook-section-heading">
              <div>
                <h2>{section.label}</h2>
                <p
                  :if={
                    Map.get(@notebook, :managed, false) &&
                      section.key == Map.get(@notebook, :current_section)
                  }
                  class="section-whisper"
                >
                  New Lists go here
                </p>
                <details class="notebook-section-details">
                  <summary>Section details</summary>
                  <form
                    phx-submit="rename_section"
                    id={"rename-section-#{index}"}
                    class="still-form-panel"
                  >
                    <input type="hidden" name="section" value={section.key} />
                    <label>
                      Section name
                      <input name="label" value={section.label} required maxlength="200" />
                    </label>
                    <button type="submit" class="quiet-link">Save name</button>
                  </form>
                  <button
                    :if={Map.get(@notebook, :managed, false)}
                    type="button"
                    phx-click="choose_section"
                    phx-value-section={section.key}
                    class="quiet-link"
                  >New Lists here</button>
                </details>
              </div>
              <nav class="notebook-ends" aria-label={"Move through #{section.label}"}>
                <a href={"#section-#{index}-beginning"}>Beginning</a>
                <span aria-hidden="true">·</span>
                <a href={"#section-#{index}-end"}>End</a>
              </nav>
            </div>
            <div id={"section-#{index}-beginning"} class="notebook-boundary">
              <span class="section-whisper">Beginning</span>
            </div>
            <ol class="notebook-list">
              <li
                :for={entry <- section.entries}
                id={"list-#{entry.id}"}
                class={if(@selected_id == entry.id, do: "notebook-current")}
              >
                <span :if={entry.list_label not in [nil, ""]} class="notebook-list-number">
                  {entry.list_label}
                </span>
                <.link
                  navigate={
                    ReadingLinks.reader(entry, %{"from" => "notebook", "notebook" => @notebook.key})
                  }
                  class="notebook-list-link"
                  aria-current={if(@selected_id == entry.id, do: "location")}
                  phx-mounted={if @selected_id == entry.id, do: JS.focus(to: "#list-#{entry.id} a")}
                ><.list_title text={Writing.opening(entry)} /></.link>
                <nav
                  class="notebook-list-actions"
                  aria-label={"Actions for #{Writing.opening(entry)}"}
                >
                  <.link
                    navigate={
                      ReadingLinks.reader(entry, %{"from" => "notebook", "notebook" => @notebook.key})
                    }
                    class="quiet-link"
                  >Read</.link>
                  <.link navigate={ReadingLinks.wander(entry)} class="quiet-link">Wander</.link>
                  <button
                    :if={entry.file_id}
                    id={"delete-list-#{entry.file_id}"}
                    type="button"
                    phx-click="request_delete_list"
                    phx-value-id={entry.file_id}
                    class="quiet-link"
                    aria-label={"Delete #{Writing.opening(entry)}"}
                  >Delete</button>
                </nav>
                <div
                  :if={@delete_list && @delete_list.id == entry.file_id}
                  id="delete-list-confirmation"
                  role="alertdialog"
                  aria-label="Permanently delete List?"
                  aria-describedby="delete-list-confirmation-description"
                  phx-mounted={JS.focus(to: "#cancel-delete-list")}
                >
                  <p id="delete-list-confirmation-description">
                    Permanently remove <strong>{Poems.display_title(@delete_list)}</strong>
                    and its file and earlier words?
                    Submitted correspondence keeps its exact submitted text.
                  </p>
                  <button type="button" phx-click="confirm_delete_list" class="quiet-link">Permanently delete</button>
                  <button
                    id="cancel-delete-list"
                    type="button"
                    phx-click={
                      JS.push("cancel_delete_list") |> JS.focus(to: "#delete-list-#{@delete_list.id}")
                    }
                    class="quiet-link"
                  >Cancel</button>
                </div>
              </li>
            </ol>
            <div id={"section-#{index}-end"} class="notebook-boundary notebook-end">
              <span class="section-whisper">End</span>
              <a href={"#section-#{index}-beginning"} class="quiet-link">Back to the beginning</a>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp regions,
    do: [early: "Early notebooks", current: "Current notebooks", elsewhere: "Other notebooks"]

  defp region_label(region), do: Keyword.fetch!(regions(), region)

  defp notebook_contains?(%{entries: entries}, id),
    do: Enum.any?(entries, &(&1.file_id == id))

  defp notebook_contains?(_, _), do: false
end
