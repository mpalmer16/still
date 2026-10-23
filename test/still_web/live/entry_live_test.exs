defmodule StillWeb.EntryLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Repo, Writing}
  alias Still.Writing.Entry
  import Ecto.Query

  test "an empty arrival becomes a saved, revisitable page", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Begin anywhere."
    assert Writing.list_entries() == []

    render_change(element(view, "#writing-form"), %{
      "entry" => %{"body" => "A tiny passing thought"}
    })

    assert [%{body: "A tiny passing thought"} = entry] = Writing.list_entries()
    assert_patch(view, ~p"/w/#{entry.id}")

    {:ok, revisited, html} = live(conn, ~p"/w/#{entry.id}")
    assert html =~ "A tiny passing thought"

    render_change(element(revisited, "#writing-form"), %{
      "entry" => %{"body" => "A tiny passing thought, revisited"}
    })

    assert Writing.get_entry!(entry.id).body == "A tiny passing thought, revisited"

    assert [%{body: "A tiny passing thought"}] =
             Writing.list_versions(Writing.get_entry!(entry.id))
  end

  test "an edit from another window never silently replaces the page", %{conn: conn} do
    {:ok, entry} = Writing.save_entry(nil, "Original page")
    {:ok, first, _} = live(conn, ~p"/w/#{entry.id}")
    {:ok, second, _} = live(conn, ~p"/w/#{entry.id}")

    render_change(element(first, "#writing-form"), %{"entry" => %{"body" => "First window"}})

    assert render_change(element(second, "#writing-form"), %{
             "entry" => %{"body" => "Second window"}
           }) =~ "Keep both pages"

    assert Writing.get_entry!(entry.id).body == "First window"

    second |> element("#stale-notice button") |> render_click()

    assert Enum.map(Writing.list_entries(), & &1.body) |> Enum.sort() == [
             "First window",
             "Second window"
           ]
  end

  test "an older page can return without a search", %{conn: conn} do
    {:ok, entry} = Writing.save_entry(nil, "A forgotten tune in a stairwell")

    Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -45, :day)]
    )

    {:ok, view, html} = live(conn, ~p"/")
    refute html =~ "From another day"
    assert has_element?(view, "#writing-body")

    render_change(element(view, "#writing-form"), %{
      "entry" => %{"body" => "The first words today"}
    })

    assert render(view) =~ "From another day"
    assert render(view) =~ "A forgotten tune"
  end
end
