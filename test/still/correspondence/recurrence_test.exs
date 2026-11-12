defmodule Still.Correspondence.RecurrenceTest do
  use ExUnit.Case, async: true
  alias Still.Correspondence.Recurrence

  defp event(rule, extra \\ %{}) do
    Map.merge(
      %{
        id: "series",
        token: "token",
        title: "A reading",
        date: "2026-11-12",
        start_time: "19:00",
        end_time: nil,
        end_date: nil,
        recurrence: rule
      },
      extra
    )
  end

  defp dates(events), do: Enum.map(events, & &1.date)

  test "weekly rules cross the year, end inclusively and respect skipped dates" do
    rule = %{"frequency" => "weekly", "until" => "2027-01-14", "excluded_dates" => ["2026-12-31"]}

    assert dates(Recurrence.occurrences([event(rule)], ~D[2026-12-24], ~D[2027-01-21])) == [
             "2026-12-24",
             "2027-01-07",
             "2027-01-14"
           ]
  end

  test "monthly weekday and last weekday patterns are anchored correctly" do
    rule = %{"frequency" => "monthly", "weekday" => "thursday", "week_of_month" => 2}

    assert dates(Recurrence.occurrences([event(rule)], ~D[2026-11-01], ~D[2027-02-28])) == [
             "2026-11-12",
             "2026-12-10",
             "2027-01-14",
             "2027-02-11"
           ]

    assert {:error, _} = Recurrence.validate(rule, "2026-11-13")

    last =
      event(%{"frequency" => "monthly", "weekday" => "thursday", "week_of_month" => -1}, %{
        date: "2026-11-26"
      })

    assert dates(Recurrence.occurrences([last], ~D[2026-11-01], ~D[2027-02-28])) == [
             "2026-11-26",
             "2026-12-31",
             "2027-01-28",
             "2027-02-25"
           ]
  end

  test "missing month dates and leap days are skipped without drifting" do
    monthly = event(%{"frequency" => "monthly"}, %{date: "2027-01-31"})

    assert dates(Recurrence.occurrences([monthly], ~D[2027-01-01], ~D[2027-04-30])) == [
             "2027-01-31",
             "2027-03-31"
           ]

    yearly = event(%{"frequency" => "yearly"}, %{date: "2024-02-29"})
    assert Recurrence.occurrences([yearly], ~D[2027-01-01], ~D[2027-12-31]) == []

    assert dates(Recurrence.occurrences([yearly], ~D[2028-01-01], ~D[2028-12-31])) == [
             "2028-02-29"
           ]
  end

  test "multi-day repeats retain local time, duration and hide choices without editing a series" do
    original =
      event(%{"frequency" => "weekly"}, %{end_date: "2026-11-14", hidden_dates: ["2026-11-19"]})

    [ongoing] = Recurrence.occurrences([original], ~D[2026-11-13], ~D[2026-11-13])

    assert {ongoing.date, ongoing.end_date, ongoing.start_time} ==
             {"2026-11-12", "2026-11-14", "19:00"}

    [hidden] = Recurrence.occurrences([original], ~D[2026-11-19], ~D[2026-11-19])
    assert hidden.hidden
    refute hidden.series_hidden
    assert original.date == "2026-11-12"

    [whole] =
      Recurrence.occurrences([Map.put(original, :hidden, true)], ~D[2026-11-12], ~D[2026-11-12])

    assert whole.series_hidden
  end

  test "malformed rules and unbounded windows are rejected" do
    for rule <- [
          %{"frequency" => "never"},
          %{"frequency" => "weekly", "interval" => 0},
          %{"frequency" => "monthly", "weekday" => "thursday"},
          %{"frequency" => "daily", "surprise" => true},
          %{"frequency" => "weekly", "until" => "2020-01-01"}
        ] do
      assert {:error, _} = Recurrence.validate(rule, "2026-11-12")
    end

    assert Recurrence.occurrences(
             [event(%{"frequency" => "daily"})],
             ~D[2026-01-01],
             ~D[2090-01-01]
           ) == []
  end
end
