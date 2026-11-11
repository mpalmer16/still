defmodule StillWeb.ArchiveLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Repo, Storage, Writing}
  alias Still.Writing.CollectionLock

  test "pages can be found by a phrase and opened", %{conn: conn} do
    {:ok, matched} = Writing.save_entry(nil, "An imaginary quartet played in the cellar")
    {:ok, _} = Writing.save_entry(nil, "The garden was quiet")

    {:ok, view, html} = live(conn, ~p"/pages")
    assert html =~ "imaginary quartet"
    assert html =~ "garden"

    render_change(element(view, "#search-form"), %{"search" => %{"query" => "quartet"}})
    assert_patch(view, ~p"/pages?q=quartet")
    assert has_element?(view, ".entry-row", "imaginary quartet")
    refute render(view) =~ "garden"

    assert has_element?(
             view,
             "a[href^='/read/#{matched.id}?'][href*='q=quartet'][href$='#passage-1']"
           )
  end

  test "Find shows notebook provenance for current and earlier matches, with a fallback", %{
    conn: conn
  } do
    notebook = "Early Notebooks/Lists 3"

    entry =
      %Still.Writing.Entry{}
      |> Still.Writing.Entry.changeset(%{
        origin: "before",
        title: "Synthetic notebook piece",
        body: "A cobalt lantern",
        notebook: notebook,
        source_key: Ecto.UUID.generate(),
        source: %{"artifacts" => [%{"path" => "Early Notebooks/Lists 3/14. Synthetic.doc"}]}
      })
      |> Still.Repo.insert!()

    %Still.Writing.Entry{}
    |> Still.Writing.Entry.changeset(%{
      origin: "before",
      title: "Unplaced synthetic piece",
      body: "Another cobalt lantern",
      source_key: Ecto.UUID.generate()
    })
    |> Still.Repo.insert!()

    {:ok, found, _} = live(conn, ~p"/pages?q=cobalt")

    assert has_element?(
             found,
             ".entry-row[href^='/notebooks/read/#{entry.id}?'][href*='from=find'] .entry-notebook",
             "Early/Notebook 3, No. 14"
           )

    assert has_element?(found, ".entry-date", "from before")

    {:ok, current} = Writing.save_entry(entry, "A different brass lamp", checkpoint: true)
    [version] = Writing.list_versions(current)
    {:ok, earlier, _} = live(conn, ~p"/pages?q=cobalt&earlier=1")

    assert has_element?(
             earlier,
             ".entry-row[href^='/notebooks/read/#{entry.id}?'][href*='from=find'][href*='version=#{version.id}'] .entry-notebook",
             "Early/Notebook 3, No. 14"
           )

    assert has_element?(
             earlier,
             ".entry-row[href^='/notebooks/read/#{entry.id}?'][href*='from=find'][href*='version=#{version.id}'] .earlier-label",
             "Earlier words"
           )
  end

  @tag :tmp_dir
  test "Find reports collection lock errors, then retries the same search", %{
    conn: conn,
    tmp_dir: root
  } do
    folder = Path.join(root, "writing")
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "quartet.md"), "An imaginary quartet played in the cellar.")
    assert {:ok, _} = Storage.set_folder(folder)

    parent = self()

    owner =
      spawn(fn ->
        result =
          CollectionLock.with_lock(Repo.config()[:database], fn ->
            send(parent, :collection_lock_held)

            receive do
              :release -> :released
            end
          end)

        send(parent, {:collection_lock_released, result})
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    assert_receive :collection_lock_held

    {:ok, view, _html} = live(conn, ~p"/pages?q=quartet")

    assert has_element?(view, "#search-collection-problem[role=alert]", "Try again")
    assert has_element?(view, "#search-collection-problem", "updating this collection")
    refute has_element?(view, ".entry-row")
    refute has_element?(view, ".archive-empty")
    refute has_element?(view, "#search-status", "No matches.")

    send(owner, :release)
    assert_receive {:collection_lock_released, :released}

    view |> element("#search-collection-problem button") |> render_click()

    assert has_element?(view, ".entry-row", "imaginary quartet")
    refute has_element?(view, "#search-collection-problem")
  end
end
