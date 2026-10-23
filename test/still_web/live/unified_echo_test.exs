defmodule StillWeb.UnifiedEchoTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Desk, Poems, Repo, Storage, Writing}
  alias Still.Writing.Entry
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    folder = Path.join(root, "collection")
    File.mkdir!(folder)
    {:ok, _} = Storage.set_folder(folder)
    %{folder: folder}
  end

  test "composing draws only historical Lists and echo reading leaves the current file desk intact",
       %{conn: conn} do
    historical =
      Repo.insert!(
        Entry.changeset(%Entry{}, %{
          origin: "before",
          source_key: "lists:synthetic-echo",
          source_group: "synthetic-page",
          notebook: "Synthetic notebook",
          source_order: 0,
          title: "Archive echo:",
          body: "cobalt instruments remember a distant harbor"
        })
      )

    {:ok, legacy} = Writing.save_entry(nil, historical.body)
    {:ok, view, _} = live(conn, ~p"/?new=1")
    body = "\n    cobalt instruments remember a distant harbor\n\n\tNew words.\n"
    view |> form("#file-writing-form", writing: %{body: body, title: ""}) |> render_change()
    {:ok, cursor} = Desk.current(Storage.collection_location())
    send(view.pid, {:settle_before, cursor.id, body})
    assert has_element?(view, ".gravity-door[href^='/w/#{historical.id}?read=1']")
    refute has_element?(view, ".gravity-door[href^='/w/#{legacy.id}?']")
    assert Writing.get_entry!(historical.id) == historical
    assert Writing.list_versions(historical) == []

    view
    |> form("#file-writing-form", writing: %{body: body, title: "New file"})
    |> render_submit()

    {:ok, [saved]} = Poems.list(Storage.collection_location())
    {:ok, read, _} = live(conn, ~p"/w/#{historical.id}?read=1&approach=left")
    assert has_element?(read, "#return-to-writing[href='/']")
    refute has_element?(read, "#delete-file")
    assert {:ok, %{id: id, saved: true}} = Desk.current(Storage.collection_location())
    assert id == saved.id
    {:ok, now, _} = live(conn, ~p"/")

    assert has_element?(
             now,
             "#file-writing-body[data-document-id='#{saved.id}'][data-resume-active='true']"
           )

    assert Poems.get(Storage.collection_location(), id) == {:ok, saved}
    assert Writing.get_entry!(historical.id) == historical
  end

  test "explicit new page stays blank while the previous file remains intact, and saves promote the same UUID",
       %{conn: conn} do
    {:ok, first, _} = live(conn, ~p"/?new=1")

    first
    |> form("#file-writing-form", writing: %{body: "old new writing", title: "First"})
    |> render_submit()

    {:ok, [previous]} = Poems.list(Storage.collection_location())
    {:ok, blank, _} = live(conn, ~p"/?new=1")
    {:ok, cursor} = Desk.current(Storage.collection_location())
    refute cursor.saved
    assert cursor.id != previous.id
    assert has_element?(blank, "#file-writing-body[data-resume-active='false']")
    blank |> form("#file-writing-form", writing: %{body: "", title: ""}) |> render_submit()
    assert {:ok, %{id: id, saved: true}} = Desk.current(Storage.collection_location())
    assert id == cursor.id
    {:ok, now, _} = live(conn, ~p"/")
    assert has_element?(now, "#file-writing-body[data-document-id='#{id}']")
    assert Poems.get(Storage.collection_location(), previous.id) == {:ok, previous}
    assert Writing.list_entries() == []
  end

  test "Read saves the current text before opening the reading view", %{conn: conn} do
    {:ok, now, _} = live(conn, ~p"/?new=1")

    render_hook(now, "save_file", %{
      writing: %{body: "latest words\n\tand space", title: ""},
      read: true
    })

    {:ok, [saved]} = Poems.list(Storage.collection_location())
    assert_redirect(now, ~p"/writing/#{saved.id}")
    assert saved.body == "latest words\n\tand space"
  end

  test "refreshing a different root cancels an earlier permanent-delete confirmation", %{
    conn: conn,
    folder: folder
  } do
    location = Storage.collection_location()

    {:ok, piece} =
      Poems.save(location, Poems.new(location), %{title: "Synthetic", body: "keep both copies"})

    {:ok, _} = Poems.trash(location, piece)
    {:ok, trash, _} = live(conn, ~p"/writing?trash=1")
    trash |> element("button", "Delete permanently…") |> render_click()
    assert has_element?(trash, "#purge-confirmation")
    other = folder <> "-other"
    File.mkdir!(other)
    File.cp_r!(Path.join(folder, "poems"), Path.join(other, "poems"))
    on_exit(fn -> File.rm_rf!(other) end)
    {:ok, _} = Storage.set_folder(other)
    trash |> element("#refresh-writing") |> render_click()
    refute has_element?(trash, "#purge-confirmation")
    render_hook(trash, "confirm_purge", %{})
    assert File.regular?(Path.join([folder, "poems", ".trash", piece.id, "poem.txt"]))
    assert File.regular?(Path.join([other, "poems", ".trash", piece.id, "poem.txt"]))
  end
end
