defmodule Still.Correspondence.CalendarUpcomingTest do
  use Still.DataCase, async: false

  alias Still.Correspondence.Calendar
  alias Still.Storage

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "still-calendar-upcoming-#{System.unique_integer([:positive])}"
      )

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

  defp add(location, id, date, attrs \\ %{}) do
    values =
      Map.merge(
        %{"external_id" => id, "title" => id, "date" => date, "category" => "other"},
        attrs
      )

    {:ok, event} = Calendar.save(location, values)
    event
  end

  test "returns visible upcoming occurrences in order, including ongoing and distant one-offs", %{
    location: location
  } do
    today = ~D[2026-11-12]
    add(location, "ongoing", "2026-11-10", %{"end_date" => "2026-11-13", "start_time" => "09:00"})

    recurring =
      add(location, "daily", "2026-11-12", %{
        "start_time" => "10:00",
        "recurrence" => %{"frequency" => "daily", "interval" => 1, "until" => "2026-11-14"},
        "hidden_dates" => ["2026-11-12"]
      })

    add(location, "cancelled", "2026-11-12", %{"status" => "cancelled"})
    hidden = add(location, "hidden", "2026-11-12", %{"recurrence" => %{"frequency" => "daily"}})
    {:ok, _hidden} = Calendar.set_hidden(location, hidden.id, hidden.token, true)
    add(location, "tomorrow", "2026-11-13", %{"start_time" => "08:00"})
    add(location, "distant", "2027-12-01")

    {:ok, [ongoing, tomorrow, daily]} = Calendar.upcoming(location, today, 3)
    assert {ongoing.title, ongoing.date} == {"ongoing", "2026-11-10"}
    assert {tomorrow.title, tomorrow.date} == {"tomorrow", "2026-11-13"}
    assert {daily.title, daily.date, daily.hidden} == {"daily", "2026-11-13", false}

    {:ok, all} = Calendar.upcoming(location, today, 10)
    assert Enum.any?(all, &(&1.title == "distant"))
    refute Enum.any?(all, &(&1.title in ["cancelled", "hidden"]))
    {:ok, after_query} = Calendar.get(location, recurring.id)
    assert after_query.token == recurring.token
    assert after_query.hidden_dates == ["2026-11-12"]
  end

  test "bounds the requested count and returns no rows for an empty collection", %{
    location: location
  } do
    assert {:ok, []} = Calendar.upcoming(location, ~D[2026-11-12])
    assert {:error, _} = Calendar.upcoming(location, ~D[2026-11-12], 11)
    assert {:error, _} = Calendar.upcoming(location, "2026-11-12")
  end
end
