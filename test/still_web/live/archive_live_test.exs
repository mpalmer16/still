defmodule StillWeb.ArchiveLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.Writing

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
             "a[href^='/w/#{matched.id}?'][href*='q=quartet'][href$='#passage-1']"
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
             ".entry-row[href^='/w/#{entry.id}?'] .entry-notebook",
             "Early Notebooks · Lists 3 · source 14"
           )

    assert has_element?(found, ".entry-date", "from before")

    {:ok, current} = Writing.save_entry(entry, "A different brass lamp", checkpoint: true)
    [version] = Writing.list_versions(current)
    {:ok, earlier, _} = live(conn, ~p"/pages?q=cobalt&earlier=1")

    assert has_element?(
             earlier,
             ".entry-row[href*='version=#{version.id}'] .entry-notebook",
             "Early Notebooks · Lists 3 · source 14"
           )

    assert has_element?(
             earlier,
             ".entry-row[href*='version=#{version.id}'] .earlier-label",
             "Earlier words"
           )
  end
end
