defmodule StillWeb.WritingAttentionTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Desk, Poems, Repo, Storage, Writing}
  alias Still.Writing.Entry
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    folder = Path.join(root, "collection")
    File.mkdir!(folder)
    {:ok, _} = Storage.set_folder(folder)
    location = Storage.collection_location()
    first = historical("opal quartz orchard\na patient ladder waits")
    second = historical("lantern compass resting\nbeside a distant harbor")
    body = "opal quartz orchard\n\nlantern compass resting\n"
    {:ok, piece} = Poems.save(location, Poems.new(location), %{title: "Two passages", body: body})
    %{location: location, piece: piece, first: first, second: second}
  end

  test "moving the caret changes the historical company while words, revisions, and cursor stay intact",
       %{conn: conn, location: location, piece: piece, first: first, second: second} do
    {:ok, view, _} = live(conn, ~p"/writing/#{piece.id}/edit")
    {:ok, cursor} = Desk.current(location)
    listen(view, piece, 2)
    send(view.pid, {:settle_before, piece.id, piece.body})
    assert has_element?(view, "#drawn-before-#{first.id}")
    refute has_element?(view, "#drawn-before-#{second.id}")
    listen(view, piece, 24)
    send(view.pid, {:settle_before, piece.id, piece.body})
    render(view)
    release(view, piece)
    assert has_element?(view, "#drawn-before-#{second.id}")
    refute has_element?(view, "#drawn-before-#{first.id}")
    assert Poems.get(location, piece.id) == {:ok, piece}
    assert Poems.revisions(location, piece.id) == {:ok, []}
    assert Desk.current(location) == {:ok, cursor}
    assert Writing.list_versions(first) == []
    assert Writing.list_versions(second) == []
  end

  test "a late release cannot resurrect the passage left behind; invalid and ahead-of-form signals never replace words",
       %{conn: conn, location: location, piece: piece, first: first, second: second} do
    {:ok, view, _} = live(conn, ~p"/writing/#{piece.id}/edit")
    listen(view, piece, 2)
    send(view.pid, {:settle_before, piece.id, piece.body})
    render(view)
    listen(view, piece, 24)
    send(view.pid, {:settle_before, piece.id, piece.body})
    render(view)
    old = :sys.get_state(view.pid).socket.assigns.field_transition
    assert is_reference(old)
    listen(view, piece, 2)
    send(view.pid, {:settle_before, piece.id, piece.body})
    render(view)
    send(view.pid, {:release_before, piece.id, piece.body, old})
    assert has_element?(view, "#drawn-before-#{first.id}:not(.gravity-receding)")
    refute has_element?(view, "#drawn-before-#{second.id}")

    render_hook(view, "echo_attention", %{
      id: "another-file",
      body: piece.body,
      start: 24,
      end: 24
    })

    render_hook(view, "echo_attention", %{id: piece.id, body: piece.body, start: -1, end: 2})
    send(view.pid, {:settle_before, piece.id, piece.body})
    assert has_element?(view, "#drawn-before-#{first.id}")

    render_hook(view, "echo_attention", %{
      id: piece.id,
      body: "Newer unsubmitted words",
      start: 3,
      end: 3
    })

    send(view.pid, {:settle_before, piece.id, piece.body})
    assert Poems.get(location, piece.id) == {:ok, piece}
    assert has_element?(view, "#file-writing-body", "lantern compass resting")
    assert Poems.revisions(location, piece.id) == {:ok, []}
  end

  test "saved reading can listen to either passage, keeps source line IDs, and returns to whole-page company",
       %{conn: conn, location: location, piece: piece, second: second} do
    {:ok, view, html} = live(conn, ~p"/writing/#{piece.id}")

    lines =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#file-text [data-authored-line]")
      |> Enum.map(&LazyHTML.text/1)

    assert Enum.join(lines, "\n") == piece.body
    assert has_element?(view, "#file-passage-3", "lantern compass resting")
    view |> element("#listen-passage-3") |> render_click()
    assert has_element?(view, "#drawn-before-#{second.id}")
    refute has_element?(view, "#reading-company")
    assert has_element?(view, "#listen-passage-3[aria-pressed=true]")
    view |> element("#listen-whole") |> render_click()
    refute has_element?(view, ".passage-listening")
    refute has_element?(view, ".gravity-presence")
    assert has_element?(view, "#reading-company")
    assert Poems.get(location, piece.id) == {:ok, piece}
  end

  test "an explicitly selected uncommon word can draw a companion without making ordinary single-word typing noisy",
       %{conn: conn, location: location, piece: piece, first: first} do
    assert Writing.gravity_field("quartz", historical_only: true) == []
    {:ok, view, _} = live(conn, ~p"/writing/#{piece.id}/edit")
    render_hook(view, "echo_attention", %{id: piece.id, body: piece.body, start: 5, end: 11})
    send(view.pid, {:settle_before, piece.id, piece.body})
    assert has_element?(view, "#drawn-before-#{first.id}")
    assert Writing.gravity_field("the", historical_only: true, selection: true) == []
    assert Poems.get(location, piece.id) == {:ok, piece}
  end

  test "a saved edition never brings its own historical original into the writing field", %{
    conn: conn,
    location: location,
    first: original
  } do
    {:ok, piece} = Poems.from_historical(location, original)
    {:ok, view, _} = live(conn, ~p"/writing/#{piece.id}/edit")
    send(view.pid, {:settle_before, piece.id, piece.body})
    refute has_element?(view, "#drawn-before-#{original.id}")
    assert Writing.get_entry!(original.id) == original
  end

  defp listen(view, piece, offset),
    do:
      render_hook(view, "echo_attention", %{
        id: piece.id,
        body: piece.body,
        start: offset,
        end: offset
      })

  defp release(view, piece) do
    transition = :sys.get_state(view.pid).socket.assigns.field_transition

    if is_reference(transition),
      do: send(view.pid, {:release_before, piece.id, piece.body, transition})

    render(view)
  end

  defp historical(body) do
    Repo.insert!(
      Entry.changeset(%Entry{}, %{
        origin: "before",
        title: "Earlier",
        body: body,
        notebook: "Synthetic notebook",
        source_group: Ecto.UUID.generate(),
        source_key: Ecto.UUID.generate()
      })
    )
  end
end
