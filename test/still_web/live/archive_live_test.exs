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
end
