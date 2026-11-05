defmodule Still.Writing.TextFile do
  @moduledoc """
  Lossless ordinary-text input and explicit title roles for the storage pilot.

  A document's body is the entire file's text, including any title. A title role
  points into that text; it never removes words or supplies a second edition.
  A filename can label a saved page without assigning title meaning to any body line.
  There is no capitalization or separator-based inference of title lines in the body.
  This module does not index, save, convert, or adopt a collection.
  """

  @bom <<239, 187, 191>>

  @doc "Read a regular local UTF-8 text file without changing it or requiring an extension."
  def read(path) when is_binary(path) do
    with {:ok, %{type: :regular}} <- File.lstat(path),
         false <- String.downcase(Path.extname(path)) == ".gdoc",
         {:ok, bytes} <- File.read(path) do
      decode(bytes)
    else
      {:ok, _} -> {:error, :not_regular_file}
      true -> {:error, :cloud_document_reference}
      error -> error
    end
  end

  @doc "Decode supported text, retaining the byte-order mark separately for an exact round trip."
  def decode(bytes) when is_binary(bytes) do
    {prefix, body} =
      case bytes do
        <<@bom, text::binary>> -> {@bom, text}
        _ -> {"", bytes}
      end

    cond do
      unsupported_document?(body) -> {:error, :binary_document}
      not String.valid?(body) -> {:error, :unsupported_encoding}
      Regex.match?(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, body) -> {:error, :binary_content}
      true -> {:ok, %{body: body, prefix: prefix, token: digest(bytes)}}
    end
  end

  defp unsupported_document?(<<"%PDF-", _::binary>>), do: true
  defp unsupported_document?(<<"{\\rtf", _::binary>>), do: true
  defp unsupported_document?(<<"PK", 3, 4, _::binary>>), do: true
  defp unsupported_document?(_), do: false

  @doc "Reconstruct the original bytes, including a UTF-8 byte-order mark when present."
  def encode(document), do: document.prefix <> document.body

  @doc "An automatic display label has no explicit-title meaning and never changes the text."
  def display_label(document, role \\ nil) do
    case title(document, role) do
      {:ok, text} -> {:ok, String.trim(text)}
      {:error, _} = error -> error
      :none -> {:ok, first_label(document.body)}
    end
  end

  @doc "A readable file title, independent of the poem's opening or a physical title-line role."
  def filename_label(path, list_label \\ nil)

  def filename_label(path, list_label) when is_binary(path) do
    name = Path.basename(path)

    stem =
      if String.downcase(Path.extname(name)) in [".txt", ".text", ".md", ".markdown"],
        do: Path.rootname(name),
        else: name

    stem =
      if is_binary(list_label) and list_label != "" do
        if stem == list_label,
          do: "",
          else: Regex.replace(~r/^#{Regex.escape(list_label)}[_. -]+/u, stem, "")
      else
        stem
      end

    label = stem |> String.replace(~r/_+/u, " ") |> String.trim()
    if label != "", do: label
  end

  def filename_label(_, _), do: nil

  defp first_label(body) do
    line = body |> String.split(~r/\r\n|\r|\n/) |> Enum.find("", &(String.trim(&1) != ""))
    line = String.trim(line)

    cond do
      line == "" -> "Untitled"
      String.length(line) > 60 -> String.slice(line, 0, 59) <> "…"
      true -> line
    end
  end

  @doc "Record the one-based physical line the writer explicitly selected as a title."
  def mark_title(document, number) when is_integer(number) and number > 0 do
    case Enum.at(lines(document), number - 1) do
      %{text: text} when text != "" ->
        if String.trim(text) == "",
          do: {:error, :blank_title},
          else: {:ok, %{line: number, text: text, token: document.token}}

      _ ->
        {:error, :missing_title_line}
    end
  end

  def mark_title(_, _), do: {:error, :missing_title_line}

  @doc "Resolve a recorded role; external changes require review instead of guessing a title."
  def title(_document, nil), do: :none

  def title(document, %{line: number, text: expected, token: token})
      when is_integer(number) and number > 0 do
    case Enum.at(lines(document), number - 1) do
      %{text: ^expected} when token == document.token -> {:ok, expected}
      _ -> {:error, :title_needs_review}
    end
  end

  def title(_, _), do: {:error, :invalid_title_role}

  @doc "Separate editor fields without dropping any indentation, separators, or line endings."
  def editor_parts(document, role) do
    with {:ok, text} <- title(document, role) do
      line = Enum.at(lines(document), role.line - 1)
      first = line.offset
      last = first + byte_size(text)

      {:ok,
       %{
         before: binary_part(document.body, 0, first),
         title: text,
         after: binary_part(document.body, last, byte_size(document.body) - last)
       }}
    else
      :none -> {:error, :no_title_role}
      error -> error
    end
  end

  @doc "Replace only a selected title line with exact supplied text; all other bytes stay put."
  def replace_title(document, role, replacement) when is_binary(replacement) do
    with false <- String.contains?(replacement, ["\r", "\n"]),
         {:ok, parts} <- editor_parts(document, role),
         {:ok, next} <- decode(document.prefix <> parts.before <> replacement <> parts.after),
         {:ok, next_role} <- mark_title(next, role.line) do
      {:ok, next, next_role}
    else
      true -> {:error, :multiline_title}
      error -> error
    end
  end

  @doc "Copy the complete text exactly once; title meaning never prepends another title."
  def copy_text(document), do: document.body

  @doc "Physical lines with original separators and byte offsets, including blank lines."
  def lines(document) do
    # An empty file has one blank line; a final separator starts another blank
    # line. A nonblank unterminated final line must not gain a phantom successor.
    trailing_line? = document.body == "" or String.ends_with?(document.body, ["\r", "\n"])

    Regex.scan(~r/([^\r\n]*)(\r\n|\r|\n|$)/u, document.body, return: :index)
    |> Enum.reject(fn [{_offset, length} | _] -> length == 0 and not trailing_line? end)
    |> Enum.map(fn [{offset, _length}, {start, length}, {ending, ending_length}] ->
      %{
        offset: offset,
        text: binary_part(document.body, start, length),
        ending: binary_part(document.body, ending, ending_length)
      }
    end)
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
