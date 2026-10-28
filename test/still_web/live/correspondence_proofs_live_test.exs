defmodule StillWeb.CorrespondenceProofsLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Correspondence, Desk, Poems, Storage}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    folder = Path.join(root, "collection")
    File.mkdir!(folder)
    {:ok, _} = Storage.set_folder(folder)
    %{location: Storage.collection_location(), folder: folder}
  end

  test "compares the frozen sent copy with current words and title without changing either or the desk",
       %{conn: conn, location: location, folder: folder} do
    old_body = "A line kept.\r\n  An earlier <b>rain</b>.  \r\n\r\nThe end.\r\n"
    new_body = "A line kept.\r\n  A different <b>rain</b>.  \r\n\r\nThe end.\r\n"

    {:ok, piece} =
      Poems.save(location, Poems.new(location), %{title: "Earlier title", body: old_body})

    {:ok, journal} = Correspondence.save_journal(location, %{name: "Original journal name"})

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "The packet",
        journal_id: journal.id,
        piece_ids: [piece.id]
      })

    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-12")

    {:ok, _} =
      Correspondence.save_journal(location, %{name: "Renamed journal"}, journal.id, journal.token)

    {:ok, current} = Poems.save(location, piece, %{title: "Current title", body: new_body})
    :ok = Desk.remember(location, %{id: current.id, saved: true, beside: nil})
    {:ok, desk} = Desk.current(location)
    {:ok, revisions} = Poems.revisions(location, current.id)
    before = snapshot(folder)

    {:ok, view, _} = live(conn, ~p"/correspondence/writing/#{current.id}")
    assert has_element?(view, "#open-work-proof", "Then & now")
    view |> element("#open-work-proof") |> render_click()
    assert has_element?(view, "#work-proof")
    assert has_element?(view, "#proof-earlier h3", "Earlier title")
    assert has_element?(view, "#proof-current h3", "Current title")
    assert has_element?(view, "#proof-earlier", "Sent to Original journal name")
    refute has_element?(view, "#proof-earlier", "Renamed journal")
    assert has_element?(view, "#proof-earlier mark.proof-removed", "An earlier <b>rain</b>.")
    assert has_element?(view, "#proof-current mark.proof-added", "A different <b>rain</b>.")
    refute has_element?(view, "#work-proof b")
    assert has_element?(view, "#proof-open-packet[href='/correspondence/packets/#{sent.id}']")
    assert has_element?(view, "#proof-edit-current[href='/writing/#{current.id}/edit']")
    view |> element("#proof-just-read") |> render_click()
    refute has_element?(view, "#work-proof mark")
    assert has_element?(view, "#proof-earlier .proof-text", "An earlier <b>rain</b>.")
    view |> element("#proof-show-changes") |> render_click()
    assert has_element?(view, "#proof-current mark.proof-added")
    assert Poems.get(location, current.id) == {:ok, current}
    assert Poems.revisions(location, current.id) == {:ok, revisions}
    assert Correspondence.packet(location, sent.id) == {:ok, sent}
    assert Desk.current(location) == {:ok, desk}
    assert snapshot(folder) == before
  end

  test "the source chooser can compare an earlier save and a title-only change", %{
    conn: conn,
    location: location
  } do
    body = "Same words.\n\n  Same space.\n"
    {:ok, piece} = Poems.save(location, Poems.new(location), %{title: "First title", body: body})
    {:ok, current} = Poems.save(location, piece, %{title: "Second title", body: body})
    {:ok, [revision]} = Poems.revisions(location, current.id)
    {:ok, view, _} = live(conn, ~p"/correspondence/writing/#{current.id}?compare=latest")
    assert has_element?(view, "#proof-status", "The words match. The title has changed.")
    assert has_element?(view, "#proof-earlier h3", "First title")
    refute has_element?(view, "#work-proof mark")

    view
    |> form("#proof-source-form", proof: %{source: "saved:#{revision.id}"})
    |> render_change()

    assert has_element?(view, "#proof-source option[selected][value='saved:#{revision.id}']")
    view |> element("#close-proof") |> render_click()
    refute has_element?(view, "#work-proof")
    assert has_element?(view, ".corr-manuscript", "Same words.")
    assert Poems.get(location, current.id) == {:ok, current}
  end

  test "a source from another work is refused and an empty history stays clear", %{
    conn: conn,
    location: location
  } do
    {:ok, piece} =
      Poems.save(location, Poems.new(location), %{title: "Here", body: "Keep these words."})

    {:ok, other} =
      Poems.save(location, Poems.new(location), %{
        title: "Elsewhere",
        body: "Other private words."
      })

    {:ok, journal} = Correspondence.save_journal(location, %{name: "Test journal"})

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Elsewhere packet",
        journal_id: journal.id,
        piece_ids: [other.id]
      })

    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-01")

    {:ok, view, html} =
      live(conn, ~p"/correspondence/writing/#{piece.id}?compare=#{"sent:#{sent.id}"}")

    assert has_element?(view, "#proof-problem", "That version isn't available for this work")
    refute has_element?(view, "#work-proof")
    assert has_element?(view, ".corr-manuscript", "Keep these words.")
    refute html =~ "Other private words"
    {:ok, empty, _} = live(conn, ~p"/correspondence/writing/#{piece.id}?compare=latest")
    assert has_element?(empty, "#proof-problem", "no earlier saves or sent copies")
    refute has_element?(empty, "#open-work-proof")
  end

  test "an unavailable folder explains the problem instead of opening a different work", %{
    conn: conn,
    location: location,
    folder: folder
  } do
    {:ok, piece} = Poems.save(location, Poems.new(location), %{title: "Here", body: "Words"})
    File.rename!(folder, folder <> "-missing")
    {:ok, view, _} = live(conn, ~p"/correspondence/writing/#{piece.id}?compare=latest")
    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "#work-proof")
    refute File.exists?(folder)
  end

  defp snapshot(folder) do
    Path.wildcard(Path.join(folder, "**/*"), match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, folder), File.read!(&1)})
  end
end
