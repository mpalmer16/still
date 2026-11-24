defmodule Still.Correspondence.FundingDirectory do
  @moduledoc "Search, filter, order, and paginate saved funding opportunities."
  alias Still.Correspondence.Funding

  @per_page 40
  @deadline_filters ~w(all upcoming past undated)

  def build(opportunities, filters, today) do
    filters = normalize_filters(filters)

    rows =
      opportunities
      |> Enum.filter(&matches_query?(&1, filters["q"]))
      |> Enum.filter(&matches_kind?(&1, filters["kind"]))
      |> Enum.filter(&matches_deadline?(&1, filters["deadline"], today))
      |> Enum.filter(&(filters["starred"] != "true" or &1[:highlighted] == true))
      |> Enum.sort_by(&deadline_sort_key(&1, today))

    matched = length(rows)
    pages = max(1, ceil(matched / @per_page))
    page = filters["page"] |> integer_or(1) |> max(1) |> min(pages)

    %{
      filters: Map.put(filters, "page", Integer.to_string(page)),
      rows: Enum.slice(rows, (page - 1) * @per_page, @per_page),
      matched: matched,
      total: length(opportunities),
      page: page,
      pages: pages,
      per_page: @per_page
    }
  end

  defp normalize_filters(filters) do
    kinds = Enum.map(Funding.kinds(), &elem(&1, 1))

    %{
      "q" => filters |> text("q", "") |> String.trim() |> String.slice(0, 300),
      "kind" => allowed(filters["kind"], kinds),
      "deadline" => allowed(filters["deadline"], @deadline_filters),
      "starred" => if(filters["starred"] == "true", do: "true", else: "false"),
      "page" => text(filters, "page", "1")
    }
  end

  defp allowed(value, allowed), do: if(value in allowed, do: value, else: "all")

  defp text(map, key, default) do
    value = Map.get(map, key)
    if is_binary(value), do: value, else: default
  end

  defp matches_query?(_opportunity, ""), do: true

  defp matches_query?(opportunity, query) do
    query = String.downcase(query)

    [:name, :funder, :kind, :cycle, :amount, :eligibility, :description, :notes]
    |> Enum.map(&Map.get(opportunity, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.any?(&String.contains?(&1, query))
  end

  defp matches_kind?(_opportunity, "all"), do: true
  defp matches_kind?(opportunity, kind), do: opportunity.kind == kind

  defp matches_deadline?(_opportunity, "all", _today), do: true

  defp matches_deadline?(opportunity, "undated", _today),
    do: is_nil(opportunity.deadline)

  defp matches_deadline?(opportunity, view, today) do
    case opportunity.deadline do
      nil -> false
      deadline when view == "upcoming" -> deadline >= Date.to_iso8601(today)
      deadline when view == "past" -> deadline < Date.to_iso8601(today)
    end
  end

  defp deadline_sort_key(opportunity, today) do
    name = String.downcase(opportunity.name)

    case opportunity.deadline do
      nil ->
        {2, 0, name}

      deadline ->
        offset = Date.diff(Date.from_iso8601!(deadline), today)
        if offset >= 0, do: {0, offset, name}, else: {1, -offset, name}
    end
  end

  defp integer_or(value, default) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> default
    end
  end
end
