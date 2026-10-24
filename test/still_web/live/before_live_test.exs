defmodule StillWeb.BeforeLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Repo, Writing}
  alias Still.Writing.Entry

  defp piece(attrs \\ %{}) do
    %Entry{}
    |> Entry.changeset(
      Map.merge(
        %{
          title: "The:Uncertain:Light:",
          body:
            "A thought - and another / still\n\tone branch\n\tanother branch\n\n\"A voice\"\n\"Another voice\"",
          origin: "before",
          source_key: Ecto.UUID.generate(),
          source_group: "one-page",
          notebook: "Early Notebooks/Lists 1",
          source_order: 0,
          source: %{
            "original_title" => "The uncertain light",
            "artifacts" => [%{"path" => "Old.doc"}]
          }
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  test "before is readable with authored whitespace and no imported date", %{conn: conn} do
    entry = piece()
    {:ok, view, html} = live(conn, ~p"/w/#{entry.id}")
    assert html =~ "From before"
    assert html =~ "A thought - and another / still"
    assert has_element?(view, ".authored-line[style=\"--indent: 2.0em\"]", "one branch")
    assert html =~ "\tanother branch"

    assert html
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#list-body [data-authored-line]")
           |> Enum.map(&LazyHTML.text/1)
           |> Enum.join("\n") == entry.body

    assert html |> LazyHTML.from_fragment() |> LazyHTML.query(".list-title") |> LazyHTML.text() ==
             entry.title

    refute has_element?(view, "time")
    refute has_element?(view, "#writing-form")
    assert has_element?(view, ".list-title", "The:")
    assert has_element?(view, ".source-neighborhood", "Early Notebooks · Lists 1")
  end

  test "editing before retains title and words together in history", %{conn: conn} do
    entry = piece()
    {:ok, view, _} = live(conn, ~p"/w/#{entry.id}")
    view |> element("button", "Change these words") |> render_click()
    assert has_element?(view, "#writing-title")

    view
    |> element("#writing-form")
    |> render_submit(%{
      "entry" => %{
        "title" => "The:Light:Again:",
        "body" => "Still one thought\n\tstill branched"
      }
    })

    assert has_element?(view, "#list-body", "Still one thought")
    assert render(view) =~ "&amp; now"
    saved = Writing.get_entry!(entry.id)
    assert saved.title == "The:Light:Again:"
    assert saved.returned_at
    assert [%{title: "The:Uncertain:Light:", body: original}] = Writing.list_versions(saved)
    assert original == entry.body

    view |> element("button", "Earlier words") |> render_click()
    view |> element(".version-row button") |> render_click()
    assert Writing.get_entry!(entry.id).body == entry.body
    assert Writing.get_entry!(entry.id).title == entry.title
    assert length(Writing.list_versions(saved)) == 2
  end

  test "source siblings stay reachable and source prelude is escaped", %{conn: conn} do
    first = piece(%{source: %{"preamble" => "An earlier line\n<not markup>", "artifacts" => []}})
    second = piece(%{title: "A:Second:Small:Piece:", source_order: 1})
    {:ok, view, html} = live(conn, ~p"/w/#{first.id}")

    assert has_element?(
             view,
             "section[aria-label='These were together'] a[href='/w/#{second.id}?cross=sibling']"
           )

    assert html =~ "Before these words"
    assert html =~ "&lt;not markup&gt;"
    refute html =~ "<not markup>"
  end

  test "editing and reading an unchanged old List leaves words and provenance alone", %{
    conn: conn
  } do
    entry = piece()
    {:ok, view, _} = live(conn, ~p"/w/#{entry.id}")
    element(view, "button", "Change these words") |> render_click()

    render_submit(element(view, "#writing-form"), %{
      "entry" => %{"title" => entry.title, "body" => entry.body}
    })

    unchanged = Writing.get_entry!(entry.id)
    assert unchanged.body == entry.body
    assert unchanged.title == entry.title
    assert unchanged.source == entry.source
    assert unchanged.returned_at == nil
    assert Writing.list_versions(unchanged) == []
  end

  test "new writing sits beside historical words without adding a SQLite record", %{conn: conn} do
    old = piece()
    {:ok, view, _} = live(conn, ~p"/?beside=#{old.id}")
    assert has_element?(view, "#file-writing-body")
    assert has_element?(view, ".beside-title", old.title)

    view
    |> form("#file-writing-form", writing: %{body: "A new answer of my own", title: ""})
    |> render_change()

    assert Writing.list_entries(origin: "now") == []
    assert Writing.get_entry!(old.id) == old
    {:ok, reopened, _} = live(conn, ~p"/w/#{old.id}")
    assert has_element?(reopened, "#return-to-writing[href='/']")
    {:ok, current, _} = live(conn, ~p"/")
    assert has_element?(current, ".beside-title", old.title)
  end

  test "a recent echo is read without replacing the current Now", %{conn: conn} do
    old = piece(%{body: "cobalt teacups: herons:"})
    {:ok, recent} = Writing.save_entry(nil, "cobalt teacups: herons:", writing_form: "list")
    {:ok, current} = Writing.save_entry(nil, "The words I am still writing")
    Writing.remember_writing(current)

    {:ok, view, _} = live(conn, ~p"/w/#{old.id}")
    assert has_element?(view, ".gravity-door[href^='/w/#{recent.id}?read=1']")
    assert has_element?(view, "#return-to-writing[href='/']")

    {:ok, read, _} = live(conn, ~p"/w/#{recent.id}?read=1")
    assert has_element?(read, ".reading-room")
    refute has_element?(read, "#writing-form")
    assert Writing.current_writing().id == current.id
    assert has_element?(read, "#return-to-writing[href='/']")
    assert Writing.get_entry!(recent.id).body == recent.body
    assert Writing.list_versions(recent) == []
  end

  test "a title in ordinary words finds its colon form without invented chronology", %{conn: conn} do
    entry = piece()
    {:ok, view, _} = live(conn, ~p"/pages?q=uncertain%20light")
    assert has_element?(view, "a[href^='/w/#{entry.id}?']")
    assert has_element?(view, ".entry-notebook", String.replace(entry.notebook, "/", " · "))
    refute has_element?(view, "time")
  end

  test "recovering browser words keeps the current title and body even inside the snapshot interval",
       %{conn: conn} do
    entry = piece()
    {:ok, view, _} = live(conn, ~p"/w/#{entry.id}")
    view |> element("button", "Change these words") |> render_click()

    view
    |> element("#writing-form")
    |> render_submit(%{
      "entry" => %{"title" => "Current:Words:", "body" => "Words saved just now\n\tstill here"}
    })

    current = Writing.get_entry!(entry.id)
    assert length(Writing.list_versions(current)) == 1
    refute has_element?(view, "#writing-form")

    render_hook(view, "recovery_found", %{})
    view |> element("#recovery-notice button", "Bring them back") |> render_click()
    assert_push_event(view, "restore-local", %{})
    assert has_element?(view, "#writing-form")

    view
    |> element("#writing-form")
    |> render_change(%{
      "entry" => %{"title" => "Words:Kept:By:The:Browser:", "body" => "An older browser copy"}
    })

    recovered = Writing.get_entry!(entry.id)
    assert recovered.body == "An older browser copy"
    assert recovered.title == "Words:Kept:By:The:Browser:"

    assert Enum.any?(Writing.list_versions(recovered), fn version ->
             version.body == current.body and version.title == current.title
           end)

    refute has_element?(view, "#recovery-notice")
  end

  test "a stale history restore offers the current words without a copy of unknown browser words",
       %{conn: conn} do
    original = piece()

    {:ok, current} =
      Writing.save_entry(original, "Current words", title: "Current:", checkpoint: true)

    {:ok, view, _} = live(conn, ~p"/w/#{current.id}")
    view |> element("button", "Earlier words") |> render_click()

    {:ok, other_window} =
      Writing.save_entry(current, "Changed in another window",
        title: "Other:Window:",
        checkpoint: true
      )

    versions_before = Writing.list_versions(other_window)
    view |> element(".version-row button") |> render_click()

    assert has_element?(view, "#stale-restore-notice", "Reopen them before restoring")

    assert has_element?(
             view,
             "#stale-restore-notice a[href='/w/#{current.id}']",
             "Open the current words"
           )

    refute has_element?(view, "#stale-notice")
    refute has_element?(view, "button", "Keep both pages")
    assert Writing.get_entry!(current.id).body == other_window.body
    assert Writing.get_entry!(current.id).title == other_window.title
    assert Writing.list_versions(other_window) == versions_before
  end
end
