defmodule Still.Next.Directory do
  @moduledoc "Search, sort, and pagination for Next in Correspondence."

  alias Still.Next

  @per_page 40
  @views [{"Open", "open"}, {"Today", "today"}, {"Upcoming", "upcoming"}, {"History", "history"}]
  @sources [
    {"All sources", "all"},
    {"Unlinked", "none"},
    {"Work", "piece"},
    {"Place", "journal"},
    {"Packet", "packet"},
    {"Calendar event", "event"},
    {"Funding opportunity", "funding"}
  ]
  @defaults %{
    "q" => "",
    "view" => "open",
    "source" => "all",
    "sort" => "default",
    "dir" => "asc",
    "page" => 1
  }

  def views, do: @views
  def sources, do: @sources
  def defaults, do: @defaults

  def filters(params) do
    %{
      "q" => query(params["q"]),
      "view" => choice(params["view"], Enum.map(@views, &elem(&1, 1)), "open"),
      "source" => choice(params["source"], Enum.map(@sources, &elem(&1, 1)), "all"),
      "sort" => choice(params["sort"], ~w(title plan deadline), "default"),
      "dir" => choice(params["dir"], ~w(asc desc), "asc"),
      "page" => page_number(params["page"])
    }
  end

  def browse(tasks, filters, today) do
    matching =
      tasks
      |> Next.view(filters["view"], today, filters["q"])
      |> Enum.filter(&source_matches?(&1.target, filters["source"]))
      |> sort(filters["sort"], filters["dir"])

    count = length(matching)
    pages = max(1, ceil(count / @per_page))
    page = min(filters["page"], pages)
    offset = (page - 1) * @per_page
    rows = Enum.slice(matching, offset, @per_page)

    %{
      rows: rows,
      count: count,
      page: page,
      pages: pages,
      first: offset + 1,
      last: offset + length(rows)
    }
  end

  defp query(value) when is_binary(value), do: String.slice(value, 0, 300)
  defp query(_), do: ""

  defp choice(value, choices, default), do: if(value in choices, do: value, else: default)

  defp page_number(page) when is_integer(page) and page > 0, do: page

  defp page_number(page) when is_binary(page) and byte_size(page) <= 8 do
    case Integer.parse(page) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp page_number(_), do: 1

  defp source_matches?(_target, "all"), do: true
  defp source_matches?(nil, "none"), do: true
  defp source_matches?(%{type: type}, type), do: true
  defp source_matches?(_, _), do: false

  defp sort(tasks, "title", direction),
    do: Enum.sort_by(tasks, &title_key/1, order(direction))

  defp sort(tasks, "plan", direction), do: sort_by_date(tasks, :planned_on, direction)
  defp sort(tasks, "deadline", direction), do: sort_by_date(tasks, :due_on, direction)
  defp sort(tasks, _, _), do: tasks

  defp sort_by_date(tasks, field, direction) do
    {dated, undated} = Enum.split_with(tasks, &Map.get(&1, field))

    Enum.sort_by(
      dated,
      &{Date.to_gregorian_days(Map.fetch!(&1, field)), title_key(&1)},
      order(direction)
    ) ++
      undated
  end

  defp title_key(task), do: {task.title |> String.normalize(:nfc) |> String.downcase(), task.id}
  defp order("desc"), do: :desc
  defp order(_), do: :asc
end
