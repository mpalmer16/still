defmodule Still.Correspondence.SubmissionWindows do
  @moduledoc "Recorded submission dates and the views they support."

  @doc "Validates a place's optional window, independently of its free-text notes."
  def normalize(nil), do: {:ok, nil}
  def normalize(%{"mode" => "check"}), do: {:ok, nil}
  def normalize(%{"mode" => "always"}), do: {:ok, %{"mode" => "always"}}

  def normalize(%{"mode" => "dates"} = window) do
    with {:ok, first} <- parse_date(window["opens"]),
         {:ok, last} <- parse_date(window["closes"]) do
      if Date.after?(first, last),
        do: {:error, "The submission window must close on or after it opens."},
        else:
          {:ok,
           %{
             "mode" => "dates",
             "opens" => Date.to_iso8601(first),
             "closes" => Date.to_iso8601(last)
           }}
    else
      _ -> {:error, "Enter both an opening and a closing date for the submission window."}
    end
  end

  def normalize(_), do: {:error, "Choose how to record the submission window."}

  def valid?(window), do: normalize(window) == {:ok, window}

  @doc "The opening and closing dates are both included in the recorded window."
  def status(window, day) do
    case window do
      %{"mode" => "always"} ->
        :open

      %{"mode" => "dates", "opens" => opens, "closes" => closes} ->
        with {:ok, first} <- parse_date(opens),
             {:ok, last} <- parse_date(closes),
             false <- Date.after?(first, last) do
          if Date.before?(day, first) or Date.after?(day, last), do: :closed, else: :open
        else
          _ -> :check
        end

      _ ->
        :check
    end
  end

  @doc "Builds the journal timeline for one month, retaining full window dates and clipping only the bar."
  def monthly_timeline(places, month, today, nearby_only? \\ false, query \\ "")

  def monthly_timeline(places, %Date{} = month, %Date{} = today, nearby_only?, query) do
    first_day = Date.beginning_of_month(month)
    last_day = Date.end_of_month(month)
    month_days = last_day.day

    today_in_month = if Date.beginning_of_month(today) == first_day, do: today
    query = search_text(query)

    eligible =
      places
      |> active_places()
      |> Enum.filter(&(not nearby_only? or &1.shortlisted))
      |> Enum.filter(&matches_query?(&1, query))

    {dated, year_round, dates_to_confirm} =
      Enum.reduce(eligible, {[], [], []}, fn place, {dated, year_round, dates_to_confirm} ->
        case timeline_dates(place.submission_window) do
          {:ok, opens, closes} ->
            if Date.after?(opens, last_day) or Date.before?(closes, first_day) do
              {dated, year_round, dates_to_confirm}
            else
              row = timeline_row(place, opens, closes, first_day, last_day, today)
              {[row | dated], year_round, dates_to_confirm}
            end

          :year_round ->
            {dated, [place | year_round], dates_to_confirm}

          :unconfirmed ->
            {dated, year_round, [place | dates_to_confirm]}
        end
      end)

    rows = dated |> Enum.reverse() |> sort_timeline_rows(today_in_month)

    %{
      month: first_day,
      today: today_in_month,
      days: month_days,
      rows: rows,
      year_round: Enum.reverse(year_round),
      dates_to_confirm: Enum.reverse(dates_to_confirm)
    }
  end

  @doc "Exports names, links, and recorded submission details for active journals."
  def export_json(places, scope) when scope in [:unconfirmed, :all] do
    places
    |> active_places()
    |> Enum.filter(&(scope == :all or timeline_dates(&1.submission_window) == :unconfirmed))
    |> Enum.map(&export_record/1)
    |> Jason.encode(pretty: true)
  end

  defp active_places(places) do
    places
    |> Enum.reject(& &1.inactive)
    |> Enum.sort_by(&{String.downcase(&1.name), &1.id})
  end

  defp matches_query?(_place, ""), do: true

  defp matches_query?(place, query) do
    fields = [
      place.name,
      place[:website],
      place[:submission_url],
      place[:windows],
      window_dates(place.submission_window)
    ]

    Enum.any?(fields, &String.contains?(search_text(&1), query))
  end

  defp search_text(value) when is_binary(value),
    do: value |> String.trim() |> String.normalize(:nfc) |> String.downcase()

  defp search_text(_), do: ""

  defp window_dates(%{"opens" => opens, "closes" => closes})
       when is_binary(opens) and is_binary(closes),
       do: "#{opens} #{closes}"

  defp window_dates(_), do: nil

  defp export_record(place) do
    %{"name" => place.name, "submission_window" => normalized_window(place.submission_window)}
    |> maybe_put("website", place[:website])
    |> maybe_put("submission_url", place[:submission_url])
    |> maybe_put("windows", place[:windows])
  end

  defp maybe_put(record, key, value) when is_binary(value) do
    if String.trim(value) == "", do: record, else: Map.put(record, key, value)
  end

  defp maybe_put(record, _key, _value), do: record

  defp normalized_window(window) do
    case normalize(window) do
      {:ok, normalized} -> normalized
      _ -> nil
    end
  end

  defp timeline_dates(%{"mode" => "always"}), do: :year_round

  defp timeline_dates(%{"mode" => "dates", "opens" => opens, "closes" => closes}) do
    with {:ok, first} <- parse_date(opens),
         {:ok, last} <- parse_date(closes),
         false <- Date.after?(first, last) do
      {:ok, first, last}
    else
      _ -> :unconfirmed
    end
  end

  defp timeline_dates(_), do: :unconfirmed

  defp timeline_row(place, start_date, end_date, first_day, last_day, today) do
    clipped_start = if Date.before?(start_date, first_day), do: first_day, else: start_date
    clipped_end = if Date.after?(end_date, last_day), do: last_day, else: end_date

    %{
      place: place,
      start_date: start_date,
      end_date: end_date,
      status: timeline_status(start_date, end_date, today),
      bar: %{
        left: clipped_start.day - 1,
        span: clipped_end.day - clipped_start.day + 1,
        continues_before?: Date.before?(start_date, first_day),
        continues_after?: Date.after?(end_date, last_day)
      }
    }
  end

  defp timeline_status(start_date, end_date, today) do
    cond do
      Date.before?(today, start_date) -> :upcoming
      Date.after?(today, end_date) -> :closed
      true -> :open
    end
  end

  defp sort_timeline_rows(rows, nil),
    do:
      Enum.sort_by(
        rows,
        &{Date.to_gregorian_days(&1.start_date), Date.to_gregorian_days(&1.end_date)}
      )

  defp sort_timeline_rows(rows, %Date{}) do
    Enum.sort_by(rows, fn
      %{status: :open, end_date: closes} -> {0, Date.to_gregorian_days(closes)}
      %{status: :upcoming, start_date: opens} -> {1, Date.to_gregorian_days(opens)}
      %{status: :closed, end_date: closes} -> {2, -Date.to_gregorian_days(closes)}
    end)
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_), do: :error
end
