defmodule StillWeb.PoemsLive do
  use StillWeb, :live_view
  alias Still.{Poems, Storage}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket)}
  end

  @impl true
  def handle_event("refresh_poems", _, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    location = Storage.collection_location()
    result = if location.available, do: Poems.list(location), else: {:ok, []}

    {poems, problem} =
      case result do
        {:ok, poems} -> {poems, location.error}
        {:error, message} -> {[], message}
      end

    assign(socket, page_title: "Poems", location: location, poems: poems, problem: problem)
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
      <div class="poetry-library">
        <header class="poetry-heading">
          <span class="section-whisper">A place for your poems</span>
          <h1>Poems.</h1>
          <.link id="new-poem" navigate={~p"/poems/new"} class="poetry-link">A blank page</.link>
        </header>
        <p :if={!@location.configured} id="poems-local-only" class="poetry-note">
          No collection folder is chosen. You can begin a local draft; choose a folder before saving a poem as a file. <.link navigate={
            ~p"/storage"
          }>Choose a folder in Storage &amp; Backups</.link>.
        </p>
        <p :if={@problem} id="poems-problem" role="alert" class="poetry-note">{@problem}</p>
        <div id="poem-shelf" class="poetry-shelf">
          <.link
            :for={poem <- @poems}
            id={"poem-#{poem.id}"}
            navigate={~p"/poems/#{poem.id}"}
            class="poetry-piece"
          >
            <span class="poetry-piece-title">{if poem.title in [nil, ""],
              do: "Untitled",
              else: poem.title}</span>
            <span class="poetry-opening">{opening(poem.body)}</span>
          </.link>
        </div>
        <p :if={@poems == [] && !@problem} id="poems-empty" class="poetry-empty">
          The page can begin whenever you are ready.
        </p>
        <footer class="poetry-collection-note">
          <details :if={@location.configured} id="poem-collection-location">
            <summary>Collection folder</summary>
            <p><code>{Path.join(@location.folder, "poems")}</code></p>
            <p>
              Poems are ordinary text files. This is the folder selected in Storage &amp; Backups.
            </p>
          </details>
          <p>A blank page also lets you return to a new poem’s local recovery copy.</p>
          <button id="refresh-poems" phx-click="refresh_poems" class="quiet-link">Refresh collection</button>
          <.link navigate={~p"/storage"} class="quiet-link">Storage &amp; Backups</.link>
        </footer>
      </div>
    </Layouts.app>
    """
  end

  defp opening(body), do: body |> String.split("\n") |> Enum.take(3) |> Enum.join("\n")
end
