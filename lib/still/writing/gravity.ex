defmodule Still.Writing.Gravity do
  @moduledoc "A little living, literal language drawn toward writing and wandering."
  import Ecto.Query
  alias Still.{Repo, Writing}
  alias Still.Writing.{Entry, Geography}

  @window 140
  @threshold 6.0
  @second_threshold 9.0
  @common MapSet.new(
            ~w(a all also always an and another any are around as at away be because been being both but by can can't could couldn't did didn't do does doesn't don't down each even ever every for from get go going got had hadn't has hasn't have haven't he her here hers him his how i i'd i'll i'm i've if in into is isn't it it's its just like little me more most much must my need never no not of on once one only or other our out over own say see seen seem seems seemed seeming she should shouldn't so some something still such than that that's the their them then there there's these they they're this those through to too until up us very was wasn't we we'd we'll we're we've were weren't what what's when where which who who's why will with without won't would wouldn't yet you you'd you'll you're you've your today tomorrow yesterday two three four five six seven eight nine ten)
          )

  def draw(body, opts \\ []) when is_binary(body) do
    body
    |> candidates(opts)
    |> choose(Keyword.get(opts, :previous_id))
    |> result()
  end

  @doc "A scarce peripheral field, held by independent literal language and stable source homes."
  def field(body, opts \\ []) when is_binary(body) do
    previous = opts |> Keyword.get(:previous, []) |> List.wrap()
    previous_ids = MapSet.new(previous, &entry_id/1)
    candidates = candidates(body, opts)

    candidates =
      if opts[:reading],
        do: prefer_other_origin(candidates, anchor_origin(opts)),
        else: candidates

    previous_id = previous |> List.first() |> entry_id()

    case choose(candidates, previous_id) do
      nil ->
        []

      first ->
        second =
          if !opts[:reading] do
            candidates
            |> Enum.flat_map(&independent(&1, first, previous_ids))
            |> choose(previous |> Enum.find(&(entry_id(&1) != first.entry.id)) |> entry_id())
          end

        [first, second]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn candidate ->
          remembered = Enum.find(previous, &(entry_id(&1) == candidate.entry.id))
          field_result(candidate, remembered)
        end)
        |> place_newcomers(previous)
    end
  end

  @doc "Use the same literal evidence to offer one path from an entire saved piece."
  def echo(%Entry{} = entry, opts \\ []) do
    query_opts = [
      reading: true,
      entry_id: entry.id,
      list: Writing.list_entry?(entry),
      title: if(is_nil(entry.file_id), do: entry.title)
    ]

    avoided = MapSet.new(Keyword.get(opts, :avoid_ids, []))
    candidates = candidates(entry.body, query_opts)
    preferred = Enum.reject(candidates, &MapSet.member?(avoided, &1.entry.id))

    if(preferred == [], do: candidates, else: preferred)
    |> prefer_other_origin(entry.origin)
    |> choose(nil)
    |> result()
    |> case do
      nil -> nil
      drawn -> Map.take(drawn, [:entry, :phrase, :line])
    end
  end

  @doc "One historical companion for a saved page, excluding its own historical source."
  def saved_echo(piece), do: saved_field(piece) |> List.first()

  @doc "A historical field for a saved page or one of its literal passages."
  def saved_field(piece, passage \\ nil, opts \\ []) do
    field(passage || piece.body,
      reading: true,
      historical_only: true,
      title:
        if(is_nil(passage) and Map.get(piece, :title_in_body) != true,
          do: Still.Poems.display_title(piece)
        ),
      exclude_ids:
        historical_source_ids(piece) ++
          List.wrap(Map.get(piece, :entry_id)) ++ Keyword.get(opts, :exclude_ids, []),
      previous: Keyword.get(opts, :previous, [])
    )
  end

  @doc "The imported original of a saved edition, so it does not echo itself."
  def historical_source_ids(piece) do
    case Map.get(piece, :historical_source) do
      %{"source_key" => source_key} when is_binary(source_key) ->
        case Repo.get_by(Entry, source_key: source_key) do
          nil -> []
          entry -> [entry.id]
        end

      _ ->
        []
    end
  end

  defp candidates(body, opts) do
    index = index(opts)
    query = if is_binary(opts[:title]), do: opts[:title] <> "\n" <> body, else: body
    query_tokens = tokens(query)
    query_tokens = if opts[:reading], do: query_tokens, else: Enum.take(query_tokens, -@window)
    formed = if opts[:list], do: formed_words(body), else: MapSet.new()
    weights = query_weights(query_tokens, index, formed, opts)
    excluded = MapSet.new(Keyword.get(opts, :exclude_ids, []) ++ List.wrap(opts[:entry_id]))

    candidates =
      Enum.reduce(weights, %{}, fn {word, weight}, matches ->
        index.inverted
        |> Map.get(word, MapSet.new())
        |> Enum.reduce(matches, fn id, acc ->
          if MapSet.member?(excluded, id) do
            acc
          else
            Map.update(acc, id, %{word => weight}, &Map.put(&1, word, weight))
          end
        end)
      end)

    query_phrases = phrases(query_tokens, query)

    candidates
    |> Enum.filter(fn {_id, matches} ->
      map_size(matches) >= 2 or singleton?(matches, formed, index, opts)
    end)
    |> Enum.map(fn {id, matches} ->
      entry = Map.fetch!(index.entries, id)
      shared = shared_phrase(Map.fetch!(index.tokens, id), entry.body, query_phrases, weights)
      phrase_bonus = if shared, do: shared.bonus, else: 0.0
      single_bonus = if map_size(matches) == 1, do: 3.0, else: 0.0
      score = Enum.sum(Map.values(matches)) + phrase_bonus + single_bonus
      %{entry: entry, score: score, shared: shared, weights: matches}
    end)
    |> Enum.filter(&(&1.score >= @threshold))
  end

  defp singleton?(matches, formed, index, opts) when map_size(matches) == 1 do
    [word] = Map.keys(matches)

    MapSet.member?(formed, word) or
      ((opts[:reading] || opts[:selection]) &&
         String.length(word) >= if(opts[:selection], do: 4, else: 6) &&
         Map.get(index.frequencies, word, 0) <= 2)
  end

  defp singleton?(_matches, _formed, _index, _opts), do: false

  defp formed_words(body) do
    colon_items = Regex.scan(~r/(?:\A|(?<=[:\n,]))[\t ]*([^:\n,]{1,80})[:,]/u, body)
    bullet_items = Regex.scan(~r/^[\t ]*[-*•][\t ]+([^\n]{1,80})$/mu, body)

    (colon_items ++ bullet_items)
    |> Enum.flat_map(fn [_literal, item] ->
      words = tokens(item) |> Enum.map(&elem(&1, 0))
      if length(words) <= 4, do: words, else: []
    end)
    |> MapSet.new()
  end

  defp anchor_origin(opts) do
    if id = opts[:entry_id] do
      case Repo.get(Entry, id) do
        nil -> nil
        entry -> entry.origin
      end
    end
  end

  defp prefer_other_origin([], _origin), do: []
  defp prefer_other_origin(candidates, nil), do: candidates

  defp prefer_other_origin(candidates, origin) do
    strongest = Enum.max_by(candidates, & &1.score)

    crossing =
      Enum.filter(candidates, &(&1.entry.origin != origin and &1.score >= strongest.score * 0.8))

    if crossing == [], do: candidates, else: crossing
  end

  defp independent(candidate, first, previous_ids) do
    novel = Map.drop(candidate.weights, Map.keys(first.weights))
    shared = candidate.shared

    shared =
      if shared && Enum.count(shared.signals, &Map.has_key?(novel, &1)) >= 2,
        do: shared

    score = Enum.sum(Map.values(novel)) + if(shared, do: shared.bonus, else: 0.0)
    retained = MapSet.member?(previous_ids, candidate.entry.id)
    threshold = if retained, do: 7.5, else: @second_threshold
    proportion = if retained, do: 0.35, else: 0.45

    if candidate.entry.id != first.entry.id and not same_source?(candidate.entry, first.entry) and
         score >= threshold and score >= first.score * proportion and
         map_size(novel) >= 2 and Enum.sum(Map.values(novel)) >= @threshold do
      [%{candidate | score: score, weights: novel, shared: shared}]
    else
      []
    end
  end

  defp same_source?(left, right) do
    is_binary(left.source_group) and left.source_group != "" and
      left.source_group == right.source_group
  end

  defp entry_id(%{entry: %{id: id}}), do: id
  defp entry_id(_fragment), do: nil

  defp choose([], _previous), do: nil

  defp choose(candidates, previous_id) do
    strongest = Enum.max_by(candidates, &{&1.score, -&1.entry.id})

    case Enum.find(candidates, &(&1.entry.id == previous_id)) do
      %{score: score} = previous when score >= strongest.score * 0.8 ->
        if map_size(previous.weights) >= min(2, map_size(strongest.weights)),
          do: previous,
          else: strongest

      _ ->
        strongest
    end
  end

  defp result(nil), do: nil

  defp result(candidate) do
    strength = min(0.95, 0.18 + (candidate.score - @threshold) / 18)
    line = source_line(candidate.entry, candidate.weights)

    %{
      entry: candidate.entry,
      line: line,
      phrase: literal_evidence(candidate),
      strength: Float.round(strength, 3),
      distance: distance(strength),
      place: Geography.for_entry(candidate.entry)
    }
  end

  defp field_result(candidate, previous) do
    drawn = result(candidate)

    {strength, motion} =
      case previous do
        %{strength: old} when is_number(old) ->
          difference = drawn.strength - old

          motion =
            cond do
              difference > 0.025 -> :approaching
              difference < -0.025 -> :receding
              true -> :settling
            end

          {Float.round(old * 0.55 + drawn.strength * 0.45, 3), motion}

        _ ->
          {drawn.strength, :approaching}
      end

    line =
      case previous do
        %{line: line} when is_binary(line) ->
          score = line_weight(line, candidate.weights)
          best_score = line_weight(drawn.line, candidate.weights)

          if line in String.split(candidate.entry.body, "\n") and score > 0 and
               score >= best_score * 0.8,
             do: line,
             else: drawn.line

        _ ->
          drawn.line
      end

    drawn
    |> Map.merge(remembered_home(previous) || peripheral_home(candidate.entry))
    |> Map.merge(%{line: line, strength: strength, distance: distance(strength), motion: motion})
  end

  defp place_newcomers(field, previous) do
    {retained, newcomers} =
      Enum.split_with(field, fn fragment ->
        previous |> Enum.find(&(entry_id(&1) == fragment.entry.id)) |> remembered_home() != nil
      end)

    placed =
      Enum.reduce(newcomers, retained, fn fragment, placed ->
        crowded =
          Enum.any?(placed, fn other ->
            fragment.side == other.side and abs(fragment.height - other.height) < 18
          end)

        fragment =
          if crowded,
            do: %{fragment | side: if(fragment.side == :left, do: :right, else: :left)},
            else: fragment

        [fragment | placed]
      end)

    Enum.map(field, fn fragment -> Enum.find(placed, &(&1.entry.id == fragment.entry.id)) end)
  end

  defp remembered_home(%{side: side, height: height})
       when side in [:left, :right] and is_number(height) and height >= 26 and height <= 68,
       do: %{side: side, height: height}

  defp remembered_home(_fragment), do: nil

  # A fragment's home follows its source rather than its rank. The hash keeps
  # both sides available without alternating a pair just to fill the room.
  defp peripheral_home(entry) do
    source = entry.source_key || entry.source_group || entry.id
    seed = :erlang.phash2({:still_field, source}, 10_000)
    %{side: if(rem(seed, 2) == 0, do: :left, else: :right), height: 26 + rem(div(seed, 2), 43)}
  end

  defp distance(strength) do
    cond do
      strength >= 0.65 -> :close
      strength >= 0.38 -> :near
      true -> :far
    end
  end

  defp query_weights(query_tokens, index, formed, opts) do
    count = length(query_tokens)
    rarity_limit = max(2, ceil(index.count * 0.06))
    scale = :math.log(max(index.count + 1, 2))

    query_tokens
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {{word, _start, _length}, position}, weights ->
      frequency = Map.get(index.frequencies, word, 0)
      deliberate = MapSet.member?(formed, word)
      limit = if deliberate, do: max(2, ceil(index.count * 0.12)), else: rarity_limit

      meaningful =
        content?(word) or
          (deliberate and String.length(word) >= 3 and not MapSet.member?(@common, word))

      if meaningful and frequency > 0 and frequency <= limit do
        rarity = :math.log((index.count + 1) / (frequency + 1)) / scale
        recency = if opts[:reading], do: 1.0, else: :math.exp(-(count - position - 1) / 30)
        weight = (3.0 + 3.0 * rarity) * recency
        Map.update(weights, word, weight, &max(&1, weight))
      else
        weights
      end
    end)
  end

  defp shared_phrase(source_tokens, body, query_phrases, weights) do
    source_tokens
    |> phrases(body)
    |> Enum.flat_map(fn {key, source} ->
      case Map.get(query_phrases, key) do
        nil ->
          []

        query ->
          signals = Enum.filter(source.words, &Map.has_key?(weights, &1)) |> Enum.uniq()

          if length(signals) >= 2 and literal_form(source.literal) == literal_form(query.literal) do
            pull = signals |> Enum.map(&Map.fetch!(weights, &1)) |> Enum.sum()

            [
              %{
                literal: source.literal,
                signals: signals,
                bonus: min(4.5, pull * 0.28 + (length(source.words) - 2) * 0.45)
              }
            ]
          else
            []
          end
      end
    end)
    |> Enum.max_by(& &1.bonus, fn -> nil end)
  end

  defp source_line(entry, weights) do
    line =
      entry.body
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.max_by(&line_weight(&1, weights), fn -> entry.body end)

    if line_weight(line, weights) > 0, do: line, else: entry.title || line
  end

  defp literal_evidence(%{shared: %{literal: literal}}), do: literal

  defp literal_evidence(candidate) do
    {word, _weight} = Enum.max_by(candidate.weights, fn {word, weight} -> {weight, word} end)
    body = candidate.entry.body <> "\n" <> (candidate.entry.title || "")
    {_word, start, length} = Enum.find(tokens(body), &(elem(&1, 0) == word))
    binary_part(body, start, length)
  end

  defp line_weight(line, weights) do
    line
    |> tokens()
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(&Map.get(weights, &1, 0.0))
    |> Enum.sum()
  end

  # Share derived tokens between readers. Exact row changes retokenize only
  # changed writings; every operation still verifies the current source files.
  defp index(opts) do
    historical? = opts[:historical_only] == true
    scope = Still.Writing.Files.discovery_scope()

    query =
      if historical?,
        do:
          from(e in Entry,
            where: (e.origin == "before" and is_nil(e.file_id)) or not is_nil(e.file_id)
          ),
        else: Entry

    query = available_entries(query, scope)

    entries = Repo.all(from(e in query, order_by: e.id))
    stamp = entries
    cache_key = {__MODULE__, Repo.config()[:database], :index, scope, historical?}

    case Still.Writing.IndexCache.get(cache_key) do
      {^stamp, index} ->
        index

      {previous_stamp, previous_index} ->
        index = refresh_index(previous_index, previous_stamp, entries)
        Still.Writing.IndexCache.put(cache_key, stamp, index)
        index

      _ ->
        index = Enum.reduce(entries, empty_index(), &add_entry/2)
        Still.Writing.IndexCache.put(cache_key, stamp, index)
        index
    end
  end

  defp available_entries(query, nil),
    do: where(query, [e], is_nil(e.file_id))

  defp available_entries(query, scope) do
    where(
      query,
      [e],
      is_nil(e.file_id) or
        (e.collection_scope == ^scope and not e.file_missing and not e.trashed)
    )
  end

  defp empty_index do
    %{count: 0, entries: %{}, tokens: %{}, words: %{}, frequencies: %{}, inverted: %{}}
  end

  defp refresh_index(index, previous_entries, entries) do
    previous = Map.new(previous_entries, &{&1.id, &1})
    current = Map.new(entries, &{&1.id, &1})
    changed = Enum.filter(entries, &(Map.get(previous, &1.id) != &1))
    removed = Map.keys(previous) -- Map.keys(current)
    index = Enum.reduce(Enum.uniq(Enum.map(changed, & &1.id) ++ removed), index, &remove_entry/2)
    Enum.reduce(changed, index, &add_entry/2)
  end

  defp add_entry(entry, index) do
    body_tokens = tokens(entry.body)

    title_tokens = if is_nil(entry.file_id), do: tokens(entry.title || ""), else: []
    words = (body_tokens ++ title_tokens) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    {frequencies, inverted} =
      Enum.reduce(words, {index.frequencies, index.inverted}, fn word, {frequencies, inverted} ->
        {Map.update(frequencies, word, 1, &(&1 + 1)),
         Map.update(inverted, word, MapSet.new([entry.id]), &MapSet.put(&1, entry.id))}
      end)

    %{
      index
      | count: index.count + 1,
        entries: Map.put(index.entries, entry.id, entry),
        tokens: Map.put(index.tokens, entry.id, body_tokens),
        words: Map.put(index.words, entry.id, words),
        frequencies: frequencies,
        inverted: inverted
    }
  end

  defp remove_entry(id, index) do
    case Map.fetch(index.words, id) do
      :error ->
        index

      {:ok, words} ->
        {frequencies, inverted} =
          Enum.reduce(words, {index.frequencies, index.inverted}, fn word,
                                                                     {frequencies, inverted} ->
            remaining = Map.fetch!(frequencies, word) - 1

            if remaining == 0 do
              {Map.delete(frequencies, word), Map.delete(inverted, word)}
            else
              {Map.put(frequencies, word, remaining),
               Map.update!(inverted, word, &MapSet.delete(&1, id))}
            end
          end)

        %{
          index
          | count: index.count - 1,
            entries: Map.delete(index.entries, id),
            tokens: Map.delete(index.tokens, id),
            words: Map.delete(index.words, id),
            frequencies: frequencies,
            inverted: inverted
        }
    end
  end

  defp content?(word), do: String.length(word) >= 4 and not MapSet.member?(@common, word)

  defp tokens(body) do
    Regex.scan(~r/[\p{L}\p{N}’']+/u, body, return: :index)
    |> Enum.map(fn [{start, length}] ->
      word = binary_part(body, start, length) |> String.downcase() |> String.replace("’", "'")
      {word, start, length}
    end)
  end

  defp phrases(words, body) do
    for size <- [2, 3, 4], chunk <- Enum.chunk_every(words, size, 1, :discard), into: %{} do
      {_word, start, _length} = hd(chunk)
      {_word, last_start, last_length} = List.last(chunk)
      words = Enum.map(chunk, &elem(&1, 0))
      key = Enum.join(words, " ")
      literal = binary_part(body, start, last_start + last_length - start)
      {key, %{literal: literal, words: words}}
    end
  end

  defp literal_form(phrase), do: phrase |> String.downcase() |> String.replace(~r/\s+/u, " ")
end
