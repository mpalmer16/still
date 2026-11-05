defmodule Still.FilenameTitleTest do
  use StillWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Still.{Poems, Repo, Storage, Writing}
  alias Still.Writing.{Entry, Files, TextFile}

  @moduletag :tmp_dir
  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "collection")
    File.mkdir_p!(Path.join(folder, "Poems"))
    {:ok, _} = Storage.set_folder(folder)
    location = Storage.collection_location()
    {:ok, _} = Files.register_folder(location, "Poems", %{label: "Poems", numbered: false})
    on_exit(fn -> Application.put_env(:still, :storage_state_directory, previous) end)
    %{folder: folder, location: location}
  end

  test "a saved filename supplies the label without turning the opening into a title", %{
    folder: folder,
    location: location,
    conn: conn
  } do
    bytes = <<239, 187, 191>> <> "An unrelated opening\r\n\r\n  Exact stanza\n\tand indentation\n"
    path = Path.join(folder, "Poems/Winter_Light.txt")
    File.write!(path, bytes)
    assert {:ok, [piece]} = Poems.list(location)
    entry = Repo.get!(Entry, piece.entry_id)
    assert Poems.display_title(piece) == "Winter Light"
    assert Writing.opening(entry) == "Winter Light"
    assert Poems.explicit_title(piece) == nil
    assert piece.title_line == nil
    assert entry.title == nil
    assert File.read!(path) == bytes
    assert {:ok, []} = Poems.revisions(location, piece.id)

    {:ok, shelf, _} = live(conn, ~p"/writing")
    assert has_element?(shelf, "#saved-#{piece.id} .file-piece-title", "Winter Light")
    {:ok, found, _} = live(conn, ~p"/pages?q=Winter+Light")
    assert has_element?(found, ".entry-row", "Winter Light")
    assert render(found) =~ "An unrelated opening"
    {:ok, edit, _} = live(conn, ~p"/writing/#{piece.id}/edit")
    refute render(element(edit, "#file-writing-body")) =~ "Winter Light"
    assert render(element(edit, "#file-writing-body")) =~ "An unrelated opening"
    assert File.read!(path) == bytes
  end

  test "renaming updates title search without changing identity, body or prior versions", %{
    folder: folder,
    location: location
  } do
    path = Path.join(folder, "Poems/Harbor Light.txt")
    File.write!(path, "  Opening words\n\n\tBody")
    {:ok, [piece]} = Poems.list(location)
    assert [%{entry: %{id: id}}] = Writing.find_entries(query: "Harbor Light")
    assert id == piece.entry_id
    assert {:ok, renamed} = Poems.rename(location, piece, "Harbor_Light.txt")
    assert renamed.id == piece.id
    assert renamed.entry_id == piece.entry_id
    assert renamed.body == piece.body
    assert Poems.display_title(renamed) == "Harbor Light"

    assert {:ok, revised} =
             Poems.save(location, renamed, %{body: "A changed opening\n\n  A revised stanza"})

    assert Poems.display_title(revised) == "Harbor Light"
    assert revised.relative_path == "Poems/Harbor_Light.txt"
    assert {:ok, [version]} = Poems.revisions(location, piece.id)
    assert version.body == piece.body
    assert {:ok, retitled} = Poems.rename(location, revised, "Lanterns_At_Dusk.txt")
    assert Poems.display_title(retitled) == "Lanterns At Dusk"
    assert Writing.find_entries(query: "Harbor Light") == []
    assert [%{entry: %{id: ^id}}] = Writing.find_entries(query: "Lanterns At Dusk")
    assert File.read!(retitled.path) == revised.body
    assert {:ok, [^version]} = Poems.revisions(location, piece.id)
  end

  test "explicit title-line meaning stays separate from filename labels", %{
    folder: folder,
    location: location
  } do
    body = "An opening\n\nChosen title\n\tExact words\n"
    File.write!(Path.join(folder, "Poems/Original_filename.txt"), body)
    {:ok, [piece]} = Poems.list(location)
    {:ok, selected} = Poems.set_title_role(location, piece, 3)
    assert Poems.display_title(selected) == "Chosen title"
    assert Writing.opening(Repo.get!(Entry, selected.entry_id)) == "Chosen title"
    assert selected.body == body
    assert File.read!(selected.path) == body
  end

  test "readable filename labels retain title words and strip only text extensions and known List numbers" do
    for {path, number, expected} <- [
          {"Poems/What_the_wind_said.txt", nil, "What the wind said"},
          {"Poems/Café_雪.TXT", nil, "Café 雪"},
          {"Poems/1984_at_the_window.txt", nil, "1984 at the window"},
          {"Notebook/0012b_A_quiet_page.txt", "0012b", "A quiet page"},
          {"Notebook/0012b.txt", "0012b", nil},
          {"Drafts/Title.with.periods", nil, "Title.with.periods"},
          {"Drafts/Winter.md", nil, "Winter"},
          {nil, nil, nil}
        ] do
      assert TextFile.filename_label(path, number) == expected
    end

    assert Poems.display_title(%{body: "  A new first line\n", title: nil}) == "A new first line"
  end
end
