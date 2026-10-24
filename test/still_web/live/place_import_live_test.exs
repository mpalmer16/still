defmodule StillWeb.PlaceImportLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Correspondence, Storage}

  @moduletag :tmp_dir
  setup %{tmp_dir: root} do
    old = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    collection = Path.join(root, "collection")
    File.mkdir_p!(collection)
    {:ok, _} = Storage.set_folder(collection)
    on_exit(fn -> Application.put_env(:still, :storage_state_directory, old) end)
    %{location: Storage.collection_location(), collection: collection}
  end

  test "Places links to upload; review writes nothing and confirmation adds only new names", %{
    conn: conn,
    location: location
  } do
    {:ok, old} = Correspondence.save_journal(location, %{name: "Existing"})
    {:ok, view, _} = live(conn, ~p"/correspondence/journals")
    render_click(element(view, "a", "Import Places"))
    assert_patch(view, ~p"/correspondence/journals/import")
    assert has_element?(view, "pre code", "Example Poetry Review")
    assert has_element?(view, "nav a.active", "Places")
    review(view, ~s([{"name":"New","notes":"<script>not markup</script>"},{"name":"existing"}]))
    assert has_element?(view, "#places-import-preview", "1 to add · 1 skipped")
    assert {:ok, [^old]} = Correspondence.journals(location)
    render_click(element(view, "#confirm-places-import"))
    assert has_element?(view, "#places-import-result", "Added 1 place. Skipped 1.")
    refute has_element?(view, "#confirm-places-import")
    assert {:ok, journals} = Correspondence.journals(location)
    assert length(journals) == 2
    new = Enum.find(journals, &(&1.name == "New"))
    refute new.verified
    {:ok, details, _} = live(conn, ~p"/correspondence/journals/#{new.id}")
    assert has_element?(details, "p", "<script>not markup</script>")
    refute has_element?(details, "script", "not markup")
  end

  test "invalid next upload clears an earlier preview, and missing selection never imports", %{
    conn: conn,
    location: location
  } do
    {:ok, view, _} = live(conn, ~p"/correspondence/journals/import")
    review(view, ~s([{"name":"Valid"}]))
    assert has_element?(view, "#confirm-places-import")
    review(view, ~s([{"name":"Other"},{"name":"Bad","wrong_field":"no"}]))
    assert render(view) =~ "Place 2: Unsupported fields: wrong_field."
    refute has_element?(view, "#confirm-places-import")
    render_submit(element(view, "#places-import-form"))
    assert render(view) =~ "Choose one JSON file"
    assert {:ok, []} = Correspondence.journals(location)
  end

  test "collection disappearing after preview reports failure and does not add elsewhere", %{
    conn: conn,
    collection: folder
  } do
    {:ok, view, _} = live(conn, ~p"/correspondence/journals/import")
    review(view, ~s([{"name":"Later"}]))
    File.rename!(folder, folder <> "-offline")
    render_click(element(view, "#confirm-places-import"))
    assert has_element?(view, "#places-import-result", "Added 0 places.")
    assert has_element?(view, "#places-import-result [role=alert]", "Could not add Later")
    refute has_element?(view, "#confirm-places-import")
    refute File.exists?(folder)
  end

  test "import without a configured collection guides setup and provides no upload", %{conn: conn} do
    {:ok, _} = Storage.clear_folder()
    {:ok, view, _} = live(conn, ~p"/correspondence/journals/import")
    assert render(view) =~ "Storage"
    refute has_element?(view, "#places-import-form")
  end

  test "deactivated places leave active choices, preserve details across edits and reopen, and reactivate",
       %{conn: conn, location: location} do
    {:ok, place} =
      Correspondence.save_journal(location, %{name: "Synthetic Place", shortlisted: true})

    {:ok, view, _} = live(conn, ~p"/correspondence/journals/#{place.id}")
    render_click(element(view, "#toggle-place-active"))
    assert has_element?(view, "#toggle-place-active", "Reactivate place")
    refute has_element?(view, "a", "Prepare a packet")
    # Optional empty addresses must remain editable after a names-only import.
    render_submit(element(view, "#journal-form"), %{
      "journal" => %{
        "name" => "Synthetic Place",
        "website" => "",
        "submission_url" => "",
        "notes" => "Kept while inactive"
      }
    })

    assert {:ok, inactive} = Correspondence.journal(location, place.id)
    assert inactive.inactive
    assert inactive.notes == "Kept while inactive"
    {:ok, directory, _} = live(conn, ~p"/correspondence/journals")
    assert has_element?(directory, "#inactive-places a", "Synthetic Place")
    refute has_element?(directory, ".editorial-place-card", "Synthetic Place")
    {:ok, home, _} = live(conn, ~p"/correspondence")
    refute has_element?(home, ".editorial-home-place", "Synthetic Place")
    {:ok, packet, _} = live(conn, ~p"/correspondence/packets/new")
    refute has_element?(packet, "option[value='#{place.id}']")
    {:ok, reopened, _} = live(conn, ~p"/correspondence/journals/#{place.id}")
    assert has_element?(reopened, "#toggle-place-active", "Reactivate place")
    render_click(element(reopened, "#toggle-place-active"))
    assert has_element?(reopened, "#toggle-place-active", "Deactivate place")
    {:ok, directory, _} = live(conn, ~p"/correspondence/journals")
    assert has_element?(directory, ".editorial-place-card", "Synthetic Place")
    refute has_element?(directory, "#inactive-places")
  end

  defp review(view, json) do
    upload =
      file_input(view, "#places-import-form", :places, [
        %{name: "places.json", content: json, type: "application/json"}
      ])

    render_upload(upload, "places.json")
    render_submit(element(view, "#places-import-form"))
  end
end
