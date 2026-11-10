defmodule StillWeb.Router do
  use StillWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {StillWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", StillWeb do
    pipe_through :browser

    live_session :room, on_mount: [{StillWeb.Room, :default}] do
      live "/", WritingLive, :now
      live "/list", WritingLive, :new
      live "/w/:id", EntryLive, :show
      live "/read/:id", EntryLive, :read
      live "/before", EntryLive, :before
      live "/wander", EntryLive, :wander
      live "/threads", ThreadsLive, :index
      live "/pages", ArchiveLive, :index
      live "/notebooks", NotebookLive, :index
      live "/notebooks/read/:id", NotebookReadingLive, :read
      live "/storage", StorageLive, :index
      live "/correspondence", CorrespondenceLive, :home
      live "/correspondence/writing", CorrespondenceLive, :collection
      live "/correspondence/writing/:id", CorrespondenceLive, :piece
      live "/correspondence/journals", CorrespondenceLive, :journals
      live "/correspondence/journals/new", CorrespondenceLive, :new_journal
      live "/correspondence/journals/import", CorrespondenceLive, :import_journals
      live "/correspondence/journals/:id", CorrespondenceLive, :journal
      live "/correspondence/packets", CorrespondenceLive, :packets
      live "/correspondence/packets/new", CorrespondenceLive, :new_packet
      live "/correspondence/packets/:id", CorrespondenceLive, :packet
      live "/writing", SavedLive, :index
      live "/writing/new", WritingLive, :new
      live "/writing/:id/edit", WritingLive, :edit
      live "/writing/:id", WritingLive, :show
      live "/poems", SavedLive, :index
      live "/poems/new", WritingLive, :new
      live "/poems/:id/edit", WritingLive, :edit
      live "/poems/:id", WritingLive, :show
    end

    get "/correspondence/packets/:id/export/:format", ManuscriptController, :show
    get "/healthz", HealthController, :index
  end

  scope "/native", StillWeb do
    pipe_through :api

    get "/storage", NativeStorageController, :show
    put "/storage", NativeStorageController, :update
    delete "/storage", NativeStorageController, :delete
    post "/backup", NativeStorageController, :backup
    post "/exports/pdf", NativeStorageController, :export_pdf
    post "/exports/pdf/input", NativeStorageController, :pdf_input
  end
end
