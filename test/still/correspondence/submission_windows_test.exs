defmodule Still.Correspondence.SubmissionWindowsTest do
  use ExUnit.Case, async: true

  alias Still.Correspondence.SubmissionWindows

  test "clips inclusive bars at month edges and keeps the exact full range" do
    places = [
      place("spans", %{"mode" => "dates", "opens" => "2026-10-29", "closes" => "2026-11-03"}),
      place("one day", %{"mode" => "dates", "opens" => "2026-11-30", "closes" => "2026-11-30"}),
      place("ends at edge", %{
        "mode" => "dates",
        "opens" => "2026-11-30",
        "closes" => "2026-12-02"
      })
    ]

    model = SubmissionWindows.monthly_timeline(places, ~D[2026-11-18], ~D[2026-11-18])
    rows = Map.new(model.rows, &{&1.place.name, &1})

    assert model.month == ~D[2026-11-01]
    assert model.today == ~D[2026-11-18]
    assert model.days == 30
    assert rows["spans"].start_date == ~D[2026-10-29]
    assert rows["spans"].end_date == ~D[2026-11-03]

    assert rows["spans"].bar == %{
             left: 0,
             span: 3,
             continues_before?: true,
             continues_after?: false
           }

    assert rows["one day"].start_date == rows["one day"].end_date
    assert rows["one day"].bar.span == 1
    assert rows["one day"].bar.left == 29
    assert rows["ends at edge"].bar.span == 1
    assert rows["ends at edge"].bar.continues_after?
  end

  test "orders open windows by nearest close, then future openings, then past windows" do
    places = [
      place("past later", dates("2026-11-01", "2026-11-10")),
      place("opens first", dates("2026-11-20", "2026-11-25")),
      place("open later", dates("2026-11-10", "2026-11-19")),
      place("open sooner", dates("2026-11-12", "2026-11-18")),
      place("past recent", dates("2026-11-02", "2026-11-16")),
      place("opens second", dates("2026-11-22", "2026-11-29"))
    ]

    model = SubmissionWindows.monthly_timeline(places, ~D[2026-11-01], ~D[2026-11-18])

    assert Enum.map(model.rows, &{&1.place.name, &1.status}) == [
             {"open sooner", :open},
             {"open later", :open},
             {"opens first", :upcoming},
             {"opens second", :upcoming},
             {"past recent", :closed},
             {"past later", :closed}
           ]
  end

  test "lists year-round and unconfirmed dates separately and applies nearby eligibility" do
    places = [
      place("near year-round", %{"mode" => "always"}, shortlisted: true),
      place("far year-round", %{"mode" => "always"}),
      place("near confirm", %{"mode" => "check"}, shortlisted: true),
      place("far confirm", nil),
      place("inactive", dates("2026-11-01", "2026-11-30"), inactive: true, shortlisted: true),
      place("near dated", dates("2026-11-01", "2026-11-30"), shortlisted: true),
      place("far dated", dates("2026-11-01", "2026-11-30"))
    ]

    model = SubmissionWindows.monthly_timeline(places, ~D[2026-11-01], ~D[2027-02-01], true)

    assert model.today == nil
    assert Enum.map(model.rows, & &1.place.name) == ["near dated"]
    assert Enum.map(model.year_round, & &1.name) == ["near year-round"]
    assert Enum.map(model.dates_to_confirm, & &1.name) == ["near confirm"]
  end

  test "includes first and last day overlaps in historical and future months" do
    at_first = [place("first", dates("2020-01-31", "2020-02-01"))]
    at_last = [place("last", dates("2032-02-29", "2032-02-29"))]

    historical = SubmissionWindows.monthly_timeline(at_first, ~D[2020-02-10], ~D[2026-11-18])
    future = SubmissionWindows.monthly_timeline(at_last, ~D[2032-02-10], ~D[2026-11-18])

    assert hd(historical.rows).bar == %{
             left: 0,
             span: 1,
             continues_before?: true,
             continues_after?: false
           }

    assert hd(future.rows).status == :upcoming
    assert hd(future.rows).bar.left == 28
    assert hd(future.rows).bar.span == 1
  end

  test "searches each timeline group across public research fields and recorded dates" do
    places = [
      place("Dated Journal", dates("2026-11-01", "2026-11-30"), windows: "Spring reading period"),
      place("Yearly Review", %{"mode" => "always"},
        submission_url: "https://submit.example/yearly"
      ),
      place("Needs Check", nil, website: "https://example.org/needs-check"),
      place("Private Needle", nil, notes: "secret needle")
    ]

    by_window =
      SubmissionWindows.monthly_timeline(places, ~D[2026-11-10], ~D[2026-11-10], false, "SPRING")

    by_url =
      SubmissionWindows.monthly_timeline(
        places,
        ~D[2026-11-10],
        ~D[2026-11-10],
        false,
        "submit.example"
      )

    by_date =
      SubmissionWindows.monthly_timeline(
        places,
        ~D[2026-11-10],
        ~D[2026-11-10],
        false,
        "2026-11-30"
      )

    private =
      SubmissionWindows.monthly_timeline(
        places,
        ~D[2026-11-10],
        ~D[2026-11-10],
        false,
        "secret needle"
      )

    assert Enum.map(by_window.rows, & &1.place.name) == ["Dated Journal"]
    assert Enum.map(by_url.year_round, & &1.name) == ["Yearly Review"]
    assert Enum.map(by_url.dates_to_confirm, & &1.name) == []
    assert Enum.map(by_date.rows, & &1.place.name) == ["Dated Journal"]
    assert by_date.year_round == []
    assert by_date.dates_to_confirm == []
    assert private.rows == [] and private.year_round == [] and private.dates_to_confirm == []
  end

  test "exports all active places or only unconfirmed dates with an explicit safe field set" do
    places = [
      place("Zeta", nil,
        website: "",
        submission_url: nil,
        windows: "  ",
        notes: "private note",
        id: "hidden-id"
      ),
      place("Alpha", %{"mode" => "always"},
        website: "https://alpha.example",
        windows: "Always open"
      ),
      place("Beta", dates("2026-11-01", "2026-11-30"),
        submission_url: "https://beta.example/submit"
      ),
      place("Inactive", nil, inactive: true, notes: "must not export")
    ]

    assert {:ok, unconfirmed_json} = SubmissionWindows.export_json(places, :unconfirmed)
    assert {:ok, all_json} = SubmissionWindows.export_json(places, :all)
    unconfirmed = Jason.decode!(unconfirmed_json)
    all = Jason.decode!(all_json)

    assert Enum.map(unconfirmed, & &1["name"]) == ["Zeta"]
    assert unconfirmed == [%{"name" => "Zeta", "submission_window" => nil}]
    assert Enum.map(all, & &1["name"]) == ["Alpha", "Beta", "Zeta"]

    assert Enum.at(all, 0) == %{
             "name" => "Alpha",
             "website" => "https://alpha.example",
             "windows" => "Always open",
             "submission_window" => %{"mode" => "always"}
           }

    assert Enum.at(all, 1) == %{
             "name" => "Beta",
             "submission_url" => "https://beta.example/submit",
             "submission_window" => %{
               "mode" => "dates",
               "opens" => "2026-11-01",
               "closes" => "2026-11-30"
             }
           }

    refute all_json =~ "private note"
    refute all_json =~ "hidden-id"
    refute all_json =~ "Inactive"
  end

  defp dates(opens, closes), do: %{"mode" => "dates", "opens" => opens, "closes" => closes}

  defp place(name, submission_window, attrs \\ []) do
    Map.merge(
      %{
        id: name,
        name: name,
        submission_window: submission_window,
        inactive: false,
        shortlisted: false
      },
      Map.new(attrs)
    )
  end
end
