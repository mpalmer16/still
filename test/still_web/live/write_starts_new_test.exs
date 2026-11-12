defmodule StillWeb.WriteStartsNewTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Desk, Poems, Storage}
  alias Still.Writing.Files

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    old_state = Application.get_env(:still, :storage_state_directory)
    state_dir = Path.join(root, "state")
    Application.put_env(:still, :storage_state_directory, state_dir)
    folder = Path.join(root, "collection")
    File.mkdir_p!(folder)
    assert {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      if old_state,
        do: Application.put_env(:still, :storage_state_directory, old_state),
        else: Application.delete_env(:still, :storage_state_directory)
    end)

    %{folder: folder, state_dir: state_dir, location: Storage.collection_location()}
  end

  test "Write after reading a saved Unplaced piece opens a fresh page without changing it", %{
    conn: conn,
    location: location,
    state_dir: state_dir
  } do
    {:ok, notebook} = Files.create_folder(location, "Field book New", %{label: "Field book New"})
    {:ok, transcription, _} = live(conn, "/?notebook=#{notebook.id}&unplaced=true")
    body = "A title from transcription\n  Authored words\n"

    render_change(element(transcription, "#file-writing-form"), %{
      "writing" => %{
        "body" => body,
        "notebook_id" => to_string(notebook.id),
        "unplaced" => "true"
      }
    })

    assert {:ok, %{saved: false, dirty: true}} = Desk.current(location)
    state_path = Path.wildcard(Path.join(state_dir, "desk-*.json")) |> List.first()
    refute File.read!(state_path) =~ "Authored words"

    render_submit(element(transcription, "#file-writing-form"), %{
      "writing" => %{"body" => body, "notebook_id" => to_string(notebook.id)}
    })

    {:ok, [saved]} = Poems.list(location)
    assert saved.unplaced
    assert saved.body == body

    {:ok, reader, _} = live(conn, ~p"/notebooks/read/#{saved.entry_id}")
    assert has_element?(reader, "#notebook-sidebar")
    assert has_element?(reader, "#notebook-content", "Authored words")

    {:ok, write, _} = live(conn, ~p"/")
    assert has_element?(write, "#writing-editor[data-surface='writing']")
    refute has_element?(write, "#notebook-sidebar")
    refute has_element?(write, "#file-writing-body[data-document-id='#{saved.id}']")
    assert has_element?(write, "#file-writing-body[data-resume-active='false']")

    [persisted] =
      write
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#file-writing-body")
      |> LazyHTML.attribute("data-persisted")

    assert Jason.decode!(persisted)["body"] == ""
    assert {:ok, cursor} = Desk.current(location)
    refute cursor.saved
    assert cursor.id != saved.id
    assert File.read!(saved.path) == body
    assert {:ok, unchanged} = Poems.get(location, saved.id)
    assert unchanged.body == body
    assert unchanged.relative_path == saved.relative_path
  end

  test "a dirty saved editor resumes after reading, with only identity and dirty state persisted",
       %{
         conn: conn,
         location: location,
         state_dir: state_dir
       } do
    {:ok, saved} =
      Poems.save(location, Poems.new(location), %{body: "Private words stay in the file"})

    {:ok, editor, _} = live(conn, ~p"/writing/#{saved.id}/edit")

    render_hook(editor, "file_editing_state", %{
      "id" => saved.id,
      "token" => saved.token,
      "dirty" => true
    })

    assert {:ok, %{id: id, saved: true, dirty: true}} = Desk.current(location)
    assert id == saved.id

    state_path = Path.wildcard(Path.join(state_dir, "desk-*.json")) |> List.first()
    state = state_path |> File.read!() |> Jason.decode!()
    desk = state["still_desk_v1"]
    [encoded_cursor] = Map.values(desk["cursors"])
    assert encoded_cursor["dirty"]
    refute Map.has_key?(encoded_cursor, "body")
    refute File.read!(state_path) =~ "Private words stay in the file"

    {:ok, reader, _} = live(conn, ~p"/writing/#{saved.id}")
    assert has_element?(reader, "#file-text", "Private words stay in the file")
    {:ok, resumed, _} = live(conn, ~p"/")

    assert has_element?(
             resumed,
             "#file-writing-body[data-document-id='#{saved.id}'][data-resume-active='true']"
           )

    assert has_element?(resumed, "#writing-editor[data-surface='writing']")
    refute has_element?(resumed, "#notebook-sidebar")
  end

  test "stale clean reports cannot clear the current draft, and recovery waiting keeps it unfinished",
       %{conn: conn, location: location} do
    {:ok, saved} = Poems.save(location, Poems.new(location), %{body: "Saved words"})
    saved_id = saved.id
    {:ok, editor, _} = live(conn, ~p"/writing/#{saved.id}/edit")

    render_hook(editor, "file_editing_state", %{
      "id" => saved.id,
      "token" => saved.token,
      "dirty" => true
    })

    render_hook(editor, "file_editing_state", %{
      "id" => saved.id,
      "token" => "stale-token",
      "dirty" => false
    })

    render_hook(editor, "file_editing_state", %{
      "id" => Ecto.UUID.generate(),
      "token" => saved.token,
      "dirty" => false
    })

    assert {:ok, %{id: id, saved: true, dirty: true}} = Desk.current(location)
    assert id == saved.id

    render_hook(editor, "file_recovery_status", %{"waiting" => true})

    render_hook(editor, "file_editing_state", %{
      "id" => saved.id,
      "token" => saved.token,
      "dirty" => false
    })

    assert {:ok, %{id: ^saved_id, saved: true, dirty: true}} = Desk.current(location)
    assert {:ok, %{id: ^saved_id, saved: true, dirty: true}} = Desk.for_write(location)

    render_hook(editor, "file_recovery_status", %{"waiting" => false})
    assert {:ok, %{id: ^saved_id, saved: true, dirty: false}} = Desk.current(location)
    assert {:ok, nil} = Desk.for_write(location)

    {:ok, write, _} = live(conn, ~p"/")
    assert has_element?(write, "#file-writing-body[data-resume-active='false']")
    refute has_element?(write, "#file-writing-body[data-document-id='#{saved.id}']")
  end

  test "New leaves a clean saved file untouched and starts a separate page", %{
    conn: conn,
    location: location
  } do
    {:ok, saved} =
      Poems.save(location, Poems.new(location), %{
        body: "Do not replace this saved page",
        relative_path: "Saved.txt"
      })

    {:ok, editor, _} = live(conn, ~p"/writing/#{saved.id}/edit")

    render_click(editor, "new_file", %{
      "writing" => %{"body" => saved.body, "title" => ""}
    })

    assert_redirect(editor, ~p"/?new=1")
    assert {:ok, unchanged} = Poems.get(location, saved.id)
    assert unchanged.body == saved.body
    assert unchanged.relative_path == "Saved.txt"
    assert {:ok, []} = Poems.revisions(location, saved.id)

    {:ok, fresh, _} = live(conn, ~p"/?new=1")
    assert has_element?(fresh, "#file-writing-body[data-resume-active='false']")
    refute has_element?(fresh, "#file-writing-body[data-document-id='#{saved.id}']")
  end
end
