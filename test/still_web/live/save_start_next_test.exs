defmodule StillWeb.SaveStartNextLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Poems, Storage}
  alias Still.Writing.{Files, Notebooks}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    old_state = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "collection")
    File.mkdir_p!(folder)
    assert {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      if old_state,
        do: Application.put_env(:still, :storage_state_directory, old_state),
        else: Application.delete_env(:still, :storage_state_directory)
    end)

    %{folder: folder, location: Storage.collection_location()}
  end

  test "Save & start next preserves the source and opens a blank page in its section", %{
    conn: conn,
    folder: folder,
    location: location
  } do
    {:ok, source_book} = Files.create_folder(location, "Field book A", %{label: "Field book A"})
    {:ok, other_book} = Files.create_folder(location, "Field book B", %{label: "Field book B"})
    {:ok, _} = Notebooks.choose_current(other_book.id)

    section_path = "Field book A/April - June"
    File.mkdir_p!(Path.join(folder, section_path))

    source_body = "Source title\nOriginal words\n"
    source_path = Path.join(section_path, "12_Source.txt")

    {:ok, source} =
      Poems.save(location, Poems.new(location), %{
        body: source_body,
        title: "An explicit title",
        title_source: "explicit",
        title_line: 1,
        notebook_id: source_book.id,
        list_label: "12b",
        source_order: 12,
        relative_path: source_path
      })

    source_bytes = File.read!(source.path)
    edit_path = "/writing/#{source.id}/edit"
    {:ok, editor, _} = live(conn, edit_path)

    assert has_element?(
             editor,
             "#save-start-next[form='file-writing-form'][name='start_next'][value='true']"
           )

    assert has_element?(editor, "#save-return-notebook")

    revised = source_body <> "Saved before starting the next page.\n"

    render_submit(element(editor, "#file-writing-form"), %{
      "writing" => %{"body" => revised},
      "start_next" => "true"
    })

    assert {:ok, saved_source} = Poems.get(location, source.id)
    assert saved_source.body == revised
    next_path = "/?after=#{source.id}&token=#{saved_source.token}"
    assert_redirect(editor, next_path)
    assert saved_source.relative_path == source_path
    assert File.read!(source.path) == revised
    refute File.read!(source.path) == source_bytes

    {:ok, next, _} = live(conn, next_path)
    assert has_element?(next, "#file-writing-body[data-resume-active='false']")
    assert has_element?(next, "#file-writing-body")
    assert has_element?(next, "#next-list-destination", "Field book A")
    assert has_element?(next, "#next-list-destination", "April - June")
    assert has_element?(next, "#next-list-destination", "Next List 13")
    assert has_element?(next, "#file-relative-path[name='writing[relative_path]']")

    assert has_element?(
             next,
             "input[name='writing[destination_folder]'][value='Field book A/April - June']"
           )

    [persisted] =
      next
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#file-writing-body")
      |> LazyHTML.attribute("data-persisted")

    draft_state = Jason.decode!(persisted)
    assert draft_state["body"] == ""
    assert draft_state["title_line"] in [nil, ""]
    assert draft_state["list_label"] in [nil, ""]
    assert draft_state["source_order"] in [nil, ""]
    assert draft_state["relative_path"] in [nil, ""]

    assert {:ok, pieces} = Files.list(location)
    assert Enum.count(pieces) == 1

    render_submit(element(next, "#file-writing-form"), %{
      "writing" => %{
        "body" => "Next page words",
        "destination_folder" => section_path
      }
    })

    assert {:ok, pieces} = Files.list(location)
    continuation = Enum.find(pieces, &(&1.id != source.id))
    assert continuation
    assert continuation.body == "Next page words"
    assert continuation.notebook_id == source_book.id
    assert continuation.relative_path =~ ~r{^Field book A/April - June/}
    assert continuation.list_label == "13"
    assert is_nil(continuation.title)
    assert is_nil(continuation.title_line)
    assert continuation.source_order == 13
    assert saved_source.body == revised
  end

  test "continuing an Unplaced piece stays Unplaced without assigning a number", %{
    conn: conn,
    location: location
  } do
    {:ok, notebook} =
      Files.create_folder(location, "Field book Unplaced", %{label: "Field book Unplaced"})

    {:ok, source} =
      Files.save_to_unplaced(location, Files.new(location), %{
        body: "Unplaced source",
        notebook_id: notebook.id
      })

    {:ok, editor, _} = live(conn, "/writing/#{source.id}/edit")

    render_submit(element(editor, "#file-writing-form"), %{
      "writing" => %{"body" => "Updated Unplaced source"},
      "start_next" => "true"
    })

    assert {:ok, updated_source} = Poems.get(location, source.id)
    next_path = "/?after=#{source.id}&token=#{updated_source.token}"
    assert_redirect(editor, next_path)
    {:ok, next, _} = live(conn, next_path)
    assert has_element?(next, "#next-list-destination", "Unplaced")
    assert has_element?(next, "#next-list-destination", "Not yet numbered")

    render_submit(element(next, "#file-writing-form"), %{
      "writing" => %{"body" => "Another Unplaced page"},
      "start_next" => "true"
    })

    {:ok, pieces} = Files.list(location)
    continuation = Enum.find(pieces, &(&1.body == "Another Unplaced page"))
    second_path = "/?after=#{continuation.id}&token=#{continuation.token}"
    assert_redirect(next, second_path)
    {:ok, final_next, _} = live(conn, second_path)
    assert has_element?(final_next, "#next-list-destination", "Unplaced")
    assert has_element?(final_next, "#next-list-destination", "Not yet numbered")

    render_submit(element(final_next, "#file-writing-form"), %{
      "writing" => %{"body" => "One more Unplaced page"}
    })

    assert {:ok, pieces} = Files.list(location)
    assert Enum.all?(pieces, &is_nil(&1.list_label))
    assert Enum.all?(pieces, & &1.unplaced)
  end

  test "a stale source keeps the proposed words and does not open a continuation", %{
    conn: conn,
    location: location
  } do
    {:ok, source} = Poems.save(location, Poems.new(location), %{body: "Original source"})
    {:ok, editor, _} = live(conn, "/writing/#{source.id}/edit")
    File.write!(source.path, "Changed outside Still")

    render_submit(element(editor, "#file-writing-form"), %{
      "writing" => %{"body" => "Latest proposed words"},
      "start_next" => "true"
    })

    assert has_element?(editor, "#file-problem")

    assert has_element?(
             editor,
             "#file-writing-form[data-save-blocked='true'][data-unsaved='true']"
           )

    assert File.read!(source.path) == "Changed outside Still"
    assert {:ok, unchanged} = Poems.get(location, source.id)
    refute unchanged.body == "Latest proposed words"
  end

  test "an invalid continuation identity or token does not become an ordinary blank page", %{
    conn: conn,
    location: location
  } do
    {:ok, source} = Poems.save(location, Poems.new(location), %{body: "Protected source"})

    for path <- [
          "/?after=#{Ecto.UUID.generate()}&token=#{source.token}",
          "/?after=#{source.id}&token=wrong-token",
          "/?after=#{source.id}"
        ] do
      {:ok, view, _} = live(conn, path)
      assert has_element?(view, "#file-problem")
      assert {:ok, unchanged} = Poems.get(location, source.id)
      assert unchanged.body == "Protected source"
      assert {:ok, pieces} = Files.list(location)
      assert length(pieces) == 1
    end
  end
end
