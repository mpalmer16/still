defmodule Still.Correspondence.PlaceDirectory do
  @moduledoc "Pure, bounded query for the Places directory."

  @search_fields ~w(name description keywords interests guidelines notes reach_note windows fee website submission_url response_expectation)
  @statuses ~w(active all inactive)
  @nearby ~w(all nearby not_nearby)
  @reaches ~w(all approachable stretch long_shot unknown)
  @simultaneous ~w(all allowed not_allowed unknown)
  @histories ~w(all never_sent awaiting sent)
  @sorts ~w(name reach window last_sent)

  def browse(journals, packets, params) do
    canonical = canonical(params)
    journals = list(journals)
    packets_by_journal = packets |> list() |> Enum.group_by(&get(&1, :journal_id))

    matches =
      journals
      |> Enum.map(fn journal ->
        {journal, summary(get(packets_by_journal, get(journal, :id), []))}
      end)
      |> Enum.filter(fn {journal, history} -> matches?(journal, history, canonical) end)
      |> Enum.sort_by(fn {journal, history} -> sort_key(journal, history, canonical.sort) end)
      |> order_direction(canonical.direction, canonical.sort)

    matched = length(matches)
    pages = max(1, ceil(matched / 40))
    page = min(canonical.page, pages)
    rows = matches |> Enum.drop((page - 1) * 40) |> Enum.take(40) |> Enum.map(&row/1)

    filters = canonical |> Map.put(:page, page) |> stringify_keys()

    %{
      rows: rows,
      filters: filters,
      total: length(journals),
      matched: matched,
      page: page,
      pages: pages,
      per_page: 40,
      shown: length(rows),
      more?: page < pages
    }
  end

  defp canonical(params) do
    p = if is_map(params), do: params, else: %{}

    %{
      q: query(value(p, :q)),
      status: enum(value(p, :status), @statuses, "active"),
      nearby: enum(value(p, :nearby), @nearby, "all"),
      reach: enum(value(p, :reach), @reaches, "all"),
      simultaneous: enum(value(p, :simultaneous), @simultaneous, "all"),
      history: enum(value(p, :history), @histories, "all"),
      sort: enum(value(p, :sort), @sorts, "name"),
      direction: enum(value(p, :direction), ~w(asc desc), "asc"),
      page: min(max(positive(value(p, :page), 1), 1), 100_000)
    }
  end

  defp matches?(journal, history, f) do
    (f.status == "all" or f.status == "inactive" == truthy?(get(journal, :inactive))) and
      nearby?(journal, f.nearby) and (f.reach == "all" or reach(journal) == f.reach) and
      simultaneous?(journal, f.simultaneous) and history?(history, f.history) and
      search?(journal, f.q)
  end

  defp nearby?(_j, "all"), do: true
  defp nearby?(j, filter), do: truthy?(get(j, :shortlisted)) == (filter == "nearby")
  defp simultaneous?(_j, "all"), do: true

  defp simultaneous?(j, f) do
    policy = get(j, :simultaneous_policy)
    policy = if policy in ["allowed", "not_allowed"], do: policy, else: "unknown"
    f == policy
  end

  defp history?(_history, "all"), do: true

  defp history?(history, filter) do
    case filter do
      "never_sent" -> history.sent_count == 0
      "sent" -> history.sent_count > 0
      "awaiting" -> history.awaiting_count > 0
    end
  end

  defp search?(_j, ""), do: true

  defp search?(j, q) do
    terms = q |> normalize() |> String.split()

    text =
      @search_fields
      |> Enum.map(&get(j, String.to_atom(&1)))
      |> Enum.map(&normalize/1)
      |> Enum.join(" ")

    Enum.all?(terms, &String.contains?(text, &1))
  end

  defp row({journal, history}) do
    Map.put(history, :journal, journal)
  end

  defp sort_key(j, _history, "reach"), do: {reach_rank(reach(j)), name_key(j), id_key(j)}
  defp sort_key(j, _history, "window"), do: {normalize(get(j, :windows)), name_key(j), id_key(j)}

  defp sort_key(j, history, "last_sent") do
    case history.last_sent_at do
      nil -> {1, "", name_key(j), id_key(j)}
      date -> {0, date, name_key(j), id_key(j)}
    end
  end

  defp sort_key(j, _history, _), do: {name_key(j), id_key(j)}

  defp order_direction(rows, "desc", "last_sent") do
    {dated, missing} =
      Enum.split_with(rows, fn {_journal, history} -> not is_nil(history.last_sent_at) end)

    Enum.reverse(dated) ++ missing
  end

  defp order_direction(rows, "desc", _sort), do: Enum.reverse(rows)
  defp order_direction(rows, _, _), do: rows

  defp summary(packets) do
    sent = Enum.filter(packets, &sent?/1)
    dates = sent |> Enum.flat_map(&submitted_dates/1) |> Enum.sort()

    %{
      packet_count: length(packets),
      sent_count: length(sent),
      awaiting_count: Enum.count(packets, &awaiting?/1),
      last_sent_at: List.last(dates)
    }
  end

  defp reach_rank("approachable"), do: 0
  defp reach_rank("stretch"), do: 1
  defp reach_rank("long_shot"), do: 2
  defp reach_rank(_), do: 3

  defp reach(j),
    do:
      if(get(j, :reach) in ["approachable", "stretch", "long_shot"],
        do: get(j, :reach),
        else: "unknown"
      )

  defp name_key(j), do: normalize(get(j, :name))
  defp id_key(j), do: to_string(get(j, :id, ""))
  defp sent?(p), do: is_binary(get(p, :snapshot_ref)) and get(p, :status) != "preparing"

  defp awaiting?(p) do
    status = get(p, :status)

    status in ["submitted", "awaiting"] or
      (status == "accepted" and
         length(list(get(p, :accepted_piece_ids))) < length(list(get(p, :piece_ids))))
  end

  defp submitted_dates(p) do
    p
    |> get(:events, [])
    |> list()
    |> Enum.filter(&(get(&1, :kind) == "submitted"))
    |> Enum.map(&get(&1, :date))
    |> Enum.filter(&valid_date?/1)
  end

  defp valid_date?(s) when is_binary(s), do: match?({:ok, _}, Date.from_iso8601(s))
  defp valid_date?(_), do: false
  defp get(m, key, default \\ nil)

  defp get(m, key, default) when is_map(m) and is_atom(key),
    do: Map.get(m, key, Map.get(m, Atom.to_string(key), default))

  defp get(m, key, default) when is_map(m), do: Map.get(m, key, default)
  defp get(_, _, default), do: default
  defp value(m, key), do: get(m, key)
  defp list(v) when is_list(v), do: v
  defp list(_), do: []
  defp enum(v, allowed, default) when is_binary(v), do: if(v in allowed, do: v, else: default)
  defp enum(_, _, default), do: default
  defp positive(v, _default) when is_integer(v) and v > 0, do: v

  defp positive(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp positive(_, default), do: default
  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)
  defp truthy?(v), do: v in [true, "true", 1, "1", "yes"]
  defp query(value) when is_binary(value), do: String.trim(value)
  defp query(_), do: ""

  defp normalize(v) when is_binary(v),
    do: v |> String.normalize(:nfc) |> String.downcase() |> String.replace(~r/\s+/u, " ")

  defp normalize(_), do: ""
end
