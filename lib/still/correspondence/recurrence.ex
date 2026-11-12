defmodule Still.Correspondence.Recurrence do
  @moduledoc "Validated calendar repeat rules and bounded, non-persisted occurrences."
  @frequencies ~w(daily weekly monthly yearly)
  @weekdays ~w(monday tuesday wednesday thursday friday saturday sunday)
  @fields ~w(frequency interval until weekday week_of_month excluded_dates)

  def validate(nil, _), do: {:ok, nil}

  def validate(rule, date) when is_map(rule) do
    rule = Map.new(rule, fn {key, value} -> {to_string(key), value} end)

    with {:ok, start} <- parse_date(date),
         true <- Map.keys(rule) -- @fields == [],
         true <- rule["frequency"] in @frequencies,
         interval = Map.get(rule, "interval", 1),
         true <- is_integer(interval) and interval in 1..100,
         {:ok, until} <- optional_date(rule["until"]),
         true <- is_nil(until) or Date.compare(until, start) != :lt,
         true <- valid_monthly?(rule, start),
         {:ok, excluded} <- excluded_dates(Map.get(rule, "excluded_dates", [])) do
      {:ok,
       %{
         "frequency" => rule["frequency"],
         "interval" => interval,
         "until" => until && Date.to_iso8601(until),
         "weekday" => rule["weekday"],
         "week_of_month" => rule["week_of_month"],
         "excluded_dates" => excluded
       }}
    else
      _ ->
        {:error,
         "Use a valid daily, weekly, monthly, or yearly recurrence. Intervals must be 1–100; the end date cannot precede the first date. Monthly weekday rules need both weekday and week_of_month, matching the first date."}
    end
  end

  def validate(_, _), do: {:error, "recurrence must be an object or null."}

  defp valid_monthly?(rule, start) do
    weekday = rule["weekday"]
    week = rule["week_of_month"]

    if is_nil(weekday) and is_nil(week) do
      true
    else
      rule["frequency"] == "monthly" and weekday in @weekdays and week in [-1, 1, 2, 3, 4, 5] and
        nth_weekday?(start, weekday, week)
    end
  end

  defp excluded_dates(values) when is_list(values) and length(values) <= 500 do
    if Enum.all?(values, &match?({:ok, _}, parse_date(&1))),
      do:
        {:ok,
         values
         |> Enum.map(fn value ->
           {:ok, date} = parse_date(value)
           Date.to_iso8601(date)
         end)
         |> Enum.uniq()
         |> Enum.sort()},
      else: {:error, "Excluded dates must be ISO dates."}
  end

  defp excluded_dates(_), do: {:error, "Use no more than 500 excluded dates."}

  @doc "Occurrences intersecting a bounded window. Repeating series stay as one stored record."
  def occurrences(events, %Date{} = first, %Date{} = last) when is_list(events) do
    if Date.compare(first, last) == :gt or Date.diff(last, first) > 400 do
      []
    else
      events
      |> Enum.flat_map(&expand(&1, first, last))
      |> Enum.sort_by(fn event -> {event.date, event.start_time || "", event.title, event.id} end)
    end
  end

  defp expand(event, first, last) do
    with {:ok, start} <- parse_date(value(event, :date)),
         {:ok, finish} <- optional_date(value(event, :end_date)) do
      duration = Date.diff(finish || start, start)
      rule = value(event, :recurrence)

      if is_nil(rule) do
        if Date.compare(start, last) != :gt and Date.compare(finish || start, first) != :lt,
          do: [occurrence(event, start, duration, nil)],
          else: []
      else
        with {:ok, normalized} when is_map(normalized) <- validate(rule, Date.to_iso8601(start)) do
          from = later(start, Date.add(first, -min(max(duration, 0), 366)))

          until =
            case optional_date(normalized["until"]) do
              {:ok, date} -> date
              _ -> nil
            end

          through = if until, do: earlier(until, last), else: last

          if Date.compare(from, through) == :gt do
            []
          else
            for date <- Date.range(from, through),
                repeats_on?(date, start, normalized),
                Date.to_iso8601(date) not in normalized["excluded_dates"],
                do: occurrence(event, date, duration, normalized)
          end
        else
          _ -> []
        end
      end
    else
      _ -> []
    end
  end

  defp occurrence(event, date, duration, rule) do
    day = Date.to_iso8601(date)

    base =
      Enum.reduce(
        ~w(title start_time end_time timezone venue address url notes category status)a,
        %{},
        fn key, acc -> Map.put(acc, key, value(event, key)) end
      )

    Map.merge(base, %{
      id: value(event, :id),
      token: value(event, :token),
      date: day,
      end_date: if(value(event, :end_date), do: Date.to_iso8601(Date.add(date, duration))),
      series_date: value(event, :date),
      recurrence: rule,
      recurrence_label: describe(rule),
      occurrence_key: "#{value(event, :id)}:#{day}",
      series_hidden: value(event, :hidden) == true,
      hidden: value(event, :hidden) == true or day in (value(event, :hidden_dates) || [])
    })
  end

  defp repeats_on?(date, start, %{"frequency" => "daily", "interval" => interval}),
    do: rem(Date.diff(date, start), interval) == 0

  defp repeats_on?(date, start, %{"frequency" => "weekly", "interval" => interval}),
    do: rem(Date.diff(date, start), 7 * interval) == 0

  defp repeats_on?(date, start, %{"frequency" => "monthly", "interval" => interval} = rule) do
    months = (date.year - start.year) * 12 + date.month - start.month

    rem(months, interval) == 0 and
      if(rule["weekday"],
        do: nth_weekday?(date, rule["weekday"], rule["week_of_month"]),
        else: date.day == start.day
      )
  end

  defp repeats_on?(date, start, %{"frequency" => "yearly", "interval" => interval}),
    do:
      rem(date.year - start.year, interval) == 0 and date.month == start.month and
        date.day == start.day

  defp nth_weekday?(date, weekday, week) do
    Date.day_of_week(date) == Enum.find_index(@weekdays, &(&1 == weekday)) + 1 and
      if(week == -1,
        do: date.day + 7 > Date.days_in_month(date),
        else: div(date.day - 1, 7) + 1 == week
      )
  end

  def describe(nil), do: nil

  def describe(rule) do
    interval = rule["interval"] || 1

    noun =
      %{"daily" => "day", "weekly" => "week", "monthly" => "month", "yearly" => "year"}[
        rule["frequency"]
      ]

    base = if interval == 1, do: "Every #{noun}", else: "Every #{interval} #{noun}s"

    if rule["weekday"] do
      ordinal =
        %{-1 => "last", 1 => "first", 2 => "second", 3 => "third", 4 => "fourth", 5 => "fifth"}[
          rule["week_of_month"]
        ]

      base <> " · #{ordinal} #{String.capitalize(rule["weekday"])}"
    else
      base
    end
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(date) when is_binary(date) do
    if Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, date),
      do: Date.from_iso8601(date),
      else: {:error, :date}
  end

  defp parse_date(_), do: {:error, :date}
  defp optional_date(value) when value in [nil, ""], do: {:ok, nil}
  defp optional_date(value), do: parse_date(value)
  defp later(a, b), do: if(Date.compare(a, b) == :gt, do: a, else: b)
  defp earlier(a, b), do: if(Date.compare(a, b) == :lt, do: a, else: b)
end
