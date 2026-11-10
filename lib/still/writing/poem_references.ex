defmodule Still.Writing.PoemReferences do
  @moduledoc "Parses and resolves local references from one poem to another."

  alias Still.Writing.Files

  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\z/
  @identified_marker ~r/\A\[\[poem: ([^\]\r\n]+) \| ([^\]\r\n]+)\]\]\z/
  @path_marker ~r/\A\[\[poem: ([^\]\r\n]+)\]\]\z/

  @doc "Splits a body into literal text and own-line poem markers, with UTF-16 offsets."
  def parse(body) when is_binary(body) do
    references =
      Regex.scan(~r/\[\[poem: [^\]\r\n]+\]\]/, body, return: :index)
      |> Enum.flat_map(fn [{start_byte, length}] ->
        raw = binary_part(body, start_byte, length)

        if own_line?(body, start_byte, length) do
          case parse_marker(raw) do
            {:ok, path, id} -> [{start_byte, raw, path, id}]
            :error -> []
          end
        else
          []
        end
      end)

    assemble_segments(body, references)
  end

  def parse(_), do: []

  @doc "Resolves references through the collection's safe file context API."
  def resolve(location, body, opts \\ []) do
    refs = Enum.filter(parse(body), &(&1.kind == :reference))

    sources =
      case Files.reference_sources(location, refs, reconcile: Keyword.get(opts, :reconcile, true)) do
        {:ok, found} when is_map(found) -> found
        _ -> %{}
      end

    current_id = Keyword.get(opts, :current_id)

    parse(body)
    |> Enum.map(fn
      %{kind: :reference} = ref -> resolve_reference(ref, sources, current_id)
      segment -> segment
    end)
  end

  @doc "Expands available references to their source words for copying."
  def expand(location, body, opts \\ []) do
    resolve(location, body, opts)
    |> Enum.map(fn
      %{kind: :reference, status: :available, source: source} -> source.body
      %{kind: :reference, raw: raw} -> raw
      %{kind: :text, raw: raw} -> raw
    end)
    |> IO.iodata_to_binary()
  end

  @doc "Returns a bounded set of readable poems matching a query."
  def candidates(location, query, opts \\ []) do
    with {:ok, pieces} <- Files.list_read_only(location) do
      search(pieces, query, opts)
    else
      _ -> []
    end
  end

  @doc "Searches an already loaded candidate list without reading the collection again."
  def search(pieces, query, opts \\ [])

  def search(pieces, query, opts) when is_list(pieces) do
    current_id = Keyword.get(opts, :current_id)
    limit = opts |> Keyword.get(:limit, 20) |> bounded_limit()
    normalized_query = query |> to_string() |> String.downcase() |> String.trim()

    pieces
    |> Enum.reject(&(&1.id == current_id))
    |> Enum.filter(fn piece ->
      matches?(
        %{title: Files.display_title(piece), path: piece.relative_path, body: piece.body},
        normalized_query
      )
    end)
    |> Enum.take(limit)
    |> Enum.map(fn piece ->
      %{
        id: piece.id,
        path: piece.relative_path,
        title: Files.display_title(piece),
        preview: String.slice(piece.body || "", 0, 240)
      }
    end)
  end

  def search(_, _, _), do: []

  @doc "Builds an identified marker for a piece."
  def marker(%{relative_path: path, id: id}) when is_binary(path) and is_binary(id) do
    "[[poem: " <> encode_path(path) <> " | " <> id <> "]]"
  end

  def marker(_), do: nil

  defp own_line?(body, start, length) do
    prefix = binary_part(body, 0, start)
    suffix_start = start + length
    suffix = binary_part(body, suffix_start, byte_size(body) - suffix_start)

    (prefix == "" or String.ends_with?(prefix, ["\n", "\r"])) and
      (suffix == "" or String.starts_with?(suffix, ["\n", "\r"]))
  end

  defp parse_marker(raw) do
    case Regex.run(@identified_marker, raw) do
      [_, encoded_path, id] ->
        with true <- Regex.match?(@uuid, id),
             {:ok, path} <- decode_path(encoded_path),
             true <- valid_path?(path) do
          {:ok, path, String.downcase(id)}
        else
          _ -> :error
        end

      nil ->
        case Regex.run(@path_marker, raw) do
          [_, encoded_path] ->
            with {:ok, path} <- decode_path(encoded_path),
                 true <- valid_path?(path) do
              {:ok, path, nil}
            else
              _ -> :error
            end

          nil ->
            :error
        end
    end
  end

  defp assemble_segments(body, references) do
    {segments, cursor} =
      Enum.reduce(references, {[], 0}, fn {start_byte, raw, path, id}, {acc, cursor} ->
        prefix = binary_part(body, cursor, start_byte - cursor)
        prefix_start = utf16_length(binary_part(body, 0, cursor))
        start_utf16 = utf16_length(binary_part(body, 0, start_byte))

        ref = %{
          kind: :reference,
          raw: raw,
          path: path,
          id: id,
          start_utf16: start_utf16,
          end_utf16: start_utf16 + utf16_length(raw)
        }

        text = %{kind: :text, raw: prefix, start_utf16: prefix_start, end_utf16: start_utf16}
        {acc ++ [text, ref], start_byte + byte_size(raw)}
      end)

    tail = binary_part(body, cursor, byte_size(body) - cursor)
    start_utf16 = utf16_length(binary_part(body, 0, cursor))

    segments ++
      [
        %{
          kind: :text,
          raw: tail,
          start_utf16: start_utf16,
          end_utf16: start_utf16 + utf16_length(tail)
        }
      ]
  end

  defp resolve_reference(ref, sources, current_id) do
    key = if ref.id, do: {:id, ref.id}, else: {:path, ref.path}

    case Map.get(sources, key) do
      {:ok, source} when source.id != current_id ->
        # Expansion stops at this source's exact words; nested markers are literal.
        Map.merge(ref, %{status: :available, message: nil, source: source})

      {:ok, _source} ->
        Map.merge(ref, %{
          status: :unavailable,
          message: "This reference points to the current poem.",
          source: nil
        })

      {:error, message} ->
        Map.merge(ref, %{status: :unavailable, message: message, source: nil})

      _ ->
        Map.merge(ref, %{
          status: :unavailable,
          message: "The referenced poem is unavailable.",
          source: nil
        })
    end
  end

  defp valid_path?(path) do
    if is_binary(path) do
      parts = String.split(path, "/")

      String.valid?(path) and Path.type(path) == :relative and path != "" and
        not Regex.match?(~r/[\x00-\x1F\x7F]/u, path) and
        Enum.all?(parts, &(&1 not in ["", ".", ".."] and &1 != <<0>>))
    else
      false
    end
  end

  defp encode_path(path) do
    path
    |> String.replace("%", "%25")
    |> String.replace("|", "%7C")
    |> String.replace("]", "%5D")
    |> String.replace("\r", "%0D")
    |> String.replace("\n", "%0A")
  end

  defp decode_path(path) do
    if Regex.match?(~r/%(?![0-9a-fA-F]{2})/, path), do: :error, else: {:ok, URI.decode(path)}
  end

  defp matches?(_piece, ""), do: true

  defp matches?(piece, query) do
    Enum.any?([piece.title, piece.path, piece.body], fn value ->
      String.contains?(String.downcase(value || ""), query)
    end)
  end

  defp bounded_limit(value) when is_integer(value), do: value |> max(1) |> min(50)
  defp bounded_limit(_), do: 20

  defp utf16_length(binary) do
    binary
    |> String.to_charlist()
    |> Enum.reduce(0, fn cp, total -> total + if(cp > 0xFFFF, do: 2, else: 1) end)
  end
end
