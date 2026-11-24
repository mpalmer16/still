defmodule Still.NextTest do
  use Still.DataCase, async: false

  alias Still.{Storage, Next}

  setup do
    root = Path.join(System.tmp_dir!(), "still-next-#{System.unique_integer([:positive])}")
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

    %{location: Storage.collection_location(), root: root}
  end

  test "capture needs no dates and saves exact title and notes", %{location: location} do
    assert {:ok, task} =
             Next.save(location, %{"title" => "Call the printer", "notes" => "Ask about paper"})

    assert task.title == "Call the printer"
    assert task.notes == "Ask about paper"
    assert task.planned_on == nil
    assert task.due_on == nil
    assert task.status == :open
    assert task.revision == 1
    assert {:ok, [listed]} = Next.list(location)
    assert listed.id == task.id
  end

  test "Open puts newly added items first across the minute boundary", %{location: location} do
    {:ok, first} = Next.save(location, %{"title" => "First capture"})
    {:ok, second} = Next.save(location, %{"title" => "Second capture"})

    first = %{first | inserted_at: ~U[2026-11-18 10:08:59.900000Z]}
    second = %{second | inserted_at: ~U[2026-11-18 10:09:00.010000Z]}

    assert Next.view([first, second], "open", ~D[2026-11-18]) == [second, first]
  end

  test "plans and real deadlines remain distinct in dated views", %{location: location} do
    today = ~D[2026-11-18]

    {:ok, past_plan} =
      Next.save(location, %{"title" => "Old plan", "planned_on" => "2026-11-10"})

    {:ok, overdue} = Next.save(location, %{"title" => "Late deadline", "due_on" => "2026-11-10"})

    {:ok, future} =
      Next.save(location, %{"title" => "Future plan", "planned_on" => "2026-11-20"})

    {:ok, both} =
      Next.save(location, %{
        "title" => "Plan and deadline",
        "planned_on" => "2026-11-20",
        "due_on" => "2026-11-20"
      })

    tasks = [past_plan, overdue, future, both]

    assert Enum.map(Next.view(tasks, "today", today), & &1.id) |> Enum.sort() ==
             Enum.map([past_plan, overdue], & &1.id) |> Enum.sort()

    assert Enum.map(Next.view(tasks, "upcoming", today), & &1.id) |> Enum.sort() ==
             Enum.map([future, both], & &1.id) |> Enum.sort()

    entries = Next.calendar_entries(tasks)
    assert length(entries) == 4

    assert Enum.find(entries, &(&1.id == both.id)) == %{
             id: both.id,
             title: both.title,
             date: "2026-11-20",
             kind: "planned_and_due"
           }

    assert Enum.any?(
             entries,
             &(&1.id == past_plan.id and &1.kind == "planned" and &1.date == "2026-11-10")
           )

    assert Enum.any?(
             entries,
             &(&1.id == overdue.id and &1.kind == "due" and &1.date == "2026-11-10")
           )
  end

  test "completion, archive, and reopen preserve history", %{location: location} do
    {:ok, task} = Next.save(location, %{"title" => "Send the note", "notes" => "First draft"})
    assert {:ok, done} = Next.set_status(location, task, :done)
    assert done.status == :done
    assert {:ok, archived} = Next.set_status(location, done, :archived)
    assert archived.status == :archived
    assert {:ok, reopened} = Next.set_status(location, archived, :open)
    assert reopened.status == :open
    assert {:ok, history} = Next.history(location, reopened)
    assert Enum.any?(history, &(&1.status == :done))
    assert Enum.any?(history, &(&1.status == :archived))
    assert Enum.any?(history, &(&1.status == :open))
    refute Enum.any?(history, &(&1.revision == reopened.revision))
  end

  test "stale edits are rejected and title and notes revisions are retained", %{
    location: location
  } do
    {:ok, original} = Next.save(location, %{"title" => "First title", "notes" => "First notes"})

    {:ok, revised} =
      Next.save(location, %{"title" => "Second title", "notes" => "Second notes"}, original)

    assert revised.revision > original.revision

    assert {:error, _} =
             Next.save(
               location,
               %{"title" => "Stale overwrite", "notes" => "Lost notes"},
               original
             )

    assert {:ok, history} = Next.history(location, revised)
    assert Enum.any?(history, &(&1.title == "First title" and &1.notes == "First notes"))
    refute Enum.any?(history, &(&1.title == "Second title" and &1.notes == "Second notes"))
    assert revised.title == "Second title"
    assert revised.notes == "Second notes"
  end

  test "task scope remains tied to its collection when storage switches", %{
    location: location,
    root: root
  } do
    {:ok, task} = Next.save(location, %{"title" => "Keep this local"})
    other = Path.join(root, "other-collection")
    File.mkdir_p!(other)
    assert {:ok, _} = Storage.set_folder(other)
    other_location = Storage.collection_location()
    assert {:ok, []} = Next.list(other_location)
    assert {:error, _} = Next.set_status(other_location, task, :done)
    assert {:ok, _} = Storage.set_folder(location.folder)
    assert {:ok, [persisted]} = Next.list(location)
    assert persisted.id == task.id
    assert persisted.status == :open
  end
end
