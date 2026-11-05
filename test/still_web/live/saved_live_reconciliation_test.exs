defmodule StillWeb.SavedLiveReconciliationTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Ecto.Changeset
  alias Still.{Poems, Repo, Storage}
  alias Still.Writing.Entry
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "collection")
    File.mkdir!(folder)
    on_exit(fn -> Application.put_env(:still, :storage_state_directory, previous) end)
    {:ok, _} = Storage.set_folder(folder)
    %{folder: folder}
  end

  test "a plain text file can be explicitly added to the collection", %{
    conn: conn,
    folder: folder
  } do
    path = Path.join(folder, "Notebook 3/12.md")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "A complete text file\n\nwith its authored spacing.\n")

    {:ok, view, _html} = live(conn, ~p"/writing")
    assert has_element?(view, "#adopt-text-file")

    view
    |> form("#adopt-text-file", path: "Notebook 3/12.md")
    |> render_submit()

    assert has_element?(view, ".file-piece-title", "A complete text file")
    assert {:ok, [piece]} = Poems.list(Storage.collection_location())
    assert piece.body == "A complete text file\n\nwith its authored spacing.\n"
  end

  test "missing writing is surfaced with its known relative location", %{conn: conn} do
    location = Storage.collection_location()

    assert {:ok, piece} =
             Poems.save(location, Poems.new(location), %{body: "Kept words", title_line: nil})

    File.rm!(piece.path)

    {:ok, view, _html} = live(conn, ~p"/writing")
    assert has_element?(view, "#file-reconciliation")
    assert has_element?(view, "#missing-file-#{piece.id}", piece.relative_path)
  end

  test "external and proposed words stay separate until the writer chooses", %{conn: conn} do
    location = Storage.collection_location()

    assert {:ok, piece} =
             Poems.save(location, Poems.new(location), %{body: "Before words", title_line: nil})

    entry = Repo.get_by!(Entry, file_id: piece.id)
    File.write!(piece.path, "Outside words\n")

    pending = %{
      "kind" => "save",
      "old_token" => entry.file_token,
      "body" => "Still's proposed words",
      "prefix" => Base.encode64(""),
      "title_line" => 1,
      "title_anchor" => "Still's proposed words",
      "metadata" => %{
        "notebook_id" => nil,
        "notebook" => nil,
        "source_order" => nil,
        "list_label" => nil
      }
    }

    entry |> Changeset.change(pending: pending) |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/writing")
    assert has_element?(view, "#pending-review-#{piece.id}", "Outside words")
    assert has_element?(view, "#pending-review-#{piece.id}", "proposed words")

    view
    |> element("button[phx-value-piece_id='#{piece.id}'][phx-value-choice='use_proposed']")
    |> render_click()

    assert File.read!(piece.path) == "Still's proposed words"
    assert {:ok, versions} = Poems.revisions(location, piece.id)
    assert Enum.any?(versions, &(&1.body == "Outside words\n"))
    assert has_element?(view, "#saved-#{piece.id}")
  end
end
