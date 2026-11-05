defmodule Still.Writing.ReadingPlaceTest do
  use Still.DataCase, async: false

  alias Still.{LocalRecord, Repo, Storage}
  alias Still.Writing.{ReadingPath, ReadingPlace, Version}

  test "normalizes reader state and retains its independent Find anchor" do
    {:ok, entry} = Still.Writing.save_entry(nil, "A heron", title: "Heron")
    version = Repo.insert!(%Version{entry_id: entry.id, body: "Earlier heron"})

    assert {:ok, saved} =
             ReadingPlace.remember(entry, %{
               "from" => "find",
               "q" => "  HERON   wing ",
               "earlier" => "true",
               "written" => "1",
               "shown" => "121",
               "at" => "version-#{version.id}",
               "version" => to_string(version.id)
             })

    assert saved.context == %{
             "from" => "find",
             "notebook" => nil,
             "q" => "HERON   wing",
             "earlier" => true,
             "written" => true,
             "shown" => 160,
             "at" => "version-#{version.id}",
             "version" => version.id
           }

    {:ok, current_writing} = Still.Writing.save_entry(nil, "Current words")
    Still.Writing.remember_writing(current_writing)
    ReadingPath.visit(entry, query: "unrelated")
    assert ReadingPlace.last().entry.id == entry.id
    assert ReadingPlace.last().context["q"] == "HERON   wing"
    assert Still.Writing.current_writing().id == current_writing.id

    next_context = ReadingPlace.context(current_writing, %{"at" => "current-#{entry.id}"})
    assert next_context["at"] == "current-#{entry.id}"

    row =
      Repo.get_by!(LocalRecord,
        scope: Storage.collection_location().scope,
        kind: "reading_place",
        record_key: "last"
      )

    refute inspect(row.data) =~ "A heron"
    refute inspect(row.data) =~ "Current words"
    assert row.bytes == nil
  end

  test "notebook bookmarks are separate, and malformed or stale versions fail closed" do
    {:ok, entry} = Still.Writing.save_entry(nil, "From the old notebook")

    entry =
      entry
      |> Ecto.Changeset.change(origin: "before", notebook: "Early Notebooks/Lists 2")
      |> Repo.update!()

    assert {:ok, _} =
             ReadingPlace.remember(entry, %{"from" => "notebook", "q" => "list", "shown" => 0})

    bookmark = ReadingPlace.for_notebook("Early Notebooks/Lists 2")
    assert bookmark.entry.id == entry.id
    assert bookmark.context["notebook"] == "Early Notebooks/Lists 2"
    assert bookmark.context["shown"] == 40

    {:ok, other} = Still.Writing.save_entry(nil, "Unrelated entry")
    bogus = Repo.insert!(%Version{entry_id: other.id, body: "unrelated"})

    assert ReadingPlace.context(entry, %{"version" => bogus.id, "at" => "version-#{bogus.id}"})[
             "version"
           ] == nil

    assert ReadingPlace.context(entry, %{"at" => "https://elsewhere/#unsafe"})["at"] ==
             "current-#{entry.id}"

    row =
      Repo.get_by!(LocalRecord,
        scope: Storage.collection_location().scope,
        kind: "reading_place",
        record_key: "last"
      )

    Repo.update!(LocalRecord.changeset(row, %{data: %{"entry_id" => "broken", "context" => %{}}}))
    assert ReadingPlace.last() == nil
  end

  test "bookmarks reject entries that are missing, trashed, or externally scoped" do
    {:ok, entry} = Still.Writing.save_entry(nil, "Temporary")

    assert {:ok, _} = ReadingPlace.remember(entry)
    assert ReadingPlace.last().entry.id == entry.id

    missing = entry |> Ecto.Changeset.change(file_missing: true) |> Repo.update!()
    assert ReadingPlace.last() == nil
    Repo.update!(Ecto.Changeset.change(missing, file_missing: false, trashed: true))
    assert ReadingPlace.last() == nil

    file_entry =
      entry
      |> Ecto.Changeset.change(
        file_id: Ecto.UUID.generate(),
        collection_scope: "other",
        file_missing: false
      )
      |> Repo.update!()

    assert {:error, _} = ReadingPlace.remember(file_entry)
    assert ReadingPlace.last() == nil
  end
end
