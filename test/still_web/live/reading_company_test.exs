defmodule StillWeb.ReadingCompanyTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Desk, Poems, Repo, Storage, Writing}
  alias Still.Writing.Entry

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "collection")
    File.mkdir_p!(folder)
    {:ok, _} = Storage.set_folder(folder)
    on_exit(fn -> Application.put_env(:still, :storage_state_directory, previous) end)
    %{folder: folder}
  end

  test "a saved file offers one historical echo without changing words, revisions, or the desk",
       %{
         conn: conn
       } do
    echo = historical("An earlier page", "opal quartz orchard <b>literal</b>")
    _legacy = Writing.save_entry(nil, "opal quartz orchard") |> elem(1)
    {:ok, view, _} = live(conn, ~p"/writing/new")

    render_submit(element(view, "#file-writing-form"), %{
      "writing" => %{"title" => "Kept page", "body" => "opal quartz orchard"}
    })

    {:ok, [saved]} = Poems.list(Storage.collection_location())
    {:ok, before_cursor} = Desk.current(Storage.collection_location())
    {:ok, reading, html} = live(conn, ~p"/writing/#{saved.id}")

    assert has_element?(reading, "#reading-company")
    assert has_element?(reading, "#reading-company .door-title", "An earlier page")

    assert Enum.count(
             LazyHTML.query(LazyHTML.from_fragment(html), "#reading-company .door-title")
           ) ==
             1

    assert html =~ "&lt;b&gt;literal&lt;/b&gt;"
    refute has_element?(reading, "#reading-company b")
    assert has_element?(reading, "#follow-file-words[href='/threads?from=file%3A#{saved.id}']")
    assert has_element?(reading, "#file-text", "opal quartz orchard")

    {:ok, after_cursor} = Desk.current(Storage.collection_location())
    assert after_cursor == before_cursor
    assert Poems.get(Storage.collection_location(), saved.id) == {:ok, saved}
    assert {:ok, []} = Poems.revisions(Storage.collection_location(), saved.id)
    assert Writing.get_entry!(echo.id) == echo
  end

  test "a promoted historical file does not echo its own original", %{conn: conn} do
    source = historical("Original source", "cobalt zeppelin sprocket")
    {:ok, saved} = Poems.from_historical(Storage.collection_location(), source)

    {:ok, reading, _} = live(conn, ~p"/writing/#{saved.id}")

    refute has_element?(reading, "#reading-company")
    assert Writing.get_entry!(source.id) == source
    assert Poems.get(Storage.collection_location(), saved.id) == {:ok, saved}
  end

  test "weak matches leave no historical company section", %{conn: conn} do
    historical("A distant page", "cobalt zeppelin sprocket")
    {:ok, view, _} = live(conn, ~p"/writing/new")

    render_submit(element(view, "#file-writing-form"), %{
      "writing" => %{"title" => "Quiet page", "body" => "and the very small day"}
    })

    {:ok, [saved]} = Poems.list(Storage.collection_location())
    {:ok, reading, _} = live(conn, ~p"/writing/#{saved.id}")
    refute has_element?(reading, "#reading-company")
  end

  defp historical(title, body) do
    Repo.insert!(
      Entry.changeset(%Entry{}, %{
        origin: "before",
        title: title,
        body: body,
        notebook: "Early Notebooks/Lists 1",
        source_order: System.unique_integer([:positive]),
        source_key: Ecto.UUID.generate()
      })
    )
  end
end
