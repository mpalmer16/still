defmodule Still.Writing.Attention do
  @moduledoc "Exact, local passage context for following a writer's attention."

  @max_locate_bytes 100_000
  @max_neighbor_graphemes 300
  @max_context_graphemes 500
  @doc "Splits authored stanzas and blank separator runs without changing any source byte."
  def passages(body) when is_binary(body) do
    if String.valid?(body) do
      body
      |> source_lines()
      |> group_lines()
    else
      []
    end
  end

  def passages(_body), do: []

  @doc "Locates a UTF-16 textarea selection or the stanza under its caret."
  def locate(body, start_utf16, end_utf16)
      when is_binary(body) and is_integer(start_utf16) and is_integer(end_utf16) do
    cond do
      not String.valid?(body) ->
        {:error, :invalid}

      byte_size(body) > @max_locate_bytes ->
        {:error, :invalid}

      start_utf16 < 0 or end_utf16 < start_utf16 ->
        {:error, :invalid}

      true ->
        boundaries = utf16_boundaries(body)

        with {:ok, start_byte} <- Map.fetch(boundaries, start_utf16),
             {:ok, end_byte} <- Map.fetch(boundaries, end_utf16),
             true <- end_byte <= byte_size(body) do
          locate_bytes(body, start_byte, end_byte)
        else
          _ -> {:error, :invalid}
        end
    end
  end

  def locate(_body, _start_utf16, _end_utf16), do: {:error, :invalid}

  @doc "Returns up to two complete nearby lines from the same stanza as an exact source line."
  def excerpt(body, line) when is_binary(body) and is_binary(line) do
    if String.valid?(body) and String.valid?(line) do
      records = source_lines(body)

      case Enum.find_index(records, &(without_lf(&1.text) == line and &1.kind == :passage)) do
        nil -> %{before: "", after: ""}
        index -> excerpt_at(records, index)
      end
    else
      %{before: "", after: ""}
    end
  end

  def excerpt(_body, _line), do: %{before: "", after: ""}

  defp locate_bytes(body, start_byte, end_byte) when start_byte < end_byte do
    records = source_lines(body)

    selected =
      Enum.filter(records, fn record ->
        record.start_byte < end_byte and record.end_byte > start_byte
      end)

    text = binary_part(body, start_byte, end_byte - start_byte)

    case selected do
      [] ->
        {:error, :invalid}

      _ ->
        {:ok,
         %{
           text: text,
           first_line: hd(selected).line,
           last_line: List.last(selected).line,
           kind: :selection
         }}
    end
  end

  defp locate_bytes(body, caret, _end_byte) do
    records = source_lines(body)

    case line_at(records, caret, byte_size(body)) do
      nil ->
        {:ok, %{text: "", first_line: nil, last_line: nil, kind: :space}}

      %{kind: :space, line: number} ->
        {:ok, %{text: "", first_line: number, last_line: number, kind: :space}}

      %{line: number} ->
        case Enum.find(
               passages(body),
               &(&1.kind == :passage and number >= &1.first_line and number <= &1.last_line)
             ) do
          nil ->
            {:ok, %{text: "", first_line: nil, last_line: nil, kind: :space}}

          passage ->
            Map.take(passage, [:text, :first_line, :last_line])
            |> Map.put(:kind, :passage)
            |> then(&{:ok, &1})
        end
    end
  end

  defp line_at([], _caret, _size), do: nil

  defp line_at(records, caret, size) do
    Enum.find(records, fn record -> caret >= record.start_byte and caret < record.end_byte end) ||
      if(caret == size, do: List.last(records))
  end

  defp utf16_boundaries(body), do: utf16_boundaries(body, 0, 0, %{0 => 0})

  defp utf16_boundaries(<<>>, _bytes, _units, boundaries), do: boundaries

  defp utf16_boundaries(<<codepoint::utf8, rest::binary>>, bytes, units, boundaries) do
    encoded = <<codepoint::utf8>>
    next_bytes = bytes + byte_size(encoded)
    next_units = units + if(codepoint > 0xFFFF, do: 2, else: 1)

    utf16_boundaries(rest, next_bytes, next_units, Map.put(boundaries, next_units, next_bytes))
  end

  defp source_lines(""), do: []

  defp source_lines(body) do
    Regex.scan(~r/[^\r\n]*(?:\r\n|\n|\r|$)/u, body)
    |> List.flatten()
    |> Enum.reject(&(&1 == ""))
    |> Enum.with_index(1)
    |> Enum.reduce({[], 0}, fn {text, number}, {records, byte_offset} ->
      record = %{
        text: text,
        line: number,
        start_byte: byte_offset,
        end_byte: byte_offset + byte_size(text),
        kind: if(String.trim(text) == "", do: :space, else: :passage)
      }

      {[record | records], record.end_byte}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp group_lines(records) do
    {chunks, current_kind, current_lines} =
      Enum.reduce(records, {[], nil, []}, fn record, {chunks, kind, lines} ->
        if kind == record.kind do
          {chunks, kind, [record | lines]}
        else
          {finish_chunk(chunks, kind, lines), record.kind, [record]}
        end
      end)

    Enum.reverse(finish_chunk(chunks, current_kind, current_lines))
  end

  defp finish_chunk(chunks, nil, _lines), do: chunks
  defp finish_chunk(chunks, _kind, []), do: chunks

  defp finish_chunk(chunks, kind, lines) do
    ordered = Enum.reverse(lines)

    [
      %{
        text: ordered |> Enum.map(& &1.text) |> IO.iodata_to_binary(),
        first_line: hd(ordered).line,
        last_line: List.last(ordered).line,
        kind: kind
      }
      | chunks
    ]
  end

  defp excerpt_at(records, index) do
    current = Enum.at(records, index)
    same_stanza? = fn record -> record.kind == :passage end

    before_lines =
      records
      |> Enum.take(index)
      |> Enum.reverse()
      |> Enum.take_while(same_stanza?)
      |> take_neighbors()

    after_lines =
      records
      |> Enum.drop(index + 1)
      |> Enum.take_while(same_stanza?)
      |> take_neighbors()

    line_ending = String.replace_prefix(current.text, without_lf(current.text), "")

    %{
      before: before_lines |> Enum.reverse() |> Enum.map(& &1.text) |> IO.iodata_to_binary(),
      after: line_ending <> (after_lines |> Enum.map(& &1.text) |> IO.iodata_to_binary())
    }
  end

  defp take_neighbors(lines) do
    Enum.reduce_while(lines, {[], 0, 0}, fn record, {chosen, count, graphemes} ->
      size = length(String.graphemes(record.text))

      cond do
        count >= 2 ->
          {:halt, {chosen, count, graphemes}}

        size > @max_neighbor_graphemes ->
          {:halt, {chosen, count, graphemes}}

        graphemes + size > @max_context_graphemes ->
          {:halt, {chosen, count, graphemes}}

        true ->
          {:cont, {chosen ++ [record], count + 1, graphemes + size}}
      end
    end)
    |> elem(0)
  end

  defp without_lf(text), do: String.replace_suffix(text, "\n", "")
end
