defmodule StillWeb.FundingLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.Correspondence.{Calendar, Funding}
  alias Still.Storage

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    folder = Path.join(root, "writing")
    File.mkdir_p!(folder)
    {:ok, _} = Storage.set_folder(folder)
    %{location: Storage.collection_location()}
  end

  test "Home defaults to 90 days and keeps far-off deadlines actionable by preparation date", %{
    conn: conn,
    location: location
  } do
    today = Still.Next.today()
    base = %{funder: "Arts Council", kind: "fellowship", benefit: "unrestricted"}

    {:ok, grant} =
      Funding.save(
        location,
        Map.merge(base, %{
          name: "Writing fellowship",
          priority: "pursue",
          prepare_on: to_string(today),
          deadline: today |> Date.add(150) |> to_string()
        })
      )

    {:ok, watched} =
      Funding.save(
        location,
        Map.merge(base, %{
          name: "A monitored fellowship",
          priority: "monitor",
          anticipated_window: "Anticipated in spring"
        })
      )

    {:ok, view, _} = live(conn, ~p"/correspondence")

    assert has_element?(view, "#correspondence-planning a[aria-current=true]", "90 days")

    assert has_element?(
             view,
             "#correspondence-planning a[href='/correspondence/funding/#{grant.id}']"
           )

    assert has_element?(
             view,
             "#correspondence-planning article",
             "Unrestricted financial support"
           )

    refute has_element?(view, "#correspondence-planning article", watched.name)
    assert {:ok, [%{funding_id: id}]} = Calendar.funding_entries(location)
    assert id == grant.id

    render_click(element(view, "#correspondence-planning a", "Show monitored"))
    assert has_element?(view, "#correspondence-planning article", "Anticipated in spring")

    render_click(element(view, "#correspondence-planning a", "30 days"))
    assert has_element?(view, "#correspondence-planning a[aria-current=true]", "30 days")
    assert has_element?(view, "#correspondence-planning article", watched.name)
  end

  test "downloads the schema and adds reviewed JSON with its highlight attached", %{
    conn: conn,
    location: location
  } do
    schema = get(conn, ~p"/correspondence/funding/schema")
    assert [disposition] = get_resp_header(schema, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ "funding-import.schema.json"

    assert %{
             "type" => "array",
             "items" => %{"properties" => %{"highlighted" => %{"type" => "boolean"}}}
           } =
             schema |> response(200) |> Jason.decode!()

    {:ok, view, _} = live(conn, ~p"/correspondence/funding")
    render_click(element(view, "a", "Import Funding"))
    assert_patch(view, ~p"/correspondence/funding/import")

    upload =
      file_input(view, "#funding-import-form", :funding, [
        %{
          name: "funding.json",
          content:
            Jason.encode!([
              %{
                name: "Harbour fellowship",
                funder: "Arts Council",
                kind: "fellowship",
                highlighted: true,
                notes: "<script>review first</script>"
              },
              %{name: "Harbour Fellowship", funder: "Arts Council", kind: "fellowship"}
            ]),
          type: "application/json"
        }
      ])

    render_upload(upload, "funding.json")
    render_submit(element(view, "#funding-import-form"))
    assert has_element?(view, "#funding-import-preview", "1 duplicates skipped")
    assert {:ok, []} = Funding.list(location)

    render_click(element(view, "#confirm-funding-import"))
    assert has_element?(view, "#funding-import-result", "Imported 1")
    assert {:ok, [opportunity]} = Funding.list(location)
    assert opportunity.highlighted

    render_click(element(view, "#funding-import-result a"))

    assert has_element?(
             view,
             "tr#funding-row-#{opportunity.id}.is-highlighted .funding-highlight-toggle[aria-pressed=true]"
           )

    render_change(element(view, "#funding-filters"), %{"funding" => %{"q" => "arts council"}})
    assert has_element?(view, "#funding-row-#{opportunity.id}", "Harbour fellowship")
    render_change(element(view, "#funding-filters"), %{"funding" => %{"q" => "different"}})
    refute has_element?(view, "#funding-row-#{opportunity.id}")

    render_click(element(view, "#funding-filters a", "Reset"))
    render_click(element(view, "#funding-row-#{opportunity.id} a", "Harbour fellowship"))
    assert has_element?(view, "textarea", "<script>review first</script>")
    refute has_element?(view, "script", "review first")

    assert has_element?(
             view,
             "#funding-form .funding-form-actions button[type=submit]",
             "Save opportunity"
           )

    assert has_element?(view, "#funding-form .funding-form-actions a", "Cancel")

    render_submit(element(view, "#funding-form"), %{"funding" => %{"highlighted" => "false"}})
    assert {:ok, %{highlighted: false}} = Funding.get(location, opportunity.id)
  end

  test "a funding row can be highlighted and cleared in place while filtered", %{
    conn: conn,
    location: location
  } do
    deadline = "2028-10-30"

    {:ok, opportunity} =
      Funding.save(location, %{
        name: "Harbour fellowship",
        funder: "Arts Council",
        kind: "fellowship",
        deadline: deadline,
        notes: "Keep these application notes."
      })

    {:ok, unstarred} =
      Funding.save(location, %{name: "Harbour grant", funder: "Arts Council", kind: "grant"})

    {:ok, view, _} = live(conn, ~p"/correspondence/funding?#{%{q: "Harbour"}}")
    row = "#funding-row-#{opportunity.id}"
    toggle = "#{row} .funding-highlight-toggle"

    assert has_element?(view, "#{toggle}[aria-pressed=false]")
    render_click(element(view, toggle))
    refute_patched(view)
    assert has_element?(view, "#funding-query[value=Harbour]")

    assert has_element?(
             view,
             "#{row}.is-highlighted .funding-highlight-toggle[aria-pressed=true]"
           )

    {:ok, saved} = Funding.get(location, opportunity.id)
    assert saved.highlighted
    fields = Funding.atom_fields()
    assert Map.take(saved, fields) == Map.take(%{opportunity | highlighted: true}, fields)

    {:ok, calendar, _} =
      live(conn, ~p"/correspondence/calendar?#{%{show: "funding", date: deadline}}")

    assert has_element?(
             calendar,
             ".corr-calendar-day[data-date='#{deadline}'] .corr-calendar-day-event.is-highlighted",
             "Harbour fellowship · Deadline"
           )

    unstarred_row = "#funding-row-#{unstarred.id}"
    assert has_element?(view, unstarred_row)

    render_change(element(view, "#funding-filters"), %{
      "funding" => %{"q" => "Harbour", "starred" => "true"}
    })

    assert_patch(view)
    assert has_element?(view, ~s(input[name="funding[starred]"][checked]))
    assert has_element?(view, row)
    refute has_element?(view, unstarred_row)

    render_click(element(view, toggle))
    refute_patched(view)
    assert has_element?(view, "#funding-query[value=Harbour]")
    refute has_element?(view, row)
    assert {:ok, %{highlighted: false}} = Funding.get(location, opportunity.id)

    render_click(element(view, "#funding-filters a", "Reset"))
    refute has_element?(view, ~s(input[name="funding[starred]"][checked]))
    assert has_element?(view, row)
    assert has_element?(view, unstarred_row)
  end

  test "a stale funding row keeps a newer edit and can be highlighted after refresh", %{
    conn: conn,
    location: location
  } do
    {:ok, original} =
      Funding.save(location, %{
        name: "Harbour fellowship",
        funder: "Arts Council",
        kind: "fellowship",
        notes: "Original notes."
      })

    {:ok, view, _} = live(conn, ~p"/correspondence/funding")
    toggle = "#funding-row-#{original.id} .funding-highlight-toggle"
    newer_attrs = original |> Map.take(Funding.atom_fields()) |> Map.put(:notes, "Newer notes.")

    assert {:ok, newer} = Funding.save(location, newer_attrs, original.id, original.token)

    render_click(element(view, toggle))
    assert has_element?(view, "[role=alert]", "This funding opportunity changed.")
    assert has_element?(view, "#{toggle}[aria-pressed=false]")
    assert {:ok, ^newer} = Funding.get(location, original.id)

    render_click(element(view, toggle))
    assert has_element?(view, "#{toggle}[aria-pressed=true]")
    assert {:ok, %{highlighted: true, notes: "Newer notes."}} = Funding.get(location, original.id)
  end

  test "funding date changes follow the record into its own month and list views", %{
    conn: conn,
    location: location
  } do
    date = "2028-10-30"

    assert {:ok, _} =
             Calendar.save(location, %{
               external_id: "synthetic-public-reading",
               title: "Public reading",
               date: date
             })

    {:ok, view, _} = live(conn, ~p"/correspondence/funding/new")

    render_submit(element(view, "#funding-form"), %{
      "funding" => %{
        "name" => "Writers prize",
        "funder" => "Arts Council",
        "kind" => "prize",
        "opens_on" => date,
        "deadline" => date,
        "deadline_time" => "17:00",
        "timezone" => "Central Time"
      }
    })

    assert {:ok, [opportunity]} = Funding.list(location)
    assert_patch(view, ~p"/correspondence/funding/#{opportunity.id}")

    render_click(element(view, "a[href*='show=funding']", "Deadline"))
    assert has_element?(view, "#correspondence-calendar[data-source=funding]")
    assert has_element?(view, "#calendar-agenda-events article", "Writers prize · Deadline")
    assert has_element?(view, "#calendar-agenda-events article", "Central Time")
    refute has_element?(view, "#calendar-agenda-events article", "Writers prize · Opens")
    refute has_element?(view, "#calendar-agenda-events article", "Public reading")
    refute has_element?(view, "#calendar-agenda-events button[phx-click='hide_calendar_event']")

    render_click(element(view, "nav[aria-label='Calendar layout'] a", "List"))
    assert has_element?(view, "#calendar-events-table tbody tr", "Writers prize · Deadline")
    refute has_element?(view, "#calendar-events-table tbody tr", "Public reading")
    render_click(element(view, "#calendar-events-table a", "View funding"))

    render_submit(element(view, "#funding-form"), %{"funding" => %{"deadline" => "2028-11-02"}})
    render_click(element(view, "a[href*='show=funding']", "Deadline"))

    assert has_element?(
             view,
             ".corr-calendar-day[data-date='2028-11-02']",
             "Writers prize · Deadline"
           )

    assert has_element?(view, ".corr-calendar-day[data-date='#{date}']", "Writers prize · Opens")

    refute has_element?(
             view,
             ".corr-calendar-day[data-date='#{date}']",
             "Writers prize · Deadline"
           )

    render_click(element(view, "nav[aria-label='Calendar content'] a", "Events"))
    assert has_element?(view, ".corr-calendar-day[data-date='#{date}']", "Public reading")
    refute has_element?(view, ".corr-calendar-day[data-date='#{date}']", "Writers prize")
    assert {:ok, [%{title: "Public reading"}]} = Calendar.list(location)
  end
end
