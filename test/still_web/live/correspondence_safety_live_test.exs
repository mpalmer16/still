defmodule StillWeb.CorrespondenceSafetyLiveTest do
  use StillWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Still.{Correspondence, Poems, Storage}

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    collection = Path.join(dir, "collection")
    File.mkdir_p!(collection)
    {:ok, _} = Storage.set_folder(collection)
    %{location: Storage.collection_location(), collection: collection}
  end

  test "dark is the default and optional light stays confined to this room", %{conn: conn} do
    {:ok, view, _} = live(conn, "/correspondence")
    assert has_element?(view, ".correspondence-room:not(.is-light)")
    assert has_element?(view, "#open-correspondence[aria-current='page']")
    render_click(element(view, ".corr-theme"))
    assert has_element?(view, ".correspondence-room.is-light")
    render_patch(view, "/correspondence/writing")
    assert has_element?(view, ".correspondence-room.is-light")
    {:ok, writing, _} = live(conn, "/?new=1")
    assert has_element?(writing, "#file-writing-form")
    refute has_element?(writing, ".correspondence-room")
  end

  test "unconfigured room and missing record routes explain the problem without creating records",
       %{conn: conn, collection: dir} do
    {:ok, _} = Storage.clear_folder()

    for path <- [
          "/correspondence",
          "/correspondence/writing",
          "/correspondence/journals/new",
          "/correspondence/packets/new"
        ] do
      {:ok, view, _} = live(conn, path)
      assert has_element?(view, "[role='alert']", "collection folder")
    end

    refute File.exists?(Path.join(dir, "correspondence"))
    {:ok, _} = Storage.set_folder(dir)

    for path <- [
          "/correspondence/writing/invalid",
          "/correspondence/journals/invalid",
          "/correspondence/packets/invalid"
        ] do
      {:ok, view, _} = live(conn, path)
      assert has_element?(view, "[role='alert']")
    end
  end

  test "partial acceptance survives a later decline and identifies other outstanding work", %{
    conn: conn,
    location: loc
  } do
    a = piece(loc, "Accepted piece")
    b = piece(loc, "Other piece")
    {:ok, journal} = Correspondence.save_journal(loc, %{name: "First synthetic journal"})
    {:ok, other_journal} = Correspondence.save_journal(loc, %{name: "Other synthetic journal"})
    sent = sent_packet(loc, journal.id, [a.id, b.id])
    other = sent_packet(loc, other_journal.id, [a.id])
    {:ok, view, _} = live(conn, "/correspondence/packets/#{sent.id}")

    render_submit(element(view, "#response-form"), %{
      "response" => %{
        "status" => "accepted",
        "date" => "2026-10-21",
        "notes" => "One work accepted",
        "accepted_piece_ids" => []
      }
    })

    assert has_element?(view, "[role='alert']", "Choose one or more")

    render_submit(element(view, "#response-form"), %{
      "response" => %{
        "status" => "accepted",
        "date" => "2026-10-21",
        "notes" => "One work accepted",
        "accepted_piece_ids" => [a.id]
      }
    })

    assert has_element?(view, ".corr-overlap", "Review other outstanding submissions")
    assert has_element?(view, ".corr-overlap", "Other synthetic journal")
    assert has_element?(view, ".corr-overlap", "has not contacted anyone")

    render_submit(element(view, "#response-form"), %{
      "response" => %{
        "status" => "declined",
        "date" => "2026-10-23",
        "notes" => "Remaining work returned"
      }
    })

    {:ok, collection, _} = live(conn, "/correspondence/writing")
    assert has_element?(collection, ".corr-library-piece", "Accepted · also away")
    {:ok, home, _} = live(conn, "/correspondence")
    refute has_element?(home, "#ready-#{a.id}")
    {:ok, packets, _} = live(conn, "/correspondence/packets")
    assert has_element?(packets, ".corr-library-piece", "RETURNED · 23 Oct 2026")
    assert {:ok, %{status: "submitted"}} = Correspondence.packet(loc, other.id)
  end

  test "a newer preparation never hides an existing outstanding submission", %{
    conn: conn,
    location: loc
  } do
    a = piece(loc, "A traveling work")
    {:ok, j} = Correspondence.save_journal(loc, %{name: "Synthetic destination"})
    sent = sent_packet(loc, j.id, [a.id])

    {:ok, _} =
      Correspondence.save_packet(loc, %{title: "New draft", journal_id: j.id, piece_ids: [a.id]})

    {:ok, view, _} = live(conn, "/correspondence/writing")
    assert has_element?(view, ".corr-library-piece", "Away now")
    refute has_element?(view, ".corr-library-piece", "In preparation")

    {:ok, _} =
      Correspondence.respond(loc, sent.id, sent.token, "declined", "Returned", "2026-10-23")

    {:ok, reopened, _} = live(conn, "/correspondence/writing")
    assert has_element?(reopened, ".corr-library-piece", "Preparing again")
    refute has_element?(reopened, ".corr-library-piece", "never sent")
  end

  defp piece(loc, title) do
    {:ok, piece} =
      Poems.save(loc, Poems.new(loc), %{
        title: title,
        body: "  Synthetic words\n\nkept exactly.\n"
      })

    piece
  end

  defp sent_packet(loc, journal_id, ids) do
    {:ok, p} =
      Correspondence.save_packet(loc, %{
        title: "Synthetic packet",
        journal_id: journal_id,
        piece_ids: ids
      })

    {:ok, p} = Correspondence.submit(loc, p.id, p.token, "2026-09-21")
    p
  end
end
