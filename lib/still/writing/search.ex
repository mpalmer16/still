defmodule Still.Writing.Search do
  @moduledoc "Literal local search, with passages and explicitly requested earlier words."
  import Ecto.Query
  alias Still.Repo
  alias Still.Writing.{Entry, Version}

  def query(value) when is_binary(value), do: String.slice(value, 0, 200) |> String.trim()
  def query(_), do: ""

  def terms(value) do
    value = value |> query() |> fold()
    words = Regex.scan(~r/[\p{L}\p{N}]+/u, value) |> List.flatten() |> Enum.uniq()
    if words == [] && value != "", do: [value], else: words
  end

  def entries(opts \\ []) do
    term = query(Keyword.get(opts, :query, ""))
    limit = opts |> Keyword.get(:limit, 40) |> max(0) |> min(100)
    offset = max(Keyword.get(opts, :offset, 0), 0)
    ordered = ordered_entries(Keyword.get(opts, :origin), Keyword.get(opts, :scope, :all))

    if term == "" do
      ordered |> limit(^limit) |> offset(^offset) |> Repo.all()
    else
      ordered
      |> Repo.all()
      |> Enum.filter(&matches?(&1, term))
      |> Enum.drop(offset)
      |> Enum.take(limit)
    end
  end

  def find(opts \\ []) do
    query = query(Keyword.get(opts, :query, ""))
    earlier? = Keyword.get(opts, :earlier, false) && query != ""
    limit = opts |> Keyword.get(:limit, 40) |> max(0) |> min(100)
    offset = max(Keyword.get(opts, :offset, 0), 0)

    ordered = ordered_entries(nil, Keyword.get(opts, :scope, :all))

    entries =
      if earlier?,
        do:
          ordered
          |> preload(versions: ^from(v in Version, order_by: [desc: v.inserted_at, desc: v.id]))
          |> Repo.all(),
        else: ordered |> Repo.all()

    entries
    |> Stream.flat_map(fn entry ->
      versions = if earlier?, do: Enum.uniq_by(entry.versions, &{&1.title, &1.body}), else: []
      current = if matches?(entry, query), do: [result(entry, nil, query)], else: []

      current ++
        for version <- versions,
            {version.title, version.body} != {entry.title, entry.body},
            matches?(version, query),
            do: result(entry, version, query)
    end)
    |> Stream.drop(offset)
    |> Enum.take(limit)
  end

  def matches?(words, query) do
    text = fold((words.title || "") <> "\n" <> words.body)
    Enum.all?(terms(query), &String.contains?(text, &1))
  end

  def passage(body, query) do
    terms = terms(query)
    lines = String.split(body, "\n", trim: false)

    {line, index} =
      lines
      |> Enum.with_index(1)
      |> Enum.max_by(
        fn {line, _} -> Enum.count(terms, &String.contains?(fold(line), &1)) end,
        fn -> {"", 1} end
      )

    matched? = terms != [] && Enum.any?(terms, &String.contains?(fold(line), &1))
    first = if matched?, do: max(index - 2, 0), else: 0
    excerpt = lines |> Enum.drop(first) |> Enum.take(3) |> Enum.join("\n") |> crop(terms)
    %{line: if(matched?, do: index), excerpt: excerpt}
  end

  def parts(text, query) do
    terms = terms(query)

    if terms == [] do
      [%{text: text, match: false}]
    else
      Regex.scan(~r/[\p{L}\p{N}\p{M}]+|[^\p{L}\p{N}\p{M}]+/u, text)
      |> Enum.map(fn [part] ->
        %{text: part, match: Enum.any?(terms, &String.contains?(fold(part), &1))}
      end)
    end
  end

  defp result(entry, version, query) do
    words = version || entry
    passage = passage(words.body, query)

    %{
      id: if(version, do: "version-#{version.id}", else: "current-#{entry.id}"),
      entry: entry,
      version: version,
      title: words.title || opening(words.body),
      excerpt:
        if(query == "" && is_nil(words.title),
          do: continuation(words.body),
          else: passage.excerpt
        ),
      line: passage.line
    }
  end

  defp continuation(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.drop(1)
    |> Enum.join(" ")
    |> String.slice(0, 220)
  end

  defp opening(body),
    do:
      body
      |> String.split("\n")
      |> Enum.find("Untitled", &(String.trim(&1) != ""))
      |> String.slice(0, 120)

  defp crop(text, terms) do
    if String.length(text) <= 280 do
      text
    else
      # Locate the original word rather than indexing folded Unicode back into authored text.
      words = Regex.scan(~r/[\p{L}\p{N}\p{M}]+|[^\p{L}\p{N}\p{M}]+/u, text) |> List.flatten()

      {prefix, _} =
        Enum.split_while(words, fn word ->
          !Enum.any?(terms, &String.contains?(fold(word), &1))
        end)

      position =
        if length(prefix) == length(words), do: 0, else: prefix |> Enum.join() |> String.length()

      start = max(position - 65, 0)

      if(start > 0, do: "…", else: "") <>
        String.slice(text, start, 280) <> if String.length(text) > start + 280, do: "…", else: ""
    end
  end

  defp fold(text),
    do: text |> String.normalize(:nfd) |> String.downcase() |> String.replace(~r/\p{M}/u, "")

  defp ordered_entries(origin, scope) do
    query =
      from e in Entry,
        order_by: [
          asc:
            fragment(
              "CASE WHEN ? = 'now' OR ? IS NOT NULL THEN 0 ELSE 1 END",
              e.origin,
              e.returned_at
            ),
          desc:
            fragment(
              "CASE WHEN ? = 'now' THEN ? ELSE ? END",
              e.origin,
              e.inserted_at,
              e.returned_at
            ),
          asc: e.notebook,
          asc: e.source_order,
          desc: e.id
        ]

    query =
      if scope == :saved do
        query
        |> where([e], e.origin == "now" or not is_nil(e.returned_at))
        |> exclude(:order_by)
        |> order_by([e], desc: e.updated_at, desc: e.id)
      else
        query
      end

    if origin in ["now", "before"], do: where(query, [e], e.origin == ^origin), else: query
  end
end
