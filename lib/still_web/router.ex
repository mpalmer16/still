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
      live "/", EntryLive, :new
      live "/list", EntryLive, :list
      live "/w/:id", EntryLive, :show
      live "/before", EntryLive, :before
      live "/wander", EntryLive, :wander
      live "/pages", ArchiveLive, :index
      live "/notebooks", NotebookLive, :index
      live "/storage", StorageLive, :index
    end

    get "/healthz", HealthController, :index
  end

  scope "/native", StillWeb do
    pipe_through :api

    get "/storage", NativeStorageController, :show
    put "/storage", NativeStorageController, :update
    delete "/storage", NativeStorageController, :delete
    post "/backup", NativeStorageController, :backup
  end
end
