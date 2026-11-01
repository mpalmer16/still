defmodule Still.Correspondence.PlaceIconsTest do
  use ExUnit.Case, async: false
  alias Still.{Correspondence, Storage}
  alias Still.Correspondence.{Icons, IconFetcher, PlaceImport}

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
       )
  @moduletag :tmp_dir
  setup %{tmp_dir: root} do
    old = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "collection")
    File.mkdir_p!(folder)
    {:ok, _} = Storage.set_folder(folder)
    on_exit(fn -> Application.put_env(:still, :storage_state_directory, old) end)
    %{location: Storage.collection_location(), folder: folder, root: root}
  end

  test "import adds descriptions and icon URLs without fetching; old records keep their bytes", %{
    location: location,
    folder: folder
  } do
    assert {:ok, plan} =
             PlaceImport.preview(
               location,
               Jason.encode!([
                 %{
                   name: "Synthetic",
                   website: "https://review.example",
                   icon_url: "https://images.example/mark.png",
                   description: "A small independent journal."
                 }
               ])
             )

    refute File.exists?(Path.join(folder, "correspondence"))
    assert %{imported: ["Synthetic"], error: nil} = PlaceImport.commit(plan)
    {:ok, [journal]} = Correspondence.journals(location)
    assert journal.description == "A small independent journal."
    assert journal.icon_url == "https://images.example/mark.png"

    {:ok, edited} =
      Correspondence.save_journal(
        location,
        %{name: journal.name, website: journal.website},
        journal.id,
        journal.token
      )

    assert edited.description == journal.description
    assert edited.icon_url == journal.icon_url

    assert {:error, _} =
             Correspondence.save_journal(
               location,
               %{name: "Stale", description: "Lost"},
               journal.id,
               journal.token
             )

    path = Path.join([folder, "correspondence", "journals", journal.id <> ".json"])

    bytes =
      File.read!(path) |> Jason.decode!() |> Map.drop(~w(description icon_url)) |> Jason.encode!()

    File.write!(path, bytes)
    assert {:ok, legacy} = Correspondence.journal(location, journal.id)
    assert legacy.description == nil
    assert legacy.icon_url == nil
    assert File.read!(path) == bytes
    assert Icons.candidates(legacy) == ["https://review.example/favicon.ico"]

    for attrs <- [
          %{icon_url: "file:///private/image"},
          %{icon_url: "data:image/png;base64,no"},
          %{description: []}
        ] do
      assert {:error, _} =
               PlaceImport.preview(location, Jason.encode!([Map.put(attrs, :name, "Invalid")]))
    end
  end

  test "icons download once, fall back to favicon, and travel with the collection without changing journals",
       %{location: location, folder: folder, root: root} do
    {:ok, journal} =
      Correspondence.save_journal(location, %{
        name: "Synthetic",
        icon_url: "https://review.example/logo.png",
        website: "https://review.example/about"
      })

    path = Path.join([folder, "correspondence", "journals", journal.id <> ".json"])
    before = File.read!(path)
    parent = self()

    fetcher = fn url ->
      send(parent, {:fetch, url})

      if String.ends_with?(url, "favicon.ico"),
        do: {:ok, %{bytes: @png}},
        else: {:error, :offline}
    end

    assert "data:image/png;base64," <> _ = uri = Icons.ensure(location, journal, fetcher)
    assert_received {:fetch, "https://review.example/logo.png"}
    assert_received {:fetch, "https://review.example/favicon.ico"}
    assert Icons.ensure(location, journal, fn _ -> flunk("must use local copy") end) == uri
    assert File.read!(path) == before
    assert {:ok, ^journal} = Correspondence.journal(location, journal.id)
    # A whole-collection copy includes the verified image without any network access.
    copy = Path.join(root, "copied")
    {:ok, _} = File.cp_r(folder, copy)
    {:ok, _} = Storage.set_folder(copy)
    copied_location = Storage.collection_location()
    {:ok, copied} = Correspondence.journal(copied_location, journal.id)

    assert Icons.ensure(copied_location, copied, fn _ -> flunk("copied cache must be offline") end) ==
             uri
  end

  test "offline and unsafe images are optional, retry later, and URL changes invalidate the cache",
       %{location: location, folder: folder} do
    {:ok, journal} =
      Correspondence.save_journal(location, %{
        name: "Synthetic",
        website: "https://review.example"
      })

    assert Icons.ensure(location, journal, fn _ -> {:ok, %{bytes: "<svg onload='bad'/>"}} end) ==
             nil

    assert Icons.cached(location, journal) == :unavailable

    assert Icons.ensure(location, journal, fn _ -> flunk("no repeated failed downloads") end) ==
             nil

    {:ok, edited} =
      Correspondence.save_journal(
        location,
        %{name: journal.name, icon_url: "https://review.example/new.png"},
        journal.id,
        journal.token
      )

    assert Icons.cached(location, edited) == :missing
    assert Icons.ensure(location, edited, fn _ -> {:ok, %{bytes: @png}} end)
    # Tampering fails the content hash rather than displaying changed bytes.
    [cache_path] =
      Path.wildcard(Path.join([folder, "correspondence", "icons", "*.json"]))
      |> Enum.filter(fn path -> Map.has_key?(Jason.decode!(File.read!(path)), "data") end)

    cache = Jason.decode!(File.read!(cache_path)) |> Map.put("sha256", "wrong")
    File.write!(cache_path, Jason.encode!(cache))
    assert Icons.cached(location, edited) == :missing
    assert {:error, _} = IconFetcher.raster(String.duplicate("x", 262_145))
    assert {:error, _} = IconFetcher.raster("<html>error</html>")
  end

  test "an offline first visit can recover on a later visit", %{location: location} do
    {:ok, journal} =
      Correspondence.save_journal(location, %{
        name: "Offline Review",
        website: "https://review.example"
      })

    assert Icons.ensure(location, journal, fn _ -> {:error, :offline} end) == nil

    assert :ok =
             Correspondence.write_icon_cache(location, journal, %{
               "retry_after" => System.system_time(:second) - 1
             })

    assert "data:image/png;base64," <> _ =
             Icons.ensure(location, journal, fn _ -> {:ok, %{bytes: @png}} end)

    {:ok, blank} = Correspondence.save_journal(location, %{name: "No website"})

    assert Icons.ensure(location, blank, fn _ -> flunk("names-only place must stay local") end) ==
             nil

    assert Icons.cached(location, blank) == :missing
  end

  test "late downloads cannot write after a source or collection changes, and symlinks are refused",
       %{location: location, folder: folder, root: root} do
    {:ok, journal} =
      Correspondence.save_journal(location, %{
        name: "Synthetic",
        website: "https://review.example"
      })

    changed = fn _ ->
      {:ok, _} =
        Correspondence.save_journal(
          location,
          %{name: journal.name, website: "https://other.example"},
          journal.id,
          journal.token
        )

      {:ok, %{bytes: @png}}
    end

    assert Icons.ensure(location, journal, changed) == nil
    refute File.exists?(Path.join([folder, "correspondence", "icons"]))
    {:ok, current} = Correspondence.journal(location, journal.id)
    elsewhere = Path.join(root, "elsewhere")
    File.mkdir_p!(elsewhere)

    switch = fn _ ->
      {:ok, _} = Storage.set_folder(elsewhere)
      {:ok, %{bytes: @png}}
    end

    assert Icons.ensure(location, current, switch) == nil
    assert File.ls!(elsewhere) == []
    {:ok, _} = Storage.set_folder(folder)
    current_location = Storage.collection_location()
    File.ln_s!(elsewhere, Path.join([folder, "correspondence", "icons"]))
    assert Icons.ensure(current_location, current, fn _ -> {:ok, %{bytes: @png}} end) == nil
    assert File.ls!(elsewhere) == []
    assert {:ok, _} = Correspondence.journal(current_location, journal.id)
  end

  test "fetches only pinned public addresses, including redirects, and treats URL text as data" do
    parent = self()

    request = fn url, address ->
      send(parent, {:requested, url, address})
      {:ok, %{status: 302, headers: %{"location" => "http://127.0.0.1/private"}, body: ""}}
    end

    resolver = fn
      "review.example" -> {:ok, {93, 184, 216, 34}}
      _ -> {:ok, {127, 0, 0, 1}}
    end

    assert {:error, _} =
             IconFetcher.fetch("https://review.example/icon",
               resolver: resolver,
               request: request
             )

    assert_received {:requested, "https://review.example/icon", {93, 184, 216, 34}}
    refute_received {:requested, "http://127.0.0.1/private", _}

    for url <- [
          "file:///tmp/logo",
          "http://user:secret@review.example/icon",
          "http://review.example:4000/icon",
          "http://127.0.0.1/icon"
        ] do
      assert {:error, _} =
               IconFetcher.fetch(url,
                 resolver: resolver,
                 request: fn _, _ -> flunk("unsafe request") end
               )
    end

    for ip <- [
          {10, 1, 2, 3},
          {169, 254, 169, 254},
          {192, 168, 1, 1},
          {172, 16, 0, 1},
          {0, 0, 0, 0},
          {100, 64, 0, 1},
          {0, 0, 0, 0, 0, 0, 0, 1}
        ] do
      refute IconFetcher.public_address?(ip)
    end

    assert {:ok, %{mime: "image/png", bytes: @png}} =
             IconFetcher.fetch("https://review.example/icon",
               resolver: resolver,
               request: fn _, {93, 184, 216, 34} ->
                 {:ok, %{status: 200, headers: %{}, body: @png}}
               end
             )
  end
end
