defmodule StillWeb.NotebookLive do
  use StillWeb, :live_view

  alias Still.Writing

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:notebooks, Writing.notebooks())
     |> assign(:notebook, nil)
     |> assign(:missing, false)
     |> assign(:selected_id, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
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

    {:noreply,
     socket
     |> assign(:notebook, notebook)
     |> assign(:missing, not is_nil(key) && is_nil(notebook))
     |> assign(:selected_id, selected_id)
     |> assign(:page_title, if(notebook, do: notebook.label, else: "Notebooks"))
     |> assign(:place, if(notebook, do: notebook.place, else: Writing.geography(nil)))}
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
      <div class="notebook-room">
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
        </div>

        <div :if={@notebook} id="notebook-index">
          <.link patch={~p"/notebooks"} class="quiet-link notebook-back">All notebooks</.link>
          <header class="notebook-heading">
            <span class="section-whisper">{region_label(@notebook.region)}</span>
            <h1>{@notebook.label}</h1>
            <p class="notebook-order">
              {if length(@notebook.sections) == 1,
                do: "In source order, from beginning to end.",
                else: "Each source section keeps its own order."}
            </p>
          </header>

          <section
            :for={{section, index} <- Enum.with_index(@notebook.sections)}
            id={"notebook-section-#{index}"}
            class="notebook-section"
            aria-label={section.label}
          >
            <div class="notebook-section-heading">
              <h2 :if={length(@notebook.sections) > 1}>{section.label}</h2>
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
                <.link
                  navigate={~p"/w/#{entry.id}?read=1"}
                  class="notebook-list-link"
                  aria-current={if(@selected_id == entry.id, do: "location")}
                ><.list_title text={Writing.opening(entry)} /></.link>
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
end
