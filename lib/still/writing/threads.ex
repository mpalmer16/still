defmodule Still.Writing.Threads do
  @moduledoc "Read-only returns between recurring words in Before and saved writing."

  import Ecto.Query

  alias Still.{Poems, Repo, Writing}
  alias Still.Writing.{Entry, Notebook}

  @word_pattern ~r/[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)*/u
  @single_word ~r/^[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)*$/u
  @stopwords MapSet.new(~w(
    about after again against all also although always am an and any are around as at away
    back be because been before being below between both but by can cannot could did do does
    doing down during each either enough even ever every few for from further get gets getting
    give go goes going gone got had has have having he her here hers herself him himself his
    how however i if in into is it its itself just keep kept kind know last later least less
    let like little long made make many may me might more most much must my myself near need
    neither never new next no nor not nothing now of off often on once one only or other our
    ours ourselves out over own perhaps quite rather really right same say says see seem seemed
    seeming seems several she should since so some someone something still such take than that
    the their theirs them themselves then there these they this those through throughout to too
    under until up upon us very was we well were what when where whether which while who whom
    whose why will with within without would yes yet you your yours yourself yourselves
  ))

  @doc "Loads historical Lists and, when configured, safely readable saved pages."
  def load(location) when is_map(location) do
    historical =
      Repo.all(
        from(entry in Entry,
          where: entry.origin == "before" and is_nil(entry.file_id),
          order_by: [asc: entry.id]
        )
      )
      |> Enum.map(&historical_document/1)

    if location[:configured] || location["configured"] do
      case Poems.list_read_only(location) do
        {:error, message} ->
          %{documents: historical, problem: message}

        {:ok, pieces} ->
          %{documents: historical ++ Enum.map(pieces, &file_document/1), problem: nil}
      end
    else
      %{documents: historical, problem: location[:error] || location["error"]}
    end
  end

  def load(_location), do: %{documents: [], problem: "The writing collection is unavailable."}

  @doc "Returns up to twelve recurring Unicode words, favoring cross-kind and cross-notebook ties."
  def words(documents, opts \\ [])

  def words(documents, opts) when is_list(documents) do
    document_count = max(length(documents), 1)
    limit = opts |> Keyword.get(:limit, 12) |> max(0) |> min(12)
    seed = Keyword.get(opts, :seed, "still-threads-v1") |> to_string()
    from = Keyword.get(opts, :from)
    from_doc = Enum.find(documents, &(&1.key == from))
    from_words = if from_doc, do: MapSet.new(document_index(from_doc).words), else: MapSet.new()
    from_filter? = Keyword.has_key?(opts, :from)

    if from_filter? and is_nil(from_doc) do
      []
    else
      documents
      |> Enum.flat_map(fn doc -> Enum.map(document_index(doc).words, &{&1, doc}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.flat_map(fn {word, occurrences} ->
        families = occurrences |> Enum.map(& &1.family) |> Enum.uniq()
        frequency = length(families) / document_count
        grapheme_count = length(String.graphemes(word))

        if length(families) >= 2 and grapheme_count >= 4 and grapheme_count <= 64 and
             not MapSet.member?(@stopwords, word) and
             (not from_filter? or MapSet.member?(from_words, word)) and
             not (document_count >= 8 and frequency > 0.65) do
          kinds = Enum.map(occurrences, & &1.kind) |> Enum.uniq()

          notebooks =
            occurrences
            |> Enum.filter(&(&1.kind == :before))
            |> Enum.map(& &1.label)
            |> Enum.uniq()

          cross_kind = length(kinds) > 1
          cross_notebook = length(notebooks) > 1
          from_bonus = if MapSet.member?(from_words, word), do: 1, else: 0

          rank =
            {if(cross_kind, do: 1, else: 0), if(cross_notebook, do: 1, else: 0), from_bonus,
             -frequency, length(families), tie(seed, word)}

          [{rank, word}]
        else
          []
        end
      end)
      |> Enum.sort_by(fn {rank, _word} -> rank end, :desc)
      |> Enum.take(limit)
      |> Enum.map(&elem(&1, 1))
    end
  end

  def words(_, _opts), do: []

  @doc "Returns the first exact authored stanza containing the complete word in each document."
  def passages(documents, word) when is_list(documents) do
    normalized = normalize_word(word)

    if normalized == "" do
      []
    else
      Enum.flat_map(documents, fn doc ->
        case Map.get(document_index(doc).passages, normalized) do
          nil -> []
          passage -> [%{document: doc, text: passage.text, line: passage.line}]
        end
      end)
    end
  end

  def passages(_, _word), do: []

  @doc "Counts distinct preferred pairs from different source families."
  def crossing_count(passages) when is_list(passages) do
    {_priority, count} = preferred_pairs(passages)
    count
  end

  def crossing_count(_), do: 0

  @doc "Chooses a deterministic pair from different source families, cycling by step."
  def pair(passages, step \\ 0)

  def pair(passages, step) when is_list(passages) do
    {priority, count} = preferred_pairs(passages)

    if count == 0 do
      nil
    else
      index = if is_integer(step), do: Integer.mod(step, count), else: 0

      case priority do
        :cross_kind ->
          cross_kind_pair(passages, index)

        :cross_notebook ->
          cross_notebook_pair(Enum.filter(passages, &(&1.document.kind == :before)), index)

        :any ->
          any_pair(passages, index)
      end
    end
  end

  def pair(_, _step), do: nil

  @doc "Normalizes one Unicode word, allowing internal straight or curly apostrophes."
  def normalize_word(value) when is_binary(value) do
    value = String.trim(value)

    if String.valid?(value) do
      normalized = value |> String.normalize(:nfc) |> String.downcase()
      graphemes = String.graphemes(normalized)

      if length(graphemes) <= 64 and Regex.match?(@single_word, normalized),
        do: normalized,
        else: ""
    else
      ""
    end
  end

  def normalize_word(_), do: ""

  defp historical_document(entry) do
    key = "before:#{entry.id}"

    %{
      key: key,
      kind: :before,
      id: entry.id,
      title: Writing.opening(entry),
      body: entry.body,
      label: entry.notebook || "Before",
      family:
        if(is_binary(entry.source_key) and entry.source_key != "",
          do: entry.source_key,
          else: key
        )
    }
  end

  defp file_document(piece) do
    key = "file:#{piece.id}"
    source_key = get_in(piece, [:historical_source, "source_key"])

    %{
      key: key,
      kind: :file,
      id: piece.id,
      title: Poems.display_title(piece),
      body: piece.body,
      label: file_notebook_label(piece),
      family: if(is_binary(source_key) and source_key != "", do: source_key, else: key)
    }
  end

  defp file_notebook_label(piece) do
    Map.get(piece, :notebook_label) ||
      case Map.get(piece, :notebook_id) do
        id when is_integer(id) ->
          case Repo.get(Notebook, id) do
            nil -> Map.get(piece, :notebook) || "Saved writing"
            notebook -> notebook.label
          end

        _ ->
          Map.get(piece, :notebook) || "Saved writing"
      end
  end

  defp tokens(text) when is_binary(text) do
    Regex.scan(@word_pattern, String.normalize(text, :nfc))
    |> List.flatten()
    |> Enum.map(&(String.normalize(&1, :nfc) |> String.downcase()))
  end

  defp tokens(_), do: []

  defp document_index(%{key: key, body: body} = doc) when is_binary(key) and is_binary(body) do
    cache_key = {__MODULE__, Repo.config()[:database], :document, doc.kind, key}

    case Still.Writing.IndexCache.get(cache_key) do
      {^body, index} -> index
      _ -> Still.Writing.IndexCache.put(cache_key, body, build_document_index(body))
    end
  end

  defp document_index(%{body: body}) when is_binary(body), do: build_document_index(body)
  defp document_index(_doc), do: %{words: [], passages: %{}}

  defp build_document_index(body) do
    passages =
      body
      |> split_lines()
      |> stanzas()
      |> Enum.reduce(%{}, fn %{text: text, start_line: start_line}, passages ->
        text
        |> split_lines()
        |> Enum.with_index()
        |> Enum.reduce(passages, fn {line, offset}, found ->
          Enum.reduce(Enum.uniq(tokens(line)), found, fn word, acc ->
            Map.put_new(acc, word, %{text: text, line: start_line + offset})
          end)
        end)
      end)

    %{words: Map.keys(passages), passages: passages}
  end

  # Keep each line ending attached to its exact source line, including CRLF.
  defp split_lines(""), do: []

  defp split_lines(body),
    do:
      Regex.scan(~r/[^\r\n]*(?:\r\n|\n|\r|$)/u, body)
      |> List.flatten()
      |> Enum.reject(&(&1 == ""))

  defp stanzas(lines) do
    {current, acc, start_line} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({[], [], nil}, fn {line, number}, {current, acc, start_line} ->
        if String.trim(line) == "" do
          {[], finish_stanza(current, start_line, acc), nil}
        else
          {[line | current], acc, start_line || number}
        end
      end)

    Enum.reverse(finish_stanza(current, start_line, acc))
  end

  defp finish_stanza([], _start_line, acc), do: acc

  defp finish_stanza(current, start_line, acc) do
    text = current |> Enum.reverse() |> IO.iodata_to_binary()
    [%{text: text, start_line: start_line} | acc]
  end

  defp preferred_pairs(passages) do
    before = Enum.filter(passages, &(&1.document.kind == :before))
    files = Enum.filter(passages, &(&1.document.kind == :file))
    file_count = length(files)
    file_families = Enum.frequencies_by(files, & &1.document.family)

    cross_kind =
      Enum.reduce(before, 0, fn passage, count ->
        count + file_count - Map.get(file_families, passage.document.family, 0)
      end)

    cond do
      cross_kind > 0 ->
        {:cross_kind, cross_kind}

      true ->
        notebook_pairs = cross_notebook_count(before)

        if notebook_pairs > 0,
          do: {:cross_notebook, notebook_pairs},
          else: {:any, family_pair_count(passages)}
    end
  end

  # Canonical orientation is always Before first, then saved writing.
  defp cross_kind_pair(passages, index) do
    before = Enum.filter(passages, &(&1.document.kind == :before))
    files = Enum.filter(passages, &(&1.document.kind == :file))
    file_count = length(files)
    file_families = Enum.frequencies_by(files, & &1.document.family)

    Enum.reduce_while(before, index, fn left, remaining ->
      candidates = file_count - Map.get(file_families, left.document.family, 0)

      if remaining < candidates do
        right =
          files
          |> Enum.reject(&(&1.document.family == left.document.family))
          |> Enum.at(remaining)

        {:halt, {left, right}}
      else
        {:cont, remaining - candidates}
      end
    end)
  end

  defp cross_notebook_count(passages) do
    labels = Enum.frequencies_by(passages, & &1.document.label)
    families = Enum.frequencies_by(passages, & &1.document.family)
    family_labels = Enum.frequencies_by(passages, &{&1.document.family, &1.document.label})

    different_labels =
      choose_pairs(length(passages)) -
        Enum.reduce(labels, 0, fn {_key, n}, sum -> sum + choose_pairs(n) end)

    family_same_label_pairs =
      Enum.reduce(family_labels, %{}, fn {{family, _label}, count}, acc ->
        Map.update(acc, family, choose_pairs(count), &(&1 + choose_pairs(count)))
      end)

    same_family_cross_label =
      Enum.reduce(families, 0, fn {family, count}, sum ->
        sum + choose_pairs(count) - Map.get(family_same_label_pairs, family, 0)
      end)

    different_labels - same_family_cross_label
  end

  defp family_pair_count(passages) do
    choose_pairs(length(passages)) -
      (passages
       |> Enum.frequencies_by(& &1.document.family)
       |> Enum.reduce(0, fn {_family, count}, sum -> sum + choose_pairs(count) end))
  end

  defp choose_pairs(count), do: div(count * (count - 1), 2)

  defp cross_notebook_pair(passages, index) do
    total = length(passages)
    labels = Enum.frequencies_by(passages, & &1.document.label)
    families = Enum.frequencies_by(passages, & &1.document.family)
    family_labels = Enum.frequencies_by(passages, &{&1.document.family, &1.document.label})

    Enum.reduce_while(passages, {index, total, labels, families, family_labels, []}, fn left,
                                                                                        {remaining,
                                                                                         suffix_total,
                                                                                         suffix_labels,
                                                                                         suffix_families,
                                                                                         suffix_family_labels,
                                                                                         prefix} ->
      family = left.document.family
      label = left.document.label
      suffix_total = suffix_total - 1
      suffix_labels = decrement(suffix_labels, label)
      suffix_families = decrement(suffix_families, family)
      suffix_family_labels = decrement(suffix_family_labels, {family, label})

      eligible =
        suffix_total - Map.get(suffix_labels, label, 0) -
          (Map.get(suffix_families, family, 0) - Map.get(suffix_family_labels, {family, label}, 0))

      if remaining < eligible do
        right =
          passages
          |> Enum.drop(length(prefix) + 1)
          |> Enum.filter(fn candidate ->
            candidate.document.label != label and candidate.document.family != family
          end)
          |> Enum.at(remaining)

        {:halt, {left, right}}
      else
        {:cont,
         {remaining - eligible, suffix_total, suffix_labels, suffix_families,
          suffix_family_labels, [left | prefix]}}
      end
    end)
  end

  defp any_pair(passages, index) do
    total = length(passages)
    families = Enum.frequencies_by(passages, & &1.document.family)

    Enum.reduce_while(passages, {index, total, families, []}, fn left,
                                                                 {remaining, suffix_total,
                                                                  suffix_families, prefix} ->
      family = left.document.family
      suffix_total = suffix_total - 1
      suffix_families = decrement(suffix_families, family)
      eligible = suffix_total - Map.get(suffix_families, family, 0)

      if remaining < eligible do
        right =
          passages
          |> Enum.drop(length(prefix) + 1)
          |> Enum.reject(&(&1.document.family == family))
          |> Enum.at(remaining)

        {:halt, {left, right}}
      else
        {:cont, {remaining - eligible, suffix_total, suffix_families, [left | prefix]}}
      end
    end)
  end

  defp decrement(map, key) do
    case Map.get(map, key, 0) do
      1 -> Map.delete(map, key)
      count when count > 1 -> Map.put(map, key, count - 1)
      _ -> map
    end
  end

  defp tie(seed, word) do
    :crypto.hash(:sha256, seed <> "\0" <> word) |> binary_part(0, 8) |> :binary.decode_unsigned()
  end
end
