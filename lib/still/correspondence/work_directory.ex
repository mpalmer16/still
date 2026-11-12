defmodule Still.Correspondence.WorkDirectory do
  @moduledoc "Pure searchable directory of correspondence-ready writing."

  alias Still.Poems

  @statuses ~w(all ready preparing submitted awaiting accepted declined withdrawn)
  @sorts ~w(notebook title activity)

  def browse(pieces, packets, params \\ %{}) do
    filters = canonical(params)

    notebook_options =
      pieces
      |> list()
      |> Enum.map(&get(&1, :notebook))
      |> Enum.reject(&(not is_binary(&1) or String.trim(&1) == ""))
      |> Enum.uniq()
      |> Enum.sort_by(&normalize/1)

    # Build involvement once; each piece may belong to several packets.
    involvement =
      packets
      |> list()
      |> Enum.reduce(%{}, fn packet, acc ->
        Enum.reduce(list(get(packet, :piece_ids)), acc, fn id, rows ->
          Map.update(rows, id, [packet], &[packet | &1])
        end)
      end)

    rows =
      pieces
      |> list()
      |> Enum.map(fn piece -> row(piece, Map.get(involvement, get(piece, :id), [])) end)
      |> Enum.filter(&matches?(&1, filters))
      |> Enum.sort_by(&sort_key(&1, filters.sort))
      |> direction(filters.direction)

    result = paginate(rows, filters)

    result
    |> Map.put(:notebook_options, notebook_options)
    |> Map.put(:total, length(list(pieces)))
  end

  defp row(piece, packets) do
    latest = Enum.max_by(packets, &to_string(get(&1, :updated_at, "")), fn -> nil end)
    states = Enum.map(packets, &piece_status(&1, get(piece, :id)))
    state_counts = Enum.frequencies(states)

    %{
      piece: piece,
      packets: Enum.reverse(packets),
      packet_count: length(packets),
      status: summary_status(states),
      status_counts: state_counts,
      latest_packet: latest,
      title: Poems.display_title(piece)
    }
  end

  defp piece_status(packet, piece_id) do
    case {piece_id in list(get(packet, :accepted_piece_ids)), get(packet, :status)} do
      {true, _} ->
        "accepted"

      {false, "accepted"} ->
        "awaiting"

      {false, status}
      when status in ["preparing", "submitted", "awaiting", "declined", "withdrawn"] ->
        status

      _ ->
        "ready"
    end
  end

  defp summary_status([]), do: "ready"

  defp summary_status(states) do
    Enum.find(
      ["accepted", "awaiting", "submitted", "preparing", "declined", "withdrawn"],
      "ready",
      fn state ->
        state in states
      end
    )
  end

  defp matches?(row, f),
    do:
      status_matches?(row, f.status) and
        (f.notebook == "all" or to_string(get(row.piece, :notebook, "")) == f.notebook) and
        search?(row, f.q)

  defp status_matches?(_row, "all"), do: true

  defp status_matches?(row, "ready"),
    do:
      not Enum.any?(row.status_counts, fn {state, count} ->
        state in ["preparing", "submitted", "awaiting", "accepted"] and count > 0
      end)

  defp status_matches?(row, state), do: Map.get(row.status_counts, state, 0) > 0

  defp search?(_row, ""), do: true

  defp search?(row, q) do
    text =
      [
        row.title,
        get(row.piece, :body),
        get(row.piece, :notebook),
        get(row.piece, :list_label),
        get(row.piece, :relative_path),
        Enum.map(row.packets, &get(&1, :title))
      ]
      |> List.flatten()
      |> Enum.map(&normalize/1)
      |> Enum.join(" ")

    Enum.all?(String.split(normalize(q)), &String.contains?(text, &1))
  end

  defp sort_key(row, "title"), do: {normalize(row.title), id(row.piece)}

  defp sort_key(row, "activity"),
    do: {to_string(get(row.latest_packet, :updated_at, "")), normalize(row.title), id(row.piece)}

  defp sort_key(row, _),
    do:
      {natural_key(get(row.piece, :notebook)), natural_key(get(row.piece, :list_label)),
       id(row.piece)}

  defp direction(rows, "desc"), do: Enum.reverse(rows)
  defp direction(rows, _), do: rows

  defp canonical(params) do
    p = if is_map(params), do: params, else: %{}

    %{
      q: query(get(p, :q)),
      status: enum(get(p, :status), @statuses, "all"),
      notebook: query(get(p, :notebook)) |> then(&if(&1 == "", do: "all", else: &1)),
      sort: enum(get(p, :sort), @sorts, "notebook"),
      direction: enum(get(p, :direction), ~w(asc desc), "asc"),
      page: positive(get(p, :page), 1)
    }
  end

  defp paginate(rows, f) do
    pages = max(1, ceil(length(rows) / 40))
    page = min(f.page, pages)
    shown = rows |> Enum.drop((page - 1) * 40) |> Enum.take(40)

    %{
      rows: shown,
      filters: Map.new(Map.put(f, :page, page), fn {k, v} -> {to_string(k), v} end),
      total: length(rows),
      matched: length(rows),
      page: page,
      pages: pages,
      per_page: 40,
      shown: length(shown),
      more?: page < pages
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

  defp natural_key(value) do
    value
    |> normalize()
    |> String.split(~r/(\d+)/, include_captures: true, trim: true)
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {n, ""} -> {0, n}
        _ -> {1, part}
      end
    end)
  end

  defp id(piece), do: to_string(get(piece, :id, ""))
end
