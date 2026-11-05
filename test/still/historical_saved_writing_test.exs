defmodule Still.HistoricalSavedWritingTest do
  use Still.DataCase
  alias Still.{Correspondence, Poems, Storage, Writing}

  @moduletag :tmp_dir
  setup %{tmp_dir: root} do
    old = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    collection = Path.join(root, "collection")
    File.mkdir_p!(collection)
    {:ok, _} = Storage.set_folder(collection)

    {:ok, entry} =
      insert_entry(%{
        origin: "before",
        source_key: "historical-synthetic-#{System.unique_integer([:positive])}",
        title: "The:Cedars:",
        body: "  Synthetic words\r\n\n\tbeside the path\n",
        notebook: "Early Notebooks/Lists 2",
        source: %{"artifacts" => [%{"path" => "private/import/14 Synthetic List.txt"}]}
      })

    on_exit(fn -> Application.put_env(:still, :storage_state_directory, old) end)
    %{location: Storage.collection_location(), entry: entry, collection: collection}
  end

  test "explicit addition preserves exact text and source; title and revisions belong only to the saved version",
       %{location: location, entry: entry} do
    before = Writing.get_entry!(entry.id)
    versions = Writing.list_versions(entry)
    assert {:ok, saved} = Writing.add_to_saved_writing(location, entry.id)
    assert saved.body == entry.title <> "\n\n" <> entry.body
    assert saved.title == entry.title
    assert File.read!(saved.path) == saved.body

    assert saved.historical_source == %{
             "kind" => "historical_list",
             "source_key" => entry.source_key,
             "title" => entry.title,
             "notebook" => entry.notebook,
             "source_number" => "14"
           }

    indexed = Still.Repo.get!(Still.Writing.Entry, saved.entry_id)
    refute Jason.encode!(indexed.source) =~ "private/import"
    refute File.exists?(Path.join(Path.dirname(saved.path), "metadata.json"))

    assert {:ok, edited} =
             Poems.save(location, saved, %{
               title: "The Cedars",
               body: "A revised poem\n\n  exact spaces"
             })

    assert edited.historical_source == saved.historical_source
    assert {:ok, same} = Writing.add_to_saved_writing(location, entry.id)
    assert same.id == saved.id
    assert same.title == "The Cedars"
    assert same.body == edited.body
    assert same.token == edited.token
    assert {:ok, [^same]} = Poems.list(location)
    assert {:ok, [revision]} = Poems.revisions(location, same.id)
    assert revision.body == saved.body
    assert revision.title == entry.title
    assert Writing.get_entry!(entry.id) == before
    assert Writing.list_versions(entry) == versions
    assert {:ok, %{pieces: [%{id: id}]}} = Correspondence.overview(location)
    assert id == same.id
  end

  test "source identity is stable across a restored database and concurrent repeated actions", %{
    location: location,
    entry: entry
  } do
    tasks =
      for _ <- 1..2,
          do: Task.async(fn -> Poems.from_historical(location, %{entry | id: entry.id + 500}) end)

    results = Enum.map(tasks, &Task.await/1)
    assert [{:ok, first}, {:ok, second}] = results
    assert first.id == second.id
    assert first.token == second.token
    assert {:ok, [piece]} = Poems.list(location)
    assert piece.id == first.id
  end

  test "Trash prevents a second copy and restore reconnects the same version", %{
    location: location,
    entry: entry
  } do
    {:ok, first} = Writing.add_to_saved_writing(location, entry.id)

    {:ok, edited} =
      Poems.save(location, first, %{title: "Personal title", body: "Keep these revisions"})

    {:ok, _} = Poems.trash(location, edited)
    assert {:error, message} = Writing.add_to_saved_writing(location, entry.id)
    assert message =~ "Trash"
    assert {:ok, []} = Poems.list(location)
    assert {:ok, restored} = Poems.restore(location, edited.id)
    assert {:ok, reopened} = Writing.add_to_saved_writing(location, entry.id)
    assert reopened == restored
  end

  test "unavailable folder and uncertain identity never substitute or overwrite", %{
    location: location,
    collection: folder,
    entry: entry
  } do
    {:ok, first} = Writing.add_to_saved_writing(location, entry.id)
    indexed = Still.Repo.get!(Still.Writing.Entry, first.entry_id)

    indexed
    |> Ecto.Changeset.change(source: Map.delete(indexed.source, "historical_source"))
    |> Still.Repo.update!()

    assert {:error, message} = Writing.add_to_saved_writing(location, entry.id)
    assert message =~ "different source"
    assert File.read!(first.path) == first.body
    File.rename!(folder, folder <> "-offline")
    assert {:error, _} = Writing.add_to_saved_writing(location, entry.id)
    refute File.exists?(folder)
    {:ok, _} = Storage.clear_folder()

    assert {:error, message} =
             Writing.add_to_saved_writing(Storage.collection_location(), entry.id)

    assert message =~ "Choose a collection folder"
  end

  test "newer entries and sources without stable identifiers cannot be promoted", %{
    location: location,
    entry: entry
  } do
    assert {:error, _} = Poems.from_historical(location, %{entry | origin: "now"})
    assert {:error, _} = Poems.from_historical(location, %{entry | source_key: nil})
    assert {:ok, []} = Poems.list(location)
  end

  defp insert_entry(attrs),
    do: Still.Repo.insert(Writing.change_entry(Writing.new_entry(), attrs))
end
