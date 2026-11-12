defmodule Still.Correspondence.CalendarImportTest do
  use Still.DataCase, async: false
  import Ecto.Query

  alias Still.Correspondence.{Calendar, CalendarImport}
  alias Still.{LocalRecord, Repo, Storage}

  setup do
    root = Path.join(System.tmp_dir!(), "still-calendar-#{System.unique_integer([:positive])}")
    folder = Path.join(root, "collection")
    File.mkdir_p!(folder)
    old_state = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    assert {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      if old_state,
        do: Application.put_env(:still, :storage_state_directory, old_state),
        else: Application.delete_env(:still, :storage_state_directory)

      File.rm_rf!(root)
    end)

    %{location: Storage.collection_location()}
  end

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        "external_id" => "reading-1",
        "title" => "Poetry reading",
        "date" => "2026-11-20",
        "category" => "reading"
      },
      overrides
    )
  end

  defp json(rows), do: Jason.encode!(rows)

  test "preview and commit add, update, and keep stable identities", %{location: location} do
    first = event()
    {:ok, preview} = CalendarImport.preview(location, json([first]))
    assert [%{attrs: attrs}] = preview.new
    assert attrs["external_id"] == first["external_id"]
    assert {:ok, %{added: 1, updated: 0, unchanged: 0}} = CalendarImport.commit(preview)
    {:ok, [saved]} = Calendar.list(location)
    assert saved.id
    assert saved.date == "2026-11-20"

    {:ok, same} = CalendarImport.preview(location, json([first]))
    assert length(same.unchanged) == 1
    assert {:ok, %{added: 0, updated: 0, unchanged: 1}} = CalendarImport.commit(same)

    changed = event(%{"title" => "Updated reading", "start_time" => "19:00"})
    {:ok, plan} = CalendarImport.preview(location, json([changed]))
    assert [%{previous: previous, id: id}] = plan.updated
    assert previous["title"] == "Poetry reading"
    assert {:ok, %{added: 0, updated: 1, unchanged: 0}} = CalendarImport.commit(plan)
    assert {:ok, updated} = Calendar.get(location, id)
    assert updated.title == "Updated reading"
  end

  test "rejects duplicate ids, unknown keys, invalid times, and invalid URLs" do
    assert {:error, _} = CalendarImport.parse(json([event(), event(%{"title" => "Second"})]))
    assert {:error, _} = CalendarImport.parse(json([event(%{"made_up" => "x"})]))
    assert {:error, _} = CalendarImport.parse(json([event(%{"end_time" => "12:00"})]))
    assert {:error, _} = CalendarImport.parse(json([event(%{"url" => "javascript:alert(1)"})]))
  end

  test "a reviewed update is rejected if its event changes before commit", %{location: location} do
    {:ok, create} = CalendarImport.preview(location, json([event()]))
    {:ok, _} = CalendarImport.commit(create)
    {:ok, plan} = CalendarImport.preview(location, json([event(%{"title" => "Revised"})]))
    [row] = plan.updated

    assert {:ok, _} =
             Calendar.save(location, event(%{"title" => "Manual change"}), row.id, row.token)

    assert {:error, _} = CalendarImport.commit(plan)
    {:ok, current} = Calendar.get(location, row.id)
    assert current.title == "Manual change"
  end

  test "recurring series remain one event and imports preserve local hidden state", %{
    location: location
  } do
    recurring =
      event(%{
        "recurrence" => %{
          "frequency" => "weekly",
          "interval" => 1,
          "until" => "2027-03-31",
          "excluded_dates" => ["2026-12-25"]
        }
      })

    {:ok, plan} = CalendarImport.preview(location, json([recurring]))
    {:ok, %{added: 1}} = CalendarImport.commit(plan)
    {:ok, [saved]} = Calendar.list(location)
    assert saved.recurrence["frequency"] == "weekly"
    assert {:ok, hidden} = Calendar.set_hidden(location, saved.id, saved.token, true)
    assert hidden.hidden
    {:ok, unchanged} = CalendarImport.preview(location, json([recurring]))
    assert length(unchanged.unchanged) == 1

    revised = Map.put(recurring, "title", "Revised recurring reading")
    {:ok, update} = CalendarImport.preview(location, json([revised]))
    assert {:ok, %{updated: 1}} = CalendarImport.commit(update)
    {:ok, [after_import]} = Calendar.list(location)
    assert after_import.id == saved.id
    assert after_import.hidden
    assert after_import.recurrence == saved.recurrence

    revisions =
      Repo.all(
        from row in LocalRecord, where: row.scope == ^location.scope and row.kind == "revision"
      )

    assert Enum.any?(revisions, &(&1.data["title"] == "Poetry reading"))
  end

  test "a collection switch invalidates a reviewed plan without partial writes", %{
    location: location
  } do
    {:ok, plan} = CalendarImport.preview(location, json([event()]))
    other = Path.join(Path.dirname(location.folder), "other-collection")
    File.mkdir_p!(other)
    assert {:ok, _} = Storage.set_folder(other)
    assert {:error, _} = CalendarImport.commit(plan)
    assert {:ok, _} = Storage.set_folder(location.folder)
    assert {:ok, []} = Calendar.list(location)
  end

  test "hidden dates survive changes and restoring one keeps the other", %{location: location} do
    event = event()
    {:ok, []} = Calendar.list(location)
    {:ok, saved} = Calendar.save(location, event)
    {:ok, first} = Calendar.set_hidden(location, saved.id, saved.token, true, "2026-11-27")
    {:ok, second} = Calendar.set_hidden(location, first.id, first.token, true, "2026-12-04")
    {:ok, same} = Calendar.set_hidden(location, second.id, second.token, true, "2026-12-04")
    assert same.token == second.token
    {:ok, restored} = Calendar.set_hidden(location, same.id, same.token, false, "2026-11-27")
    assert restored.hidden_dates == ["2026-12-04"]
  end

  test "manual saves reject duplicate external ids", %{location: location} do
    {:ok, _} = Calendar.save(location, event())
    assert {:error, _} = Calendar.save(location, event(%{"title" => "Different event"}))
  end

  test "saved revisions preserve pre-change event data", %{location: location} do
    {:ok, created} = Calendar.save(location, event())

    {:ok, _changed} =
      Calendar.save(location, event(%{"title" => "Changed"}), created.id, created.token)

    revisions =
      Repo.all(
        from row in LocalRecord, where: row.scope == ^location.scope and row.kind == "revision"
      )

    assert [%LocalRecord{data: previous}] = revisions
    assert previous["title"] == "Poetry reading"
  end

  test "decode rejects a mismatched internal id and non-four-digit dates" do
    id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()

    row = %LocalRecord{
      scope: "scope",
      kind: "calendar_event",
      record_key: id,
      lock_version: 1,
      data: %{"id" => other_id, "external_id" => "bad", "title" => "Bad", "date" => "12026-11-20"}
    }

    assert {:error, _} = Calendar.decode(row)
  end
end
