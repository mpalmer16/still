defmodule StillWeb.SavedWritingQueryBudgetTest do
  use StillWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Ecto.Changeset
  alias Still.{Poems, Repo, Storage}
  alias Still.Writing.Entry

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    on_exit(fn -> Application.put_env(:still, :storage_state_directory, previous) end)

    folder = Path.join(root, "collection")
    File.mkdir_p!(folder)
    assert {:ok, _} = Storage.set_folder(folder)
    %{folder: folder, location: Storage.collection_location()}
  end

  test "each Saved writing refresh reconciles once and sees the next external edit", %{
    conn: conn,
    folder: folder
  } do
    File.write!(Path.join(folder, "one.txt"), "Earlier words")
    {:ok, view, _} = live(conn, ~p"/writing")
    assert has_element?(view, ".file-opening", "Earlier words")

    transactions = :atomics.new(1, [])
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:still, :repo, :query],
        fn _, _, metadata, counter ->
          if String.match?(to_string(metadata[:query] || ""), ~r/^\s*begin\b/i),
            do: :atomics.add(counter, 1, 1)
        end,
        transactions
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    view |> element("#refresh-writing") |> render_click()
    assert :atomics.get(transactions, 1) == 1

    File.write!(Path.join(folder, "one.txt"), "Current external words")
    :atomics.put(transactions, 1, 0)
    view |> element("#refresh-writing") |> render_click()
    assert :atomics.get(transactions, 1) == 1
    assert has_element?(view, ".file-opening", "Current external words")
    refute has_element?(view, ".file-opening", "Earlier words")
  end

  test "a pending save conflict still shows both sets of words", %{
    conn: conn,
    location: location
  } do
    assert {:ok, piece} = Poems.save(location, Poems.new(location), %{body: "Earlier words"})
    entry = Repo.get_by!(Entry, file_id: piece.id)
    File.write!(piece.path, "External words")

    pending = %{
      "kind" => "save",
      "old_token" => entry.file_token,
      "body" => "Still's proposed words",
      "prefix" => Base.encode64(""),
      "title_line" => nil,
      "title_anchor" => nil,
      "metadata" => %{
        "notebook_id" => nil,
        "notebook" => nil,
        "source_order" => nil,
        "list_label" => nil
      }
    }

    entry |> Changeset.change(pending: pending) |> Repo.update!()

    {:ok, view, _} = live(conn, ~p"/writing")
    assert has_element?(view, "#pending-review-#{piece.id}", "External words")
    assert has_element?(view, "#pending-review-#{piece.id}", "Still's proposed words")
    assert has_element?(view, "#writing-problem", "interrupted save conflicts")
    assert File.read!(piece.path) == "External words"
    assert Repo.get!(Entry, entry.id).pending == pending
  end

  test "missing files reappearing at the same path wait for a writer's choice", %{
    conn: conn,
    folder: folder,
    location: location
  } do
    equal_path = Path.join(folder, "equal.txt")
    changed_path = Path.join(folder, "changed.txt")
    File.write!(equal_path, "Equal original words")
    File.write!(changed_path, "Earlier changed words")
    assert {:ok, originals} = Poems.list(location)
    equal = Enum.find(originals, &(&1.relative_path == "equal.txt"))
    changed = Enum.find(originals, &(&1.relative_path == "changed.txt"))

    File.rm!(equal_path)
    File.rm!(changed_path)
    assert {:ok, []} = Poems.list(location)

    equal_replacement = Path.join(Path.dirname(folder), "equal-replacement")
    changed_replacement = Path.join(Path.dirname(folder), "changed-replacement")
    File.write!(equal_replacement, "Equal original words")
    File.write!(changed_replacement, "Current changed words")
    File.rename!(equal_replacement, equal_path)
    File.rename!(changed_replacement, changed_path)

    {:ok, view, _} = live(conn, ~p"/writing")
    assert has_element?(view, "#missing-file-#{equal.id}", "Location needs confirmation")
    assert has_element?(view, "#missing-file-#{changed.id}", "Location needs confirmation")
    assert has_element?(view, "#ambiguous-file-#{equal.id} option[value='equal.txt']")
    refute has_element?(view, "#ambiguous-file-#{changed.id}")
    refute has_element?(view, "#saved-#{equal.id}")
    refute has_element?(view, "#saved-#{changed.id}")

    view
    |> form("#missing-file-#{equal.id} form", piece_id: equal.id, path: "equal.txt")
    |> render_submit()

    view
    |> form("#missing-file-#{changed.id} form", piece_id: changed.id, path: "changed.txt")
    |> render_submit()

    assert has_element?(view, "#saved-#{equal.id}")
    assert has_element?(view, "#saved-#{changed.id}")
    assert {:ok, [%{body: "Earlier changed words"}]} = Poems.revisions(location, changed.id)
    assert File.read!(equal_path) == "Equal original words"
    assert File.read!(changed_path) == "Current changed words"
  end
end
