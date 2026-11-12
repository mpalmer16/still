defmodule Still.Correspondence.PacketDirectory do
  @moduledoc "Pure searchable directory of correspondence packets."

  @statuses ~w(all preparing submitted awaiting declined accepted withdrawn)
  @sorts ~w(recent title destination sent_date)

  def browse(packets, journals, pieces, params \\ %{}) do
    f = canonical(params)
    places = Map.new(list(journals), &{get(&1, :id), &1})
    works = Map.new(list(pieces), &{get(&1, :id), &1})

    rows =
      packets
      |> list()
      |> Enum.map(fn packet ->
        ids = list(get(packet, :piece_ids))

        snapshot_pieces = list(get(get(packet, :snapshot, %{}), :pieces))
        snapshot_by_id = Map.new(snapshot_pieces, &{get(&1, :id), &1})
        destination = Map.get(places, get(packet, :journal_id))

        %{
          packet: packet,
          destination: destination,
          destination_name: get(packet, :journal_name) || get(destination, :name) || "Not chosen",
          pieces:
            Enum.map(ids, &(Map.get(snapshot_by_id, &1) || Map.get(works, &1)))
            |> Enum.reject(&is_nil/1),
          piece_count: length(ids),
          submitted_on: submitted_date(packet),
          date: display_date(packet)
        }
      end)
      |> Enum.filter(&matches?(&1, f))
      |> Enum.sort_by(&sort_key(&1, f.sort))
      |> then(fn rows -> if f.direction == "desc", do: Enum.reverse(rows), else: rows end)

    pages = max(1, ceil(length(rows) / 40))
    page = min(f.page, pages)
    shown = rows |> Enum.drop((page - 1) * 40) |> Enum.take(40)

    %{
      rows: shown,
      filters: Map.new(Map.put(f, :page, page), fn {k, v} -> {to_string(k), v} end),
      total: length(list(packets)),
      matched: length(rows),
      page: page,
      pages: pages,
      per_page: 40,
      shown: length(shown),
      more?: page < pages
    }
  end

  defp matches?(row, f),
    do:
      (f.status == "all" or get(row.packet, :status) == f.status) and
        (f.destination == "all" or (f.destination == "chosen" and not is_nil(row.destination)) or
           (f.destination == "unchosen" and is_nil(row.destination))) and search?(row, f.q)

  defp search?(_row, ""), do: true

  defp search?(row, q) do
    text =
      [
        get(row.packet, :title),
        row.destination_name,
        get(row.packet, :status),
        Enum.map(
          row.pieces,
          &[get(&1, :title), get(&1, :body), get(&1, :notebook), get(&1, :list_label)]
        )
      ]
      |> List.flatten()
      |> Enum.map(&normalize/1)
      |> Enum.join(" ")

    Enum.all?(String.split(normalize(q)), &String.contains?(text, &1))
  end

  defp submitted_date(packet) do
    packet
    |> get(:events, [])
    |> list()
    |> Enum.filter(&(get(&1, :kind) == "submitted"))
    |> Enum.map(&get(&1, :date))
    |> Enum.filter(&valid_date?/1)
    |> Enum.max(fn -> nil end)
  end

  defp display_date(packet), do: submitted_date(packet)

  defp sort_key(row, "title"), do: {normalize(get(row.packet, :title)), id(row.packet)}

  defp sort_key(row, "destination"),
    do: {normalize(row.destination_name), normalize(get(row.packet, :title)), id(row.packet)}

  defp sort_key(row, "sent_date"),
    do: {row.submitted_on || "", normalize(get(row.packet, :title)), id(row.packet)}

  defp sort_key(row, _), do: {to_string(get(row.packet, :updated_at, "")), id(row.packet)}

  defp valid_date?(s) when is_binary(s), do: match?({:ok, _}, Date.from_iso8601(s))
  defp valid_date?(_), do: false

  defp canonical(params) do
    p = if is_map(params), do: params, else: %{}

    %{
      q: query(get(p, :q)),
      status: enum(get(p, :status), @statuses, "all"),
      destination: enum(get(p, :destination), ~w(all chosen unchosen), "all"),
      sort: enum(get(p, :sort), @sorts, "recent"),
      direction: enum(get(p, :direction), ~w(asc desc), "desc"),
      page: positive(get(p, :page), 1)
    }
  end

  defp get(m, k, d \\ nil)
  defp get(m, k, d) when is_map(m) and is_atom(k), do: Map.get(m, k, Map.get(m, to_string(k), d))
  defp get(_, _, d), do: d
  defp list(v) when is_list(v), do: v
  defp list(_), do: []
  defp enum(v, allowed, d) when is_binary(v), do: if(v in allowed, do: v, else: d)
  defp enum(_, _, d), do: d
  defp positive(v, _d) when is_integer(v) and v > 0, do: v

  defp positive(v, d) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n > 0 -> n
      _ -> d
    end
  end

  defp positive(_, d), do: d
  defp query(v) when is_binary(v), do: String.trim(v)
  defp query(_), do: ""

  defp normalize(v) when is_binary(v),
    do: v |> String.normalize(:nfc) |> String.downcase() |> String.replace(~r/\s+/u, " ")

  defp normalize(_), do: ""
  defp id(packet), do: to_string(get(packet, :id, ""))
end
