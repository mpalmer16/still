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
    query_terms = terms(term)
    limit = opts |> Keyword.get(:limit, 40) |> max(0) |> min(100)
    offset = max(Keyword.get(opts, :offset, 0), 0)
    ordered = ordered_entries(Keyword.get(opts, :origin), Keyword.get(opts, :scope, :all))

    if term == "" do
      ordered
      |> Repo.all()
      |> stable_file_order()
      |> Enum.drop(offset)
      |> Enum.take(limit)
    else
      ordered
      |> Repo.all()
      |> stable_file_order()
      |> Enum.filter(&matches_terms?(&1, query_terms))
      |> Enum.drop(offset)
      |> Enum.take(limit)
    end
  end

  def find(opts \\ []) do
    query = query(Keyword.get(opts, :query, ""))
    query_terms = terms(query)
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

    entries = stable_file_order(entries)

    entries
    |> Stream.flat_map(fn entry ->
      versions = if earlier?, do: Enum.uniq_by(entry.versions, &{&1.title, &1.body}), else: []

      current =
        if matches_terms?(entry, query_terms),
          do: [result(entry, nil, query, query_terms)],
          else: []

      current ++
        for version <- versions,
            {version.title, version.body} != {entry.title, entry.body},
            matches_terms?(version, query_terms),
            do: result(entry, version, query, query_terms)
    end)
    |> Stream.drop(offset)
    |> Enum.take(limit)
  end

  def matches?(words, query) do
    matches_terms?(words, terms(query))
  end

  defp matches_terms?(_words, []), do: true

  defp matches_terms?(words, terms) do
    text = folded_text(words)
    Enum.all?(terms, &String.contains?(text, &1))
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

  defp result(entry, version, query, query_terms) do
    words = version || entry
    passage = passage_words(words, query_terms)

    %{
      id: if(version, do: "version-#{version.id}", else: "current-#{entry.id}"),
      entry: entry,
      version: version,
      title:
        if(is_nil(version) && entry.file_id,
          do: Still.Writing.opening(entry),
          else: words.title || opening(words.body)
        ),
      excerpt:
        if(query == "" && is_nil(words.title) && is_nil(entry.file_id),
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

  defp passage_words(words, terms) do
    original_lines = String.split(words.body, "\n", trim: false)

    folded_lines =
      if terms == [], do: [], else: String.split(folded_body(words), "\n", trim: false)

    {_line, index} =
      original_lines
      |> Enum.with_index(1)
      |> Enum.max_by(
        fn {_line, index} ->
          folded = Enum.at(folded_lines, index - 1, "")
          Enum.count(terms, &String.contains?(folded, &1))
        end,
        fn -> {"", 1} end
      )

    folded = Enum.at(folded_lines, index - 1, "")
    matched? = terms != [] && Enum.any?(terms, &String.contains?(folded, &1))
    first = if matched?, do: max(index - 2, 0), else: 0
    excerpt = original_lines |> Enum.drop(first) |> Enum.take(3) |> Enum.join("\n") |> crop(terms)
    %{line: if(matched?, do: index), excerpt: excerpt}
  end

  defp folded_text(%Entry{} = entry) do
    source =
      {entry.body, entry.title, entry.file_id, entry.relative_path, entry.list_label,
       entry.title_line, entry.title_needs_review}

    cached_fold(entry, :entry, source, fn ->
      title = if entry.file_id, do: Still.Writing.opening(entry), else: entry.title || ""
      title <> "\n" <> entry.body
    end)
  end

  defp folded_text(%Version{} = version) do
    cached_fold(version, :version, {version.body, version.title, nil}, fn ->
      (version.title || "") <> "\n" <> version.body
    end)
  end

  defp folded_text(words) when is_map(words) do
    if Map.get(words, :file_id),
      do: fold(Still.Writing.Files.display_title(words) <> "\n" <> Map.get(words, :body, "")),
      else: fold((Map.get(words, :title) || "") <> "\n" <> Map.get(words, :body, ""))
  end

  defp folded_body(%Entry{} = entry),
    do: cached_fold(entry, :entry_body, {entry.body}, fn -> entry.body end)

  defp folded_body(%Version{} = version),
    do: cached_fold(version, :version_body, {version.body}, fn -> version.body end)

  defp folded_body(words) when is_map(words), do: Map.get(words, :body, "")

  defp cached_fold(%{id: id}, kind, source, text) do
    key = {__MODULE__, Still.Repo.config()[:database], kind, id}
    stamp = source

    case Still.Writing.IndexCache.get(key) do
      {^stamp, folded} -> folded
      _ -> Still.Writing.IndexCache.put(key, stamp, fold(text.()))
    end
  end

  defp fold(text),
    do: text |> String.normalize(:nfd) |> String.downcase() |> String.replace(~r/\p{M}/u, "")

  defp ordered_entries(origin, scope) do
    query =
      from(e in Entry,
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
      )

    active_scope = Still.Writing.Files.discovery_scope()

    query =
      if active_scope do
        where(
          query,
          [e],
          is_nil(e.file_id) or
            (e.collection_scope == ^active_scope and not e.file_missing and not e.trashed)
        )
      else
        where(query, [e], is_nil(e.file_id))
      end

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

  # File projection insertion and edit times are synchronization events, not
  # writing chronology. Keep ordinary Now/returned entries in their existing
  # order, then sequence file entries by their notebook and authored List order.
  defp stable_file_order(entries) do
    {files, ordinary} = Enum.split_with(entries, &(not is_nil(&1.file_id)))

    {current, earlier} =
      Enum.split_while(ordinary, &(&1.origin == "now" or not is_nil(&1.returned_at)))

    current ++ Enum.sort_by(files, &file_sequence/1) ++ earlier
  end

  defp file_sequence(entry) do
    notebook = to_string(entry.notebook_id || entry.notebook || "")

    list_position =
      if is_integer(entry.source_order),
        do: {0, entry.source_order},
        else: {1, natural_key(entry.list_label || "")}

    {natural_key(notebook), list_position, natural_key(entry.list_label || ""), entry.id}
  end

  defp natural_key(value) do
    Regex.scan(~r/\d+|\D+/u, value)
    |> List.flatten()
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {number, ""} -> {0, number}
        _ -> {1, String.downcase(part)}
      end
    end)
  end
end
