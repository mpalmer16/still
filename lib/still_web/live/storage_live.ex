defmodule StillWeb.StorageLive do
  use StillWeb, :live_view

  alias Still.Storage

  @impl true
  def mount(_params, _session, socket) do
    status = Storage.status()

    {:ok,
     assign(socket,
       page_title: "Storage & Backups",
       storage: status,
       folder: status.folder || "",
       notice: nil,
       problem: nil
     )}
  end

  @impl true
  def handle_event("set_folder", %{"storage" => %{"folder" => folder}}, socket) do
    result(socket, Storage.set_folder(folder), "Backup folder saved.")
  end

  def handle_event("clear_folder", _, socket),
    do:
      result(
        socket,
        Storage.clear_folder(),
        "Backup folder cleared. Your database stays where it is."
      )

  def handle_event("backup", _, socket),
    do:
      result(
        socket,
        Storage.backup(),
        "Backup completed on this computer. Cloud synchronization has not been confirmed."
      )

  def handle_event("refresh", _, socket),
    do: {:noreply, assign(socket, storage: Storage.status(), notice: nil, problem: nil)}

  def handle_event("open_folder", _, socket) do
    case Storage.open_folder() do
      :ok ->
        {:noreply,
         assign(socket,
           notice: "Opened the backup folder on the computer running Still.",
           problem: nil
         )}

      {:error, message} ->
        {:noreply, assign(socket, problem: message, notice: nil)}
    end
  end

  defp result(socket, {:ok, status}, notice) do
    {:noreply,
     assign(socket, storage: status, folder: status.folder || "", notice: notice, problem: nil)}
  end

  defp result(socket, {:error, message}, _) do
    {:noreply, assign(socket, storage: Storage.status(), problem: message, notice: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active="storage"
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
      <div class="storage-room">
        <h1>Storage &amp; Backups.</h1>
        <p>
          Your writing database stays in its current location. A backup is a separate, complete copy.
        </p>
        <p>
          Choose any local folder, including one synchronized by a service you use. Still does not contact that service.
        </p>
        <p>
          Poems use a <code>poems/</code>
          directory inside this chosen folder. Changing or clearing the folder changes which poem collection opens; existing poem files stay where they are. Database backups contain SQLite writing only. <.link navigate={
            ~p"/poems"
          }>Open Poems</.link>.
        </p>
        <p :if={@notice} id="storage-notice" role="status">{@notice}</p>
        <p :if={@problem} id="storage-problem" role="alert">{@problem}</p>
        <p :if={@storage.error && @storage.error != @problem} id="storage-guidance" role="alert">
          {@storage.error}
        </p>

        <section aria-labelledby="backup-folder-heading">
          <h2 id="backup-folder-heading">Backup folder</h2>
          <p :if={!@storage.configured} id="no-backup-folder">
            No backup folder is configured. You can keep writing normally.
          </p>
          <p :if={@storage.configured}>
            Current folder: <code id="backup-folder-path">{@storage.folder}</code>
          </p>
          <p>
            In the Mac app, use File → Choose Backup Folder…. In a browser, enter an absolute folder path on the computer running Still.
          </p>
          <.form for={%{}} as={:storage} id="backup-folder-form" phx-submit="set_folder">
            <label for="backup-folder">Local folder</label>
            <input
              id="backup-folder"
              type="text"
              name="storage[folder]"
              value={@folder}
              autocomplete="off"
              spellcheck="false"
              required
            />
            <button type="submit">Use This Folder</button>
          </.form>
          <div class="storage-actions">
            <button :if={@storage.configured} id="clear-backup-folder" phx-click="clear_folder">Clear Folder</button>
            <button :if={@storage.configured} id="open-backup-folder" phx-click="open_folder">Open Backup Folder</button>
          </div>
          <p>
            Changing or clearing this setting does not move or delete your database or earlier backups.
          </p>
        </section>

        <section aria-labelledby="backup-heading">
          <h2 id="backup-heading">Database backup</h2>
          <div id="last-backup">
            <p :if={is_nil(@storage.last_backup)}>
              No successful backup is recorded for this folder.
            </p>
            <div :if={@storage.last_backup}>
              <p>Last successful backup: <time>{@storage.last_backup.at}</time></p>
              <p><code>{@storage.last_backup.path}</code></p>
            </div>
          </div>
          <p id="backup-freshness">
            {if @storage.changed,
              do: "The database has changes that are not in a verified backup.",
              else: "The database matches the last verified backup."}
          </p>
          <div class="storage-actions">
            <button
              id="backup-now"
              phx-click="backup"
              phx-disable-with="Backing up…"
              disabled={!@storage.configured}
            >Back Up Now</button>
            <button id="refresh-backup-status" phx-click="refresh">Refresh Status</button>
          </div>
          <p>
            A completed backup is confirmed locally. Check your synchronization service separately before relying on a cloud copy.
          </p>
          <p>
            Backups contain all saved writing, revisions, provenance, and reading state. Unsent recovery copies stay in the browser or Mac app until saved.
          </p>
        </section>
        <.link navigate={~p"/pages"} class="quiet-link">Return to Find</.link>
      </div>
    </Layouts.app>
    """
  end
end
