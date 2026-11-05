defmodule StillWeb.EntryLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Repo, Writing}
  alias Still.Writing.Entry

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    on_exit(fn -> Application.put_env(:still, :storage_state_directory, previous) end)
    :ok
  end

  test "an imported historical entry remains editable with its title, words and revision", %{
    conn: conn
  } do
    entry = historical_entry()
    original_title = entry.title
    original_body = entry.body
    {:ok, view, html} = live(conn, ~p"/w/#{entry.id}")
    assert html =~ "Imported words"
    assert html =~ "with their spacing"
    refute has_element?(view, "#writing-form")
    assert has_element?(view, "#copy-entry-reading button[aria-label='Copy text']")

    [payload] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#copy-entry-reading")
      |> LazyHTML.attribute("data-persisted")

    assert %{"body" => ^original_body, "title" => ^original_title, "title_source" => "explicit"} =
             Jason.decode!(payload)

    element(view, "button", "Change these words") |> render_click()

    assert has_element?(
             view,
             "#copy-entry-edit[data-body-selector='#writing-body'][data-title-selector='#writing-title']"
           )

    revised_title = "A returned title"
    revised_body = "A changed thought\n\tkept with its branch"

    render_submit(element(view, "#writing-form"), %{
      "entry" => %{"title" => revised_title, "body" => revised_body}
    })

    saved = Writing.get_entry!(entry.id)
    assert saved.title == revised_title
    assert saved.body == revised_body
    assert saved.returned_at

    assert [%{title: ^original_title, body: ^original_body} = version] =
             Writing.list_versions(saved)

    {:ok, earlier, _} = live(conn, ~p"/w/#{saved.id}?read=1&version=#{version.id}")
    assert has_element?(earlier, "#copy-entry-version button[aria-label='Copy text']")

    [payload] =
      earlier
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#copy-entry-version")
      |> LazyHTML.attribute("data-persisted")

    assert %{"body" => ^original_body, "title" => ^original_title} = Jason.decode!(payload)
  end

  test "opening the new Now page does not create a historical database entry", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#file-writing-form")

    render_change(element(view, "#file-writing-form"), %{
      "writing" => %{"title" => "Draft title", "body" => "Unfiled words"}
    })

    assert Repo.all(Entry) == []
    refute has_element?(view, "#writing-form")
  end

  defp historical_entry do
    %Entry{}
    |> Entry.changeset(%{
      origin: "before",
      title: "An imported title",
      body: "Imported words\n\twith their spacing",
      notebook: "Early Notebooks/Lists 1",
      source_order: 1,
      source_key: Ecto.UUID.generate()
    })
    |> Repo.insert!()
  end
end
