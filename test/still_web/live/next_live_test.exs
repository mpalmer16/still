defmodule StillWeb.NextLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Next, Poems, Storage}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "writing")
    File.mkdir_p!(folder)
    assert {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:still, :storage_state_directory, previous),
        else: Application.delete_env(:still, :storage_state_directory)
    end)

    %{location: Storage.collection_location()}
  end

  test "quick capture saves an undated item without opening details", %{
    conn: conn,
    location: location
  } do
    {:ok, view, _} = live(conn, ~p"/correspondence/next")

    render_submit(element(view, "#next-capture"), %{"capture" => %{"title" => "Call the printer"}})

    assert has_element?(view, "#next-table a.next-item-title", "Call the printer")
    assert {:ok, [task]} = Next.list(location)
    assert task.title == "Call the printer"
    assert task.notes == ""
    assert task.planned_on == nil
    assert task.due_on == nil
  end

  test "an item can be planned for today, completed, and reopened from history", %{
    conn: conn,
    location: location
  } do
    {:ok, item} = Next.save(location, %{"title" => "Read the draft"})
    {:ok, view, _} = live(conn, ~p"/correspondence/next")
    render_click(element(view, "#next-#{item.id} button.next-plan-today"))
    assert has_element?(view, "#next-#{item.id} td:nth-child(2) time", "Today")

    render_click(element(view, "#next-#{item.id} button.next-check"))
    render_click(element(view, "nav[aria-label='Item views'] a", "History"))
    assert has_element?(view, "#next-#{item.id}[data-status='done']")
    assert has_element?(view, "#next-#{item.id}", "Completed")
    render_click(element(view, "#next-#{item.id} button.next-check"))
    render_click(element(view, "nav[aria-label='Item views'] a", "Open"))
    assert has_element?(view, "#next-#{item.id}[data-status='open']")
  end

  test "the detail form saves notes and both optional dates", %{conn: conn, location: location} do
    {:ok, view, _} = live(conn, ~p"/correspondence/next")

    render_submit(element(view, "#next-capture"), %{
      "capture" => %{"title" => "Prepare a reading", "details" => "true"}
    })

    assert has_element?(view, "#next-editor input[value='Prepare a reading']")

    render_submit(element(view, "#next-editor"), %{
      "task" => %{
        "title" => "Prepare a reading",
        "notes" => "Bring the blue notebook",
        "planned_on" => Date.to_iso8601(Next.today()),
        "due_on" => Date.to_iso8601(Date.add(Next.today(), 2))
      }
    })

    assert {:ok, [task]} = Next.list(location)
    assert task.title == "Prepare a reading"
    assert task.notes == "Bring the blue notebook"
    assert task.planned_on == Next.today()
    assert task.due_on == Date.add(Next.today(), 2)
  end

  test "a stale second view cannot overwrite a newer edit", %{conn: conn, location: location} do
    {:ok, task} = Next.save(location, %{"title" => "Original", "notes" => "Earlier words"})
    {:ok, first, _} = live(conn, ~p"/correspondence/next?edit=#{task.id}")
    {:ok, second, _} = live(conn, ~p"/correspondence/next?edit=#{task.id}")

    render_submit(element(first, "#next-editor"), %{
      "task" => %{"title" => "Newer title", "notes" => "Newer notes"}
    })

    render_submit(element(second, "#next-editor"), %{
      "task" => %{"title" => "Stale title", "notes" => "Stale notes"}
    })

    assert has_element?(second, "#next-page [role='alert']", "changed in another view")
    assert {:ok, [saved]} = Next.list(location)
    assert saved.title == "Newer title"
    assert saved.notes == "Newer notes"
  end

  test "a work and its linked item remain connected after a file rename", %{
    conn: conn,
    location: location
  } do
    {:ok, piece} = Poems.save(location, Poems.new(location), %{body: "A small poem"})
    {:ok, work, _} = live(conn, ~p"/correspondence/writing/#{piece.id}")
    add = ~p"/correspondence/next?#{%{from: "piece", ref: piece.id}}"

    {:ok, view, _} =
      work |> element(".corr-next-add") |> render_click() |> follow_redirect(conn, add)

    assert has_element?(view, "#next-editor .next-source", "Work")

    render_submit(element(view, "#next-editor"), %{
      "task" => %{"title" => "Revise this poem", "notes" => "Keep the last line"}
    })

    assert {:ok, [task]} = Next.list(location)
    assert task.target == %{type: "piece", id: piece.id}

    assert {:ok, renamed} = Poems.rename(location, piece, "Renamed work.txt")
    assert renamed.id == piece.id

    render_click(element(view, "#next-#{task.id} a.next-item-title"))
    assert has_element?(view, "a[href='/correspondence/writing/#{piece.id}']")
    assert has_element?(view, "#next-editor .next-source a", Poems.display_title(renamed))

    {:ok, work, _} = live(conn, ~p"/correspondence/writing/#{piece.id}")
    assert has_element?(work, ".corr-next-links a", "Revise this poem")
  end

  test "a calendar day opens the detail form and shows the saved plan", %{conn: conn} do
    date = Date.add(Next.today(), 3)
    day = Date.to_iso8601(date)
    {:ok, calendar, _} = live(conn, ~p"/correspondence/calendar?date=#{day}")

    {:ok, view, _} =
      calendar
      |> element(".corr-calendar-add-task")
      |> render_click()
      |> follow_redirect(conn, ~p"/correspondence/next?on=#{day}")

    assert has_element?(
             view,
             "#next-editor input[name='task[planned_on]'][value='#{day}']"
           )

    view
    |> element("#next-editor")
    |> render_submit(%{"task" => %{"title" => "Draft a letter", "planned_on" => day}})

    {:ok, calendar, _} = live(conn, ~p"/correspondence/calendar?date=#{day}")
    assert has_element?(calendar, ".corr-calendar-day[data-date='#{day}'] a", "Draft a letter")

    {:ok, editor, _} =
      calendar
      |> element(".corr-calendar-day-tasks a", "Draft a letter")
      |> render_click()
      |> follow_redirect(conn)

    assert has_element?(editor, "#next-editor input[value='Draft a letter']")
  end

  test "Next appears only in Correspondence navigation", %{conn: conn} do
    {:ok, writing, _} = live(conn, ~p"/")
    refute has_element?(writing, "nav[aria-label='Main navigation'] a", "Next")

    {:ok, view, _} = live(conn, ~p"/correspondence/next")

    refute has_element?(view, "nav[aria-label='Main navigation']")
    assert has_element?(view, "nav[aria-label='Correspondence'] a[aria-current='page']", "Next")
    assert has_element?(view, "a#back-to-still[href='/']")
  end

  test "legacy Next URLs redirect to the directory and preserve edit parameters", %{
    conn: conn,
    location: location
  } do
    {:ok, task} = Next.save(location, %{"title" => "Open this task"})

    legacy_path = ~p"/next?edit=#{task.id}"
    path = ~p"/correspondence/next?edit=#{task.id}"
    assert conn |> get(legacy_path) |> redirected_to() == path

    {:ok, view, _} = live(conn, path)
    assert has_element?(view, "#next-editor input[value='Open this task']")
  end

  test "directory navigation, search, and sort work with the table", %{
    conn: conn,
    location: location
  } do
    {:ok, _} = Next.save(location, %{"title" => "Apple notes"})
    {:ok, _} = Next.save(location, %{"title" => "Zebra notes"})
    {:ok, view, _} = live(conn, ~p"/correspondence/next")

    assert has_element?(view, "#next-table")
    assert has_element?(view, "#next-capture")
    assert has_element?(view, "#next-filters input[name='q']")
    assert has_element?(view, "#next-filters select[name='source']")
    assert has_element?(view, "#next-table", "Item")
    assert has_element?(view, "#next-table", "Plan")
    assert has_element?(view, "#next-table", "Deadline")
    assert has_element?(view, "nav[aria-label='Item views'] a", "Open")
    assert has_element?(view, "nav[aria-label='Item views'] a", "Today")
    assert has_element?(view, "nav[aria-label='Item views'] a", "Upcoming")
    assert has_element?(view, "nav[aria-label='Item views'] a", "History")

    assert has_element?(view, "#next-table a[href*='sort=plan']", "Plan")
    assert has_element?(view, "#next-table a[href*='sort=deadline']", "Deadline")
    assert has_element?(view, "#next-items tr:first-child a.next-item-title", "Zebra notes")

    render_click(element(view, "#next-table a[href*='sort=title']"))
    assert has_element?(view, "#next-table th[aria-sort=ascending]", "Item")
    assert has_element?(view, "#next-items tr:first-child a.next-item-title", "Apple notes")

    render_click(element(view, "#next-table a[href*='sort=title'][href*='dir=desc']"))
    assert has_element?(view, "#next-table th[aria-sort=descending]", "Item")
    assert has_element?(view, "#next-items tr:first-child a.next-item-title", "Zebra notes")

    render_change(element(view, "#next-filters"), %{"q" => "Zebra"})
    assert has_element?(view, "#next-table", "Zebra notes")
    refute has_element?(view, "#next-table", "Apple notes")
    render_change(element(view, "#next-filters"), %{"q" => "", "source" => "event"})
    assert has_element?(view, "#next-table", "No items match these filters.")
  end
end
